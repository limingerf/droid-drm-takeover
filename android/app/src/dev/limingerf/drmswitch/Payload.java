package dev.limingerf.drmswitch;

import android.content.Context;
import android.content.res.AssetManager;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * 把 APK 里打包的 assets/payload/** 释放到 {@link Shell#PAYLOAD}。
 *
 * 两步走：
 *   1. 先解到应用私有目录（不需要 root）；
 *   2. 再用 root 把私有目录的内容搬进 {@link Shell#PAYLOAD}
 *      （/data/local/drm-takeover，root 独占可写 —— 理由见 Shell.PAYLOAD 的注释）。
 *
 * 第 2 步优先用 tar 流（root 只负责写，应用只负责读自己的 assets，
 * 不跨 SELinux 上下文），失败再回落到 cp。
 *
 * ⚠️ 落地后必须确保这棵树**对非 root 不可写**：这些脚本随后会以 root 执行。
 *    所以两个脚本都用 `chmod -R go-w` 收掉 group/other 的写位。
 */
final class Payload {

    private static final String OK = "DRM_PAYLOAD_OK";
    private static final String BAD = "DRM_PAYLOAD_FAIL";

    /** 安装成功的判据：这个文件必须存在。 */
    private static final String MARKER = "core/switch.sh";

    /**
     * 建目录 + 落文件 + 收权限，两个安装方式共用的收尾片段。
     *
     * 两件事都要做，别只做一件：
     *   · `chmod -R go-w` 去掉 group/other 的写位 —— 这些脚本随后以 root 执行，
     *     不能让非 root 有机会改它们。
     *   · `chmod 755` 给 bin/ 和 .sh 补上执行位 —— tar/cp 可能带来 644，
     *     而 `bin/kwinwrap` 是被直接 exec 的（不是 `sh kwinwrap`）。
     *     早期版本只做前者，结果二进制不可执行。
     */
    private static final String LOCKDOWN =
            "chmod 700 \"$D\" 2>/dev/null\n"
            + "chmod -R go-w \"$D\" 2>/dev/null\n"
            // bin/ 下的产物要被直接 exec
            + "chmod 755 \"$D\"/bin/* 2>/dev/null\n"
            // 脚本统一用 `sh <路径>` 调用，执行位不是必需，但给上更符合直觉
            + "chmod 755 \"$D\"/*.sh \"$D\"/core/*.sh \"$D\"/core/lib/*.sh "
            + "\"$D\"/core/device/*.sh \"$D\"/linux/*.sh \"$D\"/display/*.sh "
            + "\"$D\"/android/*.sh 2>/dev/null\n"
            + "if [ -f \"$D/" + MARKER + "\" ]; then echo " + OK + "; "
            + "else echo " + BAD + "; exit 1; fi\n";

    private Payload() {
    }

    /** 递归枚举 assets，路径相对于 assets 根。空目录会被当成文件，复制时忽略。 */
    private static void walk(AssetManager am, String path, List<String> files, List<String> dirs)
            throws IOException {
        String[] children = am.list(path);
        if (children == null) {
            return;
        }
        if (children.length == 0) {
            if (!path.isEmpty()) {
                files.add(path);
            }
            return;
        }
        if (!path.isEmpty()) {
            dirs.add(path);
        }
        for (String c : children) {
            walk(am, path.isEmpty() ? c : path + "/" + c, files, dirs);
        }
    }

    private static void deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] kids = f.listFiles();
            if (kids != null) {
                for (File k : kids) {
                    deleteRecursive(k);
                }
            }
        }
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
        }
    }

    /** 解包 assets 到应用私有目录，返回写入的文件数。 */
    static int extractToPrivate(Context ctx) throws IOException {
        File root = new File(ctx.getFilesDir(), "payload");
        deleteRecursive(root);
        if (!root.mkdirs() && !root.isDirectory()) {
            throw new IOException("无法创建 " + root);
        }

        AssetManager am = ctx.getAssets();
        List<String> files = new ArrayList<>();
        List<String> dirs = new ArrayList<>();
        walk(am, "", files, dirs);

        int written = 0;
        for (String rel : files) {
            File out = new File(root, rel);
            File parent = out.getParentFile();
            if (parent != null && !parent.isDirectory() && !parent.mkdirs() && !parent.isDirectory()) {
                throw new IOException("无法创建目录 " + parent);
            }
            try (InputStream in = am.open(rel);
                 OutputStream os = new FileOutputStream(out)) {
                copy(in, os);
                written++;
            } catch (FileNotFoundException e) {
                // assets 里的空目录：aapt2 会把它列出来但打不开，跳过即可
            }
        }
        return written;
    }

    /**
     * 完整安装：解包 + 以 root 搬到 {@link Shell#PAYLOAD}。
     *
     * @return 成功与否；过程与结果都通过 {@code sink} 汇报。
     */
    static boolean install(Context ctx, Shell.LineSink sink) {
        File priv = new File(ctx.getFilesDir(), "payload");
        int count;
        try {
            count = extractToPrivate(ctx);
        } catch (IOException e) {
            sink.onLine("! 解包 assets 失败：" + e.getMessage());
            return false;
        }
        sink.onLine("已解包 " + count + " 个文件到 " + priv.getAbsolutePath());

        final boolean[] ok = new boolean[1];
        Shell.LineSink probe = new Shell.LineSink() {
            @Override
            public void onLine(String line) {
                if (line.contains(OK)) {
                    ok[0] = true;
                }
                sink.onLine(line);
            }
        };

        // 方式一：tar 流。root 只写目标目录，不读应用私有目录。
        sink.onLine("→ 方式一：tar 流写入 " + Shell.PAYLOAD);
        String tarScript = ""
                + "D=" + Shell.PAYLOAD + "\n"
                + "mkdir -p \"$D\" || exit 1\n"
                + "tar -x -f - -C \"$D\" || exit 1\n"
                + LOCKDOWN;

        int code = Shell.run(Shell.su(tarScript),
                new Shell.StdinSource() {
                    @Override
                    public void writeTo(OutputStream out) throws IOException {
                        Tar.writeTree(priv, out);
                    }
                }, probe, 300000L);
        if (ok[0]) {
            sink.onLine("✓ payload 安装完成（tar 流）");
            return true;
        }
        sink.onLine("! tar 流方式失败（exit " + code + "），改用 cp 兜底");

        // 方式二：root 直接读应用私有目录再复制。
        ok[0] = false;
        String cpScript = ""
                + "D=" + Shell.PAYLOAD + "\n"
                + "S=" + priv.getAbsolutePath() + "\n"
                + "rm -rf \"$D\"\n"
                + "mkdir -p \"$D\" || exit 1\n"
                + "cp -R \"$S/.\" \"$D/\" || exit 1\n"
                + LOCKDOWN;

        int code2 = Shell.run(Shell.su(cpScript), null, probe, 300000L);
        if (ok[0]) {
            sink.onLine("✓ payload 安装完成（cp 方式）");
            return true;
        }
        sink.onLine("✗ payload 安装失败（exit " + code2 + "）");
        sink.onLine("  常见原因：没有授予 root，或 " + Shell.PAYLOAD + " 不可写。");
        return false;
    }
}

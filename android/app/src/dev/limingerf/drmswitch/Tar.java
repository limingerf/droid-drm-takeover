package dev.limingerf.drmswitch;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * 最小 USTAR 打包器（只写，不解）。
 *
 * 为什么要它：把 payload 送进 root 独占的 {@link Shell#PAYLOAD} 需要 root。与其让 root 去读应用私有目录
 * （跨 SELinux 上下文，未必允许），不如由应用自己读 assets、把 tar 流喂给 `su -c 'tar -x'`。
 * 这样写入端始终是 root，读端始终是应用自己。
 *
 * 只支持普通文件和目录，够用。toybox / GNU tar 都能解。
 */
final class Tar {

    private static final int BLOCK = 512;

    /** 固定 mtime，让每次构建的 tar 流可复现。 */
    private static final long MTIME = 1700000000L;

    private Tar() {
    }

    /** 把 {@code root} 下的整棵树写成 tar 流。不关闭 {@code out}。 */
    static void writeTree(File root, OutputStream out) throws IOException {
        List<File> dirs = new ArrayList<>();
        List<File> files = new ArrayList<>();
        collect(root, dirs, files);

        for (File d : dirs) {
            String rel = rel(root, d);
            if (rel.isEmpty()) {
                continue;
            }
            header(out, rel + "/", 0L, 0755, true);
        }

        byte[] buf = new byte[65536];
        for (File f : files) {
            String rel = rel(root, f);
            long len = f.length();
            header(out, rel, len, 0644, false);
            long written = 0L;
            try (InputStream in = new FileInputStream(f)) {
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    written += n;
                }
            }
            // 补齐到 512 边界（长度可能因为并发变化，以实际写入量为准）
            int rem = (int) (written % BLOCK);
            if (rem != 0) {
                out.write(new byte[BLOCK - rem]);
            }
        }

        // tar 结束标记：两个全零块
        out.write(new byte[BLOCK * 2]);
        out.flush();
    }

    private static void collect(File dir, List<File> dirs, List<File> files) {
        File[] children = dir.listFiles();
        if (children == null) {
            return;
        }
        for (File c : children) {
            if (c.isDirectory()) {
                dirs.add(c);
                collect(c, dirs, files);
            } else if (c.isFile()) {
                files.add(c);
            }
        }
    }

    private static String rel(File root, File f) {
        String r = root.getAbsolutePath();
        String a = f.getAbsolutePath();
        if (a.equals(r)) {
            return "";
        }
        if (a.startsWith(r + File.separator)) {
            a = a.substring(r.length() + 1);
        }
        return a.replace(File.separatorChar, '/');
    }

    /** 写一个 512 字节的 USTAR 头。 */
    private static void header(OutputStream out, String name, long size, int mode, boolean dir)
            throws IOException {
        byte[] h = new byte[BLOCK];

        String prefix = "";
        String nm = name;
        if (nm.getBytes(StandardCharsets.UTF_8).length > 100) {
            int cut = -1;
            for (int i = nm.length() - 1; i > 0; i--) {
                if (nm.charAt(i) != '/') {
                    continue;
                }
                String p = nm.substring(0, i);
                String n = nm.substring(i + 1);
                if (p.getBytes(StandardCharsets.UTF_8).length <= 155
                        && n.getBytes(StandardCharsets.UTF_8).length <= 100) {
                    cut = i;
                    break;
                }
            }
            if (cut < 0) {
                throw new IOException("路径太长，USTAR 放不下：" + nm);
            }
            prefix = nm.substring(0, cut);
            nm = nm.substring(cut + 1);
        }

        putStr(h, 0, 100, nm);
        putOctal(h, 100, 8, mode);
        putOctal(h, 108, 8, 0);          // uid
        putOctal(h, 116, 8, 0);          // gid
        putOctal(h, 124, 12, dir ? 0L : size);
        putOctal(h, 136, 12, MTIME);
        for (int i = 148; i < 156; i++) { // chksum 先填空格再算
            h[i] = ' ';
        }
        h[156] = (byte) (dir ? '5' : '0'); // typeflag
        putStr(h, 257, 6, "ustar");
        h[262] = 0;
        h[263] = '0';
        h[264] = '0';
        putStr(h, 265, 32, "root");
        putStr(h, 297, 32, "root");
        putStr(h, 345, 155, prefix);

        int sum = 0;
        for (byte b : h) {
            sum += (b & 0xFF);
        }
        String cs = Long.toOctalString(sum);
        while (cs.length() < 6) {
            cs = "0" + cs;
        }
        if (cs.length() > 6) {
            cs = cs.substring(cs.length() - 6);
        }
        putStr(h, 148, 6, cs);
        h[154] = 0;
        h[155] = ' ';

        out.write(h);
    }

    private static void putStr(byte[] h, int off, int len, String s) {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        int n = Math.min(b.length, len);
        System.arraycopy(b, 0, h, off, n);
    }

    /** 以 NUL 结尾的定长八进制字段。 */
    private static void putOctal(byte[] h, int off, int len, long value) {
        int digits = len - 1;
        String s = Long.toOctalString(value);
        while (s.length() < digits) {
            s = "0" + s;
        }
        if (s.length() > digits) {
            s = s.substring(s.length() - digits);
        }
        putStr(h, off, digits, s);
        h[off + digits] = 0;
    }
}

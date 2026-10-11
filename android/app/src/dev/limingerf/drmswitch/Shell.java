package dev.limingerf.drmswitch;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * 极简 root shell 执行器。
 *
 * 只做三件事：起进程、把 stdout/stderr（已合并）按行回调、可选地把一段字节流喂给子进程 stdin。
 * 不依赖任何第三方库，也不依赖 AndroidX。
 */
final class Shell {

    /**
     * APK 把 payload 释放到的位置；下面所有脚本路径都以此为根。
     *
     * ★ 为什么是 /data/local/drm-takeover 而不是 /data/local/tmp/...：
     *   /data/local/tmp 的权限是 0771 shell:shell —— adb shell（uid 2000）可写。
     *   而这里释放出来的脚本随后**以 root 执行**（本应用已持有 su 授权，
     *   不会再弹提示）。两者相加 = 任何能写该目录的本地进程都能拿到 root
     *   代码执行。所以改放 /data/local/drm-takeover：/data/local 是
     *   0711 root:root，只有 root 能写。
     *   脚本侧另有 core/lib/common.sh 的 drm_assert_payload_trusted() 兜底，
     *   万一路径被改回可写目录，它会拒绝运行。
     */
    static final String PAYLOAD = "/data/local/drm-takeover";

    /**
     * root 二进制的候选位置，越靠前越优先。
     * 应用进程通常 stat 不到 /data/adb（SELinux），所以最后一定要回落到裸 "su" 交给 PATH。
     */
    private static final String[] SU_CANDIDATES = {
        "/data/adb/ksu/bin/su",
        "/data/adb/magisk/su",
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
    };

    /** 收到一行输出。实现可能被后台线程调用。 */
    interface LineSink {
        void onLine(String line);
    }

    /** 生产子进程的 stdin。实现必须关闭流。 */
    interface StdinSource {
        void writeTo(OutputStream out) throws IOException;
    }

    private Shell() {
    }

    /** 解析可用的 root 二进制，找不到就返回裸 "su"。 */
    static String suBinary() {
        for (String c : SU_CANDIDATES) {
            File f = new File(c);
            if (f.exists()) {
                return c;
            }
        }
        return "su";
    }

    /** 构造以 root 执行 {@code script} 的 argv（脚本交给设备上的 sh 解释）。 */
    static String[] su(String script) {
        return new String[] { suBinary(), "-c", script };
    }

    /** 阻塞执行，返回退出码；无法启动时返回 -1。 */
    static int run(String[] argv, StdinSource stdin, LineSink sink, long timeoutMs) {
        return start(argv, stdin, sink, timeoutMs).await();
    }

    /** 起一个进程并立即返回句柄，适合常驻命令（例如 watch）。 */
    static Job start(String[] argv, StdinSource stdin, LineSink sink, long timeoutMs) {
        Process process;
        try {
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectErrorStream(true);
            pb.directory(new File("/"));
            process = pb.start();
        } catch (IOException e) {
            if (sink != null) {
                sink.onLine("! 无法执行 " + argv[0] + "：" + e.getMessage());
            }
            return new Job(null, null, null, null);
        }

        final Process p = process;

        Thread reader = new Thread(new Runnable() {
            @Override
            public void run() {
                try (InputStream in = p.getInputStream();
                     BufferedReader br = new BufferedReader(
                             new InputStreamReader(in, StandardCharsets.UTF_8), 8192)) {
                    String line;
                    while ((line = br.readLine()) != null) {
                        if (sink != null) {
                            sink.onLine(line);
                        }
                    }
                } catch (IOException ignored) {
                    // 进程结束或流被关闭，正常情况
                }
            }
        }, "drm-shell-out");
        reader.setDaemon(true);
        reader.start();

        Thread writer = null;
        if (stdin != null) {
            writer = new Thread(new Runnable() {
                @Override
                public void run() {
                    try (OutputStream out = p.getOutputStream()) {
                        stdin.writeTo(out);
                        out.flush();
                    } catch (IOException ignored) {
                        // 子进程可能已经退出（例如 tar 报错），忽略
                    }
                }
            }, "drm-shell-in");
            writer.setDaemon(true);
            writer.start();
        }

        Thread watchdog = null;
        if (timeoutMs > 0) {
            final long ms = timeoutMs;
            watchdog = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        Thread.sleep(ms);
                        if (p.isAlive()) {
                            if (sink != null) {
                                sink.onLine("! 超时（" + (ms / 1000) + "s），已终止命令");
                            }
                            p.destroy();
                        }
                    } catch (InterruptedException ignored) {
                        // 命令在超时前结束，正常
                    }
                }
            }, "drm-shell-timeout");
            watchdog.setDaemon(true);
            watchdog.start();
        }

        return new Job(p, reader, writer, watchdog);
    }

    /** 一个已启动的进程。 */
    static final class Job {
        private final Process process;
        private final Thread reader;
        private final Thread writer;
        private final Thread watchdog;
        private volatile boolean finished;

        Job(Process process, Thread reader, Thread writer, Thread watchdog) {
            this.process = process;
            this.reader = reader;
            this.writer = writer;
            this.watchdog = watchdog;
            this.finished = (process == null);
        }

        boolean isAlive() {
            return !finished && process != null && process.isAlive();
        }

        /** 等到进程结束，返回退出码。 */
        int await() {
            if (process == null) {
                return -1;
            }
            join(reader);
            join(writer);
            int code;
            try {
                code = process.waitFor();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                code = -1;
            }
            finished = true;
            if (watchdog != null) {
                watchdog.interrupt();
            }
            return code;
        }

        /** 尽力终止（只杀 su 本身；su 的子进程由脚本自行收尾）。 */
        void cancel() {
            if (process != null) {
                process.destroy();
            }
            if (watchdog != null) {
                watchdog.interrupt();
            }
        }

        private static void join(Thread t) {
            if (t == null) {
                return;
            }
            try {
                t.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}

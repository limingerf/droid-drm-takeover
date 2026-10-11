package dev.limingerf.drmswitch;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

/**
 * 离线测试用：直接调用设备上会用的那个 {@link Tar#writeTree}，
 * 把一棵目录树打成 tar 流写进文件。
 *
 * 【为什么需要它】
 * 设备上 payload 的落地链路是：
 *
 *   APK 的 assets/payload/**
 *     → Payload.extractToPrivate()   解到应用私有目录
 *     → Tar.writeTree()              打成 tar 流
 *     → su -c 'tar -x -f - -C $D'    root 侧还原
 *     → LOCKDOWN                     收权限
 *
 * Tar.java 是手写的 USTAR 编码器（不用 java.util.zip，因为要精确控制
 * 权限位和确定性输出）。手写编码器最容易出的问题是"GNU tar 能读、
 * toybox tar 读不了"或者反过来 —— 所以必须拿真实产物过一遍往返比对。
 *
 * 用法：java dev.limingerf.drmswitch.TarTest &lt;源目录&gt; &lt;输出tar&gt;
 */
public final class TarTest {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("用法: TarTest <源目录> <输出tar>");
            System.exit(2);
        }
        File root = new File(args[0]);
        if (!root.isDirectory()) {
            System.err.println("不是目录: " + root);
            System.exit(2);
        }
        try (OutputStream out = new FileOutputStream(args[1])) {
            Tar.writeTree(root, out);
        }
        System.out.println("tar 写出完成: " + args[1]
                + " (" + new File(args[1]).length() + " 字节)");
    }
}

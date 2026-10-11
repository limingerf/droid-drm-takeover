package dev.limingerf.drmswitch;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import java.util.ArrayList;
import java.util.List;

/**
 * 前台服务：托管 {@code android/exit-watch.sh run}。
 *
 * 这是给"没有 KernelSU/Magisk service.d 自启"的设备准备的替代方案 ——
 * 让守护跟着 APK 进程活着，而不是靠开机钩子。
 *
 * 注意：这只在 APK 进程存活期间有效，设备重启后仍需 boot-install.sh 或手动启动。
 */
public final class WatchService extends Service {

    public static final String ACTION_START = "dev.limingerf.drmswitch.action.START_WATCH";
    public static final String ACTION_STOP = "dev.limingerf.drmswitch.action.STOP_WATCH";

    private static final String CHANNEL = "drm-watch";
    private static final int NOTIF_ID = 0x4452; // "DR"

    private static final int LOG_MAX = 400;
    private static final List<String> LOG = new ArrayList<>();

    /** 供 Activity 判断按钮该显示"启动"还是"停止"。 */
    public static volatile boolean running;

    private Shell.Job job;

    /** 返回守护输出的快照（供 Activity 展示）。 */
    public static List<String> snapshot() {
        synchronized (LOG) {
            return new ArrayList<>(LOG);
        }
    }

    private static void record(String line) {
        synchronized (LOG) {
            LOG.add(line);
            while (LOG.size() > LOG_MAX) {
                LOG.remove(0);
            }
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = (intent == null) ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopWatch();
            // stopForeground(boolean) 在 API 33 起废弃；int 形式 API 24 就有，minSdk 26 可安全直用。
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        startForegroundCompat();
        startWatch();
        return START_STICKY;
    }

    private void startForegroundCompat() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL, "返回守护", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("托管 droid-drm-takeover 的「返回安卓」守护进程");
            nm.createNotificationChannel(ch);
        }

        Intent open = new Intent(this, MainActivity.class);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);

        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle("返回守护运行中")
                .setContentText("监听容器里的「返回安卓」请求")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();

        // 三参 startForeground 是 API 29 才有的；API 26-28 只能走两参重载。
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    private void startWatch() {
        if (job != null && job.isAlive()) {
            record("(托管守护已在运行)");
            running = true;
            return;
        }
        record("启动托管守护：" + Shell.PAYLOAD + "/android/exit-watch.sh run");
        String script = "sh " + Shell.PAYLOAD + "/android/exit-watch.sh run";
        job = Shell.start(Shell.su(script), null, new Shell.LineSink() {
            @Override
            public void onLine(String line) {
                record(line);
            }
        }, 0L);
        running = true;
    }

    private void stopWatch() {
        running = false;
        if (job != null) {
            record("停止托管守护");
            job.cancel();
            job = null;
        }
        // 顺带让脚本侧的 watch 循环也退出（双保险）
        Shell.start(Shell.su("sh " + Shell.PAYLOAD + "/android/exit-watch.sh stop"),
                null, null, 30000L);
    }

    @Override
    public void onDestroy() {
        running = false;
        if (job != null) {
            job.cancel();
            job = null;
        }
        super.onDestroy();
    }
}

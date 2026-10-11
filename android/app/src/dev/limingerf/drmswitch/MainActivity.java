package dev.limingerf.drmswitch;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 唯一界面。整个 UI 用 Java 手工搭（不写 layout XML），
 * 这样构建时只需要处理 strings.xml 和一个图标，资源编译极其简单。
 */
public final class MainActivity extends Activity {

    private static final String PREFS = "drm-switch";
    private static final String KEY_PAYLOAD_VERSION = "payload_version";

    /** 改动 assets 内容时 +1，应用会在下次启动时自动重装 payload。 */
    private static final int PAYLOAD_VERSION = 1;

    private static final String ANDROID_DIR = Shell.PAYLOAD + "/android";
    private static final String CORE_DIR = Shell.PAYLOAD + "/core";

    private static final int MAX_OUTPUT = 60000;

    private static final int BG = 0xFF0E141B;
    private static final int BG_OUT = 0xFF060A0F;
    private static final int FG = 0xFFD7E3EE;
    private static final int ACCENT = 0xFF3DDC84;
    private static final int DIM = 0xFF9FB3C8;

    private final ExecutorService queue = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final StringBuilder outBuf = new StringBuilder();
    private final List<Button> allButtons = new ArrayList<>();

    private TextView output;
    private ScrollView outScrollV;
    private HorizontalScrollView outScrollH;
    private TextView statusLine;
    private Button serviceButton;

    private boolean busy;
    private boolean flushScheduled;

    // ───────────────────────────────────────── UI

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        askNotificationPermission();
        maybeAutoInstall();
    }

    private int dp(int v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(ACCENT);
        root.addView(title);

        statusLine = new TextView(this);
        statusLine.setTextSize(11);
        statusLine.setTextColor(DIM);
        statusLine.setPadding(0, dp(2), 0, dp(8));
        statusLine.setText("payload: " + Shell.PAYLOAD + "\nsu: " + Shell.suBinary());
        root.addView(statusLine);

        // ── 输出区（竖直可滚 + 横向可滚，方便看长行）
        outScrollV = new ScrollView(this);
        outScrollH = new HorizontalScrollView(this);
        output = new TextView(this);
        output.setTypeface(Typeface.MONOSPACE);
        output.setTextSize(10);
        output.setTextColor(FG);
        output.setBackgroundColor(BG_OUT);
        output.setPadding(dp(8), dp(8), dp(8), dp(8));
        output.setTextIsSelectable(true);
        output.setText("准备就绪。\n\n首次使用请先点「安装/更新 payload」。\n");
        outScrollH.addView(output);
        outScrollV.addView(outScrollH);

        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        slp.bottomMargin = dp(8);
        root.addView(outScrollV, slp);

        // ── 按钮区
        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.VERTICAL);
        root.addView(buttons, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout r1 = row(buttons);
        addBtn(r1, "安装/更新 payload", new Runnable() {
            @Override
            public void run() {
                doInstall();
            }
        });
        addBtn(r1, "刷新状态", new Runnable() {
            @Override
            public void run() {
                runShell("刷新状态", "sh " + CORE_DIR + "/switch.sh status", 120000L);
            }
        });

        LinearLayout r2 = row(buttons);
        addBtn(r2, "进入 Linux（接管）", new Runnable() {
            @Override
            public void run() {
                confirmEnter();
            }
        });

        LinearLayout r3 = row(buttons);
        addBtn(r3, "启动返回守护", new Runnable() {
            @Override
            public void run() {
                runShell("启动返回守护",
                        "sh " + ANDROID_DIR + "/exit-watch.sh start", 180000L);
            }
        });
        addBtn(r3, "停止返回守护", new Runnable() {
            @Override
            public void run() {
                runShell("停止返回守护",
                        "sh " + ANDROID_DIR + "/exit-watch.sh stop", 120000L);
            }
        });

        LinearLayout r4 = row(buttons);
        addBtn(r4, "安装开机自启", new Runnable() {
            @Override
            public void run() {
                runShell("安装开机自启",
                        "sh " + ANDROID_DIR + "/boot-install.sh install", 120000L);
            }
        });
        addBtn(r4, "环境体检", new Runnable() {
            @Override
            public void run() {
                runShell("环境体检", "sh " + CORE_DIR + "/switch.sh doctor", 300000L);
            }
        });

        LinearLayout r5 = row(buttons);
        addBtn(r5, "查看日志", new Runnable() {
            @Override
            public void run() {
                showLogs();
            }
        });
        addBtn(r5, "清空输出", new Runnable() {
            @Override
            public void run() {
                clearOutput();
            }
        });

        LinearLayout r6 = row(buttons);
        serviceButton = addBtn(r6, "托管守护（前台服务）", new Runnable() {
            @Override
            public void run() {
                toggleService();
            }
        });

        refreshServiceLabel();
    }

    private LinearLayout row(LinearLayout parent) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(6);
        parent.addView(r, lp);
        return r;
    }

    private Button addBtn(LinearLayout row, String label, final Runnable action) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(13);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.leftMargin = dp(3);
        lp.rightMargin = dp(3);
        row.addView(b, lp);
        b.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                action.run();
            }
        });
        allButtons.add(b);
        return b;
    }

    private void setButtonsEnabled(boolean enabled) {
        for (Button b : allButtons) {
            b.setEnabled(enabled);
        }
        if (enabled) {
            refreshServiceLabel();
        }
    }

    private void refreshServiceLabel() {
        if (serviceButton == null) {
            return;
        }
        serviceButton.setText(WatchService.running
                ? "停止托管守护" : "托管守护（前台服务）");
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
    }

    // ───────────────────────────────────────── 输出缓冲

    private void append(String s) {
        synchronized (outBuf) {
            outBuf.append(s);
        }
        scheduleFlush();
    }

    private void appendLine(String s) {
        append(s + "\n");
    }

    private void clearOutput() {
        synchronized (outBuf) {
            outBuf.setLength(0);
        }
        scheduleFlush();
    }

    private void scheduleFlush() {
        if (flushScheduled) {
            return;
        }
        flushScheduled = true;
        ui.postDelayed(new Runnable() {
            @Override
            public void run() {
                flush();
            }
        }, 80L);
    }

    private void flush() {
        String text;
        synchronized (outBuf) {
            int len = outBuf.length();
            if (len > MAX_OUTPUT) {
                outBuf.delete(0, len - MAX_OUTPUT);
            }
            text = outBuf.toString();
            flushScheduled = false;
        }
        if (output == null) {
            return;
        }
        output.setText(text);
        outScrollV.post(new Runnable() {
            @Override
            public void run() {
                outScrollV.fullScroll(View.FOCUS_DOWN);
            }
        });
        outScrollH.post(new Runnable() {
            @Override
            public void run() {
                outScrollH.fullScroll(View.FOCUS_RIGHT);
            }
        });
    }

    // ───────────────────────────────────────── 命令执行

    private interface Task {
        int run() throws Exception;
    }

    /** 串行执行：同一时刻只允许一条命令，避免状态机被并发踩。 */
    private void submit(String label, final Task task) {
        if (busy) {
            toast("有命令正在执行，请稍候");
            return;
        }
        busy = true;
        append("\n════════ " + label + " ════════\n");
        setButtonsEnabled(false);
        queue.execute(new Runnable() {
            @Override
            public void run() {
                int code;
                try {
                    code = task.run();
                } catch (Throwable t) {
                    appendLine("! 异常：" + t);
                    code = -1;
                }
                final int c = code;
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        appendLine("──── 退出码 " + c + " ────");
                        busy = false;
                        setButtonsEnabled(true);
                    }
                });
            }
        });
    }

    private void runShell(String label, final String script, final long timeoutMs) {
        submit(label, new Task() {
            @Override
            public int run() {
                appendLine("$ su -c '" + script + "'");
                return Shell.run(Shell.su(script), null, new Shell.LineSink() {
                    @Override
                    public void onLine(String line) {
                        appendLine(line);
                    }
                }, timeoutMs);
            }
        });
    }

    private void doInstall() {
        submit("安装/更新 payload", new Task() {
            @Override
            public int run() {
                boolean ok = Payload.install(MainActivity.this, new Shell.LineSink() {
                    @Override
                    public void onLine(String line) {
                        appendLine(line);
                    }
                });
                if (ok) {
                    getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                            .putInt(KEY_PAYLOAD_VERSION, PAYLOAD_VERSION).apply();
                }
                return ok ? 0 : 1;
            }
        });
    }

    private void maybeAutoInstall() {
        SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (sp.getInt(KEY_PAYLOAD_VERSION, 0) == PAYLOAD_VERSION) {
            appendLine("payload 版本 v" + PAYLOAD_VERSION + " 已安装。");
            appendLine("（若被清掉，点「安装/更新 payload」重装。）");
            runRootProbe();
            return;
        }
        appendLine("首次启动：自动安装 payload…");
        doInstall();
    }

    private void runRootProbe() {
        submit("检查 root", new Task() {
            @Override
            public int run() {
                appendLine("$ su -c 'id'");
                return Shell.run(Shell.su("id"), null, new Shell.LineSink() {
                    @Override
                    public void onLine(String line) {
                        appendLine(line);
                    }
                }, 120000L);
            }
        });
    }

    private void confirmEnter() {
        new android.app.AlertDialog.Builder(this)
                .setTitle("进入 Linux？")
                .setMessage("安卓的 framework 会被停掉，屏幕会黑约 10–30 秒，"
                        + "然后由 KWin 接管点亮。\n\n"
                        + "请先保存所有工作。\n"
                        + "长按电源键是逃生阀。")
                .setPositiveButton("接管", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int w) {
                        runShell("进入 Linux（接管）",
                                "sh " + ANDROID_DIR + "/enter.sh", 900000L);
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void showLogs() {
        final String L = Shell.PAYLOAD + "/logs";
        submit("查看日志", new Task() {
            @Override
            public int run() {
                String script = ""
                        + "L=" + L + "\n"
                        + "echo \"== 日志目录 $L ==\"\n"
                        + "ls -l \"$L\" 2>/dev/null || echo '(日志目录还不存在)'\n"
                        + "echo\n"
                        + "for f in \"$L\"/*.log; do\n"
                        + "  [ -f \"$f\" ] || continue\n"
                        + "  echo \"──────── $f ────────\"\n"
                        + "  tail -n 80 \"$f\"\n"
                        + "  echo\n"
                        + "done\n";
                int code = Shell.run(Shell.su(script), null, new Shell.LineSink() {
                    @Override
                    public void onLine(String line) {
                        appendLine(line);
                    }
                }, 120000L);

                List<String> svc = WatchService.snapshot();
                appendLine("");
                appendLine("════ 托管守护缓冲（" + svc.size() + " 行）════");
                if (svc.isEmpty()) {
                    appendLine("(空 —— 未启用托管守护，或还没有输出)");
                } else {
                    for (String l : svc) {
                        appendLine(l);
                    }
                }
                return code;
            }
        });
    }

    // ───────────────────────────────────────── 前台服务

    private void toggleService() {
        Intent i = new Intent(this, WatchService.class);
        if (WatchService.running) {
            i.setAction(WatchService.ACTION_STOP);
            // 服务已在运行且界面在前台，startService 合法
            startService(i);
            appendLine("已请求停止托管守护。");
        } else {
            i.setAction(WatchService.ACTION_START);
            startForegroundService(i);
            appendLine("已请求启动托管守护（前台服务）。");
        }
        ui.postDelayed(new Runnable() {
            @Override
            public void run() {
                refreshServiceLabel();
            }
        }, 800L);
    }

    private void askNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            return;
        }
        requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, 1);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshServiceLabel();
    }
}

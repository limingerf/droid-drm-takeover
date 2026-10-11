#!/system/bin/sh
# android/exit-watch.sh — 安卓侧"返回安卓"守护进程的启动器。
#
# 容器里的「返回安卓」按钮只会 `touch /root/.drm-exit-request`。
# 这个守护每秒轮询共享目录，发现请求后停容器并整机重启。
#
# ★ 为什么需要它常驻：容器与安卓是两个 PID 命名空间，容器里的进程
#   没法直接让安卓重启。必须有一个安卓侧的东西在听。
#
# 用法:
#   启动  su -c 'sh .../android/exit-watch.sh start'
#   停止  su -c 'sh .../android/exit-watch.sh stop'
#   状态  su -c 'sh .../android/exit-watch.sh status'
#   前台  su -c 'sh .../android/exit-watch.sh run'
#
# 开机自启：用 android/boot-install.sh 装到 KernelSU /data/adb/service.d/

set -u

# ★ 与 android/enter.sh 用同一个 payload 根：/data/local/drm-takeover。
#   这里同样以 root 执行，所以绝不能落在 shell 可写的 /data/local/tmp。
DRM_PAYLOAD=${DRM_PAYLOAD:-/data/local/drm-takeover}
DRM_SIDE=android
export DRM_SIDE
export PATH="/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:/sbin:/bin:$PATH"

DRM_ROOT=$DRM_PAYLOAD
SW="$DRM_ROOT/core/switch.sh"
LOG="$DRM_ROOT/logs/exit-watch.log"
PIDF="$DRM_ROOT/.exit-watch.pid"

[ -f "$SW" ] || { echo "找不到 $SW" >&2; exit 1; }
mkdir -p "$DRM_ROOT/logs" 2>/dev/null

_alive() {
    [ -f "$PIDF" ] || return 1
    _p=$(cat "$PIDF" 2>/dev/null)
    [ -n "$_p" ] && [ -d "/proc/$_p" ]
}

case "${1:-start}" in
    run)
        # 前台运行（给 init/service.d 或 APK 的前台服务用）
        exec sh "$SW" watch
        ;;
    start)
        if _alive; then
            echo "已在运行（pid=$(cat "$PIDF")）"
            exit 0
        fi
        rm -f "$PIDF" 2>/dev/null
        echo "启动返回守护…"
        setsid nohup sh "$SW" watch >>"$LOG" 2>&1 &
        sleep 2
        if _alive; then
            echo "已启动（pid=$(cat "$PIDF")）"
        else
            echo "启动失败，见 $LOG" >&2
            tail -n 20 "$LOG" 2>/dev/null >&2
            exit 1
        fi
        ;;
    stop)
        sh "$SW" watch-stop >/dev/null 2>&1
        if _alive; then
            _p=$(cat "$PIDF")
            kill -9 "$_p" 2>/dev/null
            sleep 1
        fi
        rm -f "$PIDF" 2>/dev/null
        echo "已停止"
        ;;
    status)
        if _alive; then
            echo "running pid=$(cat "$PIDF")"
            exit 0
        fi
        echo "not running"
        exit 1
        ;;
    *)
        echo "用法: $0 {start|stop|status|run}" >&2
        exit 2
        ;;
esac

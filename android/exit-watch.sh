#!/system/bin/sh
# android/exit-watch.sh — 安卓侧接管守护的启动器。
#
# ══ 它守的是什么 ══
# 容器与安卓是两个 PID 命名空间，容器里的进程既停不了安卓的服务、也重启
# 不了安卓。而**接管必须停 surfaceflinger 和 composer HAL**，返回安卓必须
# 整机重启 —— 两件事都只有安卓侧做得到。
# 所以方向反过来：容器写请求文件，这个守护轮询并执行。
#
#   容器 → 安卓： enter.request（进 Linux）/ exit.request（回安卓）
#   安卓 → 容器： enter.result / device / serial / heartbeat
#
# 完整协议见 core/lib/request.sh。文件名保留 exit-watch 是历史原因
# （它最早只管返回安卓），APK、boot-install.sh 与文档都按这个名字引用。
#
# ★ 为什么容器不能直接调 adb（实测，不是推测）：
#   Droidspaces v6.6.0 的容器里 /dev/bus/usb 不存在（没有 USB 节点），
#   adbd 也没监听 TCP ⇒ 容器里 `adb devices` **恒为空**。
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

[ -f "$SW" ] || { echo "找不到 $SW" >&2; exit 1; }
mkdir -p "$DRM_ROOT/logs" 2>/dev/null

# ★ 存活判据必须问 switch.sh —— 真正写 pid 文件的是 cmd_watch，
#   它写的是 $DRM_RUN_DIR/watch.pid。本脚本原来自己查一个
#   `$DRM_ROOT/.exit-watch.pid`，而**没有任何代码会创建它**，
#   于是 `start` 永远报"启动失败"（哪怕守护已经正常跑起来了），
#   而 `stop` 的 kill 分支也永远不执行。
_alive() {
    sh "$SW" watch-status >/dev/null 2>&1
}

_watcher_pid() {
    sh "$SW" watch-status 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
}

case "${1:-start}" in
    run)
        # 前台运行（给 init/service.d 或 APK 的前台服务用）
        exec sh "$SW" watch
        ;;
    start)
        if _alive; then
            echo "已在运行（pid=$(_watcher_pid)）"
            exit 0
        fi
        echo "启动接管守护…"
        setsid nohup sh "$SW" watch >>"$LOG" 2>&1 &
        sleep 2
        if _alive; then
            echo "已启动（pid=$(_watcher_pid)）"
        else
            echo "启动失败，见 $LOG" >&2
            tail -n 20 "$LOG" 2>/dev/null >&2
            exit 1
        fi
        ;;
    stop)
        sh "$SW" watch-stop >/dev/null 2>&1
        sleep 2
        if _alive; then
            _p=$(_watcher_pid)
            [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
            sleep 1
        fi
        if _alive; then
            echo "停止失败（仍在跑）" >&2
            exit 1
        fi
        echo "已停止"
        ;;
    status)
        if _alive; then
            echo "running pid=$(_watcher_pid)"
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

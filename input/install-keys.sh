#!/bin/sh
# input/install-keys.sh — 装并起「硬件按键守护」drm-keys.py。
#
# 干什么：
#   把 drm-keys.py 放到 /usr/local/bin/，杀掉旧实例，再以后台常驻方式拉起。
#   幂等：重复跑只会重启守护，不会叠加实例（守护自己还有 flock 单例）。
#
# 为什么单独一个脚本而不是塞进 session-up.sh：
#   · 守护要能在**不重跑整个接管**的情况下单独重起（调参、修 bug 时最常用）。
#   · session-up.sh 只负责"会话起来"，按键守护是会话起来之后的常驻件，
#     和 keepbright 守护同类。这里给它一个明确的入口。
#
# 用法：
#   sh install-keys.sh              装 + 起
#   sh install-keys.sh --stop       只停
#   sh install-keys.sh --status     看状态
#
# 环境变量（透传给守护）：VOL_STEP / LONG_MS / DEBOUNCE_MS / SCREEN_WATCHDOG_S
set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
SRC="$SELF_DIR/drm-keys.py"
DST=/usr/local/bin/drm-keys.py
PIDF=/run/drm-keys.pid
LOG=/run/drm-keys.log
LOCK=/run/drm-keys.lock

say() { printf '%s\n' "$*"; }

stop_daemon() {
    if [ -f "$PIDF" ]; then
        _p=$(cat "$PIDF" 2>/dev/null)
        case "$_p" in
            ''|*[!0-9]*) : ;;
            *)
                if kill -0 "$_p" 2>/dev/null; then
                    # ★ 必须发 TERM 而不是 KILL：守护的 TERM handler 会先把
                    #   屏幕恢复亮（否则守护死了屏幕还黑着，用户按电源键也没人听）。
                    kill -TERM "$_p" 2>/dev/null
                    _i=0
                    while [ $_i -lt 20 ] && kill -0 "$_p" 2>/dev/null; do
                        sleep 0.2; _i=$((_i + 1))
                    done
                    kill -0 "$_p" 2>/dev/null && kill -KILL "$_p" 2>/dev/null
                    say "已停旧守护 pid=$_p"
                fi ;;
        esac
    fi
    # pidfile 丢了但进程还在（例如被外部 kill -9）：按 cmdline 兜底
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _cl=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null)
        case "$_cl" in
            *drm-keys.py*)
                _p=${_d#/proc/}
                [ "$_p" = "$$" ] && continue
                kill -TERM "$_p" 2>/dev/null
                say "兜底停掉 pid=$_p" ;;
        esac
    done
    rm -f "$LOCK" 2>/dev/null
}

case "${1:-}" in
    --stop)
        stop_daemon
        say "已停"
        exit 0 ;;
    --status)
        [ -f "$DST" ] && exec python3 "$DST" --status
        say "还没装（$DST 不存在）"
        exit 1 ;;
esac

if [ ! -f "$SRC" ]; then
    say "找不到 $SRC" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { say "容器里没有 python3" >&2; exit 1; }

stop_daemon
mkdir -p /usr/local/bin
cp "$SRC" "$DST" || { say "拷贝到 $DST 失败" >&2; exit 1; }
chmod 755 "$DST"

# ★ 把运行参数写进一个 env 文件，方便以后调参不用改脚本。
#   守护的默认值已经是本机验证过的，这里只在环境里显式给了才写。
ENVF=/etc/drm-keys.env
if [ -n "${VOL_STEP:-}${LONG_MS:-}${DEBOUNCE_MS:-}${SCREEN_WATCHDOG_S:-}${RUNDIR:-}${DESKTOP_USER:-}${WAYLAND_DISPLAY:-}" ]; then
    {
        echo "# 由 input/install-keys.sh 生成 —— drm-keys.py 的运行参数"
        echo "# 见 input/drm-keys.py 头部注释；改完重跑 install-keys.sh 生效"
        [ -n "${VOL_STEP:-}" ]           && echo "VOL_STEP=${VOL_STEP}"
        [ -n "${LONG_MS:-}" ]            && echo "LONG_MS=${LONG_MS}"
        [ -n "${DEBOUNCE_MS:-}" ]        && echo "DEBOUNCE_MS=${DEBOUNCE_MS}"
        [ -n "${SCREEN_WATCHDOG_S:-}" ]  && echo "SCREEN_WATCHDOG_S=${SCREEN_WATCHDOG_S}"
        [ -n "${RUNDIR:-}" ]             && echo "RUNDIR=${RUNDIR}"
        [ -n "${DESKTOP_USER:-}" ]       && echo "DESKTOP_USER=${DESKTOP_USER}"
        [ -n "${WAYLAND_DISPLAY:-}" ]    && echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
    } >"$ENVF" 2>/dev/null
fi

# 起守护：setsid 脱离当前会话，否则 droidspaces run 退出时会被带走
if [ -f "$ENVF" ]; then
    # shellcheck disable=SC1090
    . "$ENVF"
    export VOL_STEP LONG_MS DEBOUNCE_MS SCREEN_WATCHDOG_S RUNDIR DESKTOP_USER WAYLAND_DISPLAY
fi

setsid nohup python3 "$DST" -d >>"$LOG" 2>&1 &

_i=0
_ok=0
while [ $_i -lt 30 ]; do
    _p=""
    [ -f "$PIDF" ] && _p=$(cat "$PIDF" 2>/dev/null)
    case "$_p" in
        ''|*[!0-9]*) : ;;
        *) [ -d "/proc/$_p" ] && { _ok=1; break; } ;;
    esac
    sleep 0.2; _i=$((_i + 1))
done

if [ "$_ok" = 1 ]; then
    say "drm-keys 已起 pid=$_p"
    exit 0
fi

say "drm-keys 没起来，看 $LOG" >&2
tail -20 "$LOG" 2>/dev/null
exit 1

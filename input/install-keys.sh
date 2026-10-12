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
        # ★ 三个文件都要报：少装 lockscreen.sh 会让电源键静默退化成"只熄屏"，
        #   少装 drmbl 会让"熄面板"退化成"最暗"。
        if [ -f /usr/local/bin/lockscreen.sh ]; then
            say "lockscreen.sh 已装（电源键可锁屏）"
        else
            say "★ lockscreen.sh 未装 ⇒ 电源键只会熄屏，不会锁屏"
        fi
        if [ -x /usr/local/bin/drmbl ]; then
            if /usr/local/bin/drmbl probe >/dev/null 2>&1; then
                say "drmbl 已装且可用（面板可真正熄灭）"
            else
                say "★ drmbl 装了但拿不到 master fd ⇒ 面板只会「最暗」，不会全黑"
            fi
        else
            say "★ drmbl 未装 ⇒ 面板只会「最暗」，不会全黑"
        fi
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

# ★★★ 锁屏辅助脚本必须和 drm-keys.py **放在同一目录** ★★★
#
# drm-keys.py 里的 LOCK_SCRIPT 是 `dirname(__file__)/lockscreen.sh`。
# 电源键短按要调它来完成「锁屏 + 熄面板」。
#
# ⚠️ 少装它不会报错 —— 代码里有回退路径（_lock_run 返回 127 ⇒ 退化成
#    普通的"只熄屏"）。也就是说**表面上电源键还能用，实际没有锁屏**。
#    这种静默降级是最难查的一类问题，所以这里必须装，且失败要出声。
LOCKS="$SELF_DIR/lockscreen.sh"
LOCKDST=/usr/local/bin/lockscreen.sh
if [ -f "$LOCKS" ]; then
    if cp "$LOCKS" "$LOCKDST"; then
        chmod 755 "$LOCKDST"
    else
        say "警告：拷贝 lockscreen.sh 到 $LOCKDST 失败 ⇒ 电源键将退化为「只熄屏」" >&2
    fi
else
    say "警告：找不到 $LOCKS ⇒ 电源键将退化为「只熄屏」（没有锁屏）" >&2
fi

# ★★★ 熄面板的工具 drmbl 也必须装 ★★★
#
# lockscreen.sh 的 panel-off 靠 `drmbl blank` 把 DRM connector 的 brightness
# 写成 0 —— 这是本机**唯一**有效的熄屏手段（sysfs 那条路被内核 bypass 了，
# 见 input/lockscreen.sh 文件头）。少了它，电源键只会「锁屏 + 最暗」，
# 面板并不会真正熄灭。
#
# 跟 lockscreen.sh 一样，少装它是**静默降级**（_drmbl_run 返回 127，日志里
# 只会有一行 "!! drmbl blank 失败"），所以这里必须装，且失败要出声。
DRMBL_SRC=""
for _c in "$SELF_DIR/../bin/drmbl" "$SELF_DIR/drmbl"; do
    [ -x "$_c" ] && { DRMBL_SRC=$_c; break; }
done
DRMBL_DST=/usr/local/bin/drmbl
if [ -n "$DRMBL_SRC" ]; then
    if cp "$DRMBL_SRC" "$DRMBL_DST" && chmod 755 "$DRMBL_DST"; then
        # 装完立刻自检：它必须真的能从 KWin 那里拿到 master fd，
        # 否则装了个跑不起来的二进制比不装更糟（看起来"装了"）。
        if ! "$DRMBL_DST" probe >/dev/null 2>&1; then
            say "警告：drmbl 装好了但 probe 失败（拿不到 DRM master fd）" >&2
            say "      ⇒ 电源键会退化为「锁屏 + 最暗」，面板不会真正熄灭" >&2
            "$DRMBL_DST" probe 2>&1 | sed 's/^/      /' >&2
        fi
    else
        say "警告：拷贝 drmbl 到 $DRMBL_DST 失败 ⇒ 面板无法真正熄灭（只会最暗）" >&2
    fi
else
    say "警告：找不到 bin/drmbl（先跑 make runtime）⇒ 面板无法真正熄灭（只会最暗）" >&2
fi

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

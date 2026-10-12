#!/bin/sh
# display/powerdevil-enable.sh — 让 plasma-powerdevil 真正跑起来，并把亮度控制接到真背光
#
# ══════════════════════════════════════════════════════════════════════
# 这个脚本修的是什么（三条**互相独立**的断点，缺一条亮度就调不了）
# ══════════════════════════════════════════════════════════════════════
#
# 症状：KDE 里有亮度滑块（或 Fn 亮度键 / 托盘图标），但拖了没反应。
#
# 断点 ①：plasma-powerdevil.service 根本没被拉起
#   它是 `static`（没有 [Install] 段），靠 graphical-session.target 被拉。
#   而本项目的桌面是绕过 startplasma-wayland 手工起的 ⇒ 那个 target 从来没
#   激活过 ⇒ PowerDevil 一次都没启动 ⇒ 没人接亮度滑块。
#   实测：systemctl --user is-active plasma-powerdevil → inactive
#         systemctl --user is-system-running      → degraded
#
# 断点 ②：手工拉起会 SIGABRT
#   因为 systemd --user 的环境里没有 WAYLAND_DISPLAY（同样是绕过
#   startplasma 的后果）。PowerDevil 是 Qt Wayland 客户端，缺了它直接 abort：
#     Failed to create wl_display (No such file or directory)
#     Could not load the Qt platform plugin "wayland"
#   ⇒ 本脚本装 display/powerdevil-wayland-env.conf 作为 drop-in 补上。
#
# 断点 ③：背光探测器永远失败（KAuth 走不通）
#   PowerDevil 读背光走 KAuth → 系统总线 org.kde.powerdevil.backlighthelper，
#   那个名字由 dbus-daemon 激活；而本容器 rootfs 是 **nosuid**，
#   setuid 的 dbus-daemon-launch-helper 失效 ⇒ 任何 User= 的 system service
#   都起不来。实测报错：
#     "DBus Backend error: service start org.kde.powerdevil.backlighthelper
#      failed: The permission of the setuid helper is not correct"
#   ⇒ 本脚本装 display/powerdevil-backlight-helper.service，
#     让 systemd(PID 1, root) 常驻把 helper 拉起来（详见该文件顶部注释）。
#
# 另外：PowerDevil 一旦跑起来，它的**默认空闲策略**会按 5 分钟变暗 /
#   10 分钟熄屏把背光打到全黑。本设备的兜底只有长按电源键，所以本脚本
#   同时装 display/powerdevilrc 把这两个动作关掉（A/B 实测见该文件）。
#
# ══════════════════════════════════════════════════════════════════════
# 用法
# ══════════════════════════════════════════════════════════════════════
#   sh display/powerdevil-enable.sh            装上并启动（幂等）
#   sh display/powerdevil-enable.sh --check    只检查现状，不改任何东西
#   sh display/powerdevil-enable.sh --revert   撤销本脚本的全部改动
#
# ══════════════════════════════════════════════════════════════════════

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

HELPER_UNIT=/etc/systemd/system/droidspaces-backlight-helper.service
HELPER_SRC="$SELF_DIR/powerdevil-backlight-helper.service"
DROPIN_SRC="$SELF_DIR/powerdevil-wayland-env.conf"
RC_SRC="$SELF_DIR/powerdevilrc"

ACTION=${1:-install}
# 本次运行有没有改动 drop-in / powerdevilrc —— 决定要不要重启 PowerDevil
PD_CHANGED=0

# ─────────────────────── 环境解析 ───────────────────────

# Wayland socket 名。
#
# ★ 不能写死 wayland-0：本项目 KWin 是用 `--socket=taketest` 起的
#   （core/lib/display.sh 里的 $_sock），实测名字就是 taketest。
# ★ 判据与 input/drm-keys.py 的 detect_wayland_display() 保持一致：
#   "是 unix socket 且存在同名 .lock"。Wayland 协议要求服务端建
#   <socket>.lock 做互斥，所以这个判据比"名字以 wayland- 开头"可靠得多
#   （本机 wayland-0 是个残留死 socket）。
pd_socket_resolve() {
    _rd=$1
    _best=
    for _p in "$_rd"/*; do
        [ -S "$_p" ] || continue
        _n=${_p##*/}
        case "$_n" in
            pipewire*|pulse*|bus|systemd*|gnupg*|dconf*|gvfs*|ssh*|drkonqi*|openssh*)
                continue ;;
        esac
        [ -e "$_p.lock" ] || continue
        case "$_n" in
            wayland-*) printf '%s\n' "$_n"; return 0 ;;
        esac
        [ -n "$_best" ] || _best=$_n
    done
    [ -n "$_best" ] && { printf '%s\n' "$_best"; return 0; }
    return 1
}

# 以桌面用户 + 会话总线身份执行。返回它的输出。
#
# ★ 为什么必须降权：PowerDevil / busctl --user 要的是**会话总线**，
#   root 直接跑会连到 root 自己的 user manager（或者根本连不上）。
#   实测：systemctl --user 以 root 跑 → "Failed to connect to user scope bus
#   via local transport: Operation not permitted"（systemd 只接受自己的 uid）。
pd_as_desktop() {
    _env="XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus"
    [ -n "$PD_SOCKET" ] && _env="$_env WAYLAND_DISPLAY=$PD_SOCKET"
    if drm_have runuser; then
        # shellcheck disable=SC2086
        runuser -u "$DESKTOP_USER" -- env $_env "$@" 2>&1
    else
        su -s /bin/sh -c "env $_env $*" "$DESKTOP_USER" 2>&1
    fi
}

pd_user_systemctl() {
    drm_have systemctl || { drm_warn "容器里没有 systemctl，跳过"; return 0; }
    pd_as_desktop systemctl --user "$@"
}

pd_system_systemctl() {
    drm_have systemctl || { drm_warn "容器里没有 systemctl，跳过"; return 0; }
    systemctl "$@"
}

# ─────────────────────── 安装 ───────────────────────

pd_install_helper_unit() {
    drm_phase "① 装 KAuth 背光助手单元（绕开 nosuid 的 dbus launch-helper）"
    if [ ! -f "$HELPER_SRC" ]; then
        drm_warn "找不到 $HELPER_SRC"
        return 1
    fi
    cp -f "$HELPER_SRC" "$HELPER_UNIT" || { drm_warn "写 $HELPER_UNIT 失败"; return 1; }
    chmod 644 "$HELPER_UNIT"
    pd_system_systemctl daemon-reload
    pd_system_systemctl enable --now droidspaces-backlight-helper.service
    sleep 2
    if pd_system_systemctl is-active --quiet droidspaces-backlight-helper.service; then
        drm_log "  助手已在跑：$(busctl --system list 2>/dev/null | grep -c backlighthelper) 个总线名"
    else
        drm_warn "  助手没起来，KAuth 那条路仍然是断的"
        return 1
    fi
}

pd_install_dropin() {
    drm_phase "② 给 plasma-powerdevil 补 Wayland 环境"
    _dir="$DESKTOP_HOME/.config/systemd/user/plasma-powerdevil.service.d"
    mkdir -p "$_dir" || { drm_warn "建不出 $_dir"; return 1; }
    if [ ! -f "$DROPIN_SRC" ]; then
        drm_warn "找不到 $DROPIN_SRC"
        return 1
    fi
    _tmp="$_dir/.10-wayland-env.conf.new"
    sed "s|@WAYLAND_DISPLAY@|$PD_SOCKET|g" "$DROPIN_SRC" >"$_tmp" \
        || { drm_warn "写 drop-in 失败"; return 1; }
    # ★ 内容没变就**不重写**：改写时间戳会让下面的"要不要 restart"判断
    #   误以为配置变了，于是无谓地重启一次 PowerDevil。实测连续两次
    #   restart 之间 KWin 侧的 kde_external_brightness_v1 握手会来不及，
    #   短暂出现"没有任何可调屏"（as 0）的假故障。
    if cmp -s "$_tmp" "$_dir/10-wayland-env.conf"; then
        rm -f "$_tmp"
        drm_log "  drop-in 已是最新，未改动"
    else
        mv -f "$_tmp" "$_dir/10-wayland-env.conf"
        PD_CHANGED=1
        drm_log "  WAYLAND_DISPLAY=$PD_SOCKET → $_dir/10-wayland-env.conf"
    fi
    # ★ 必须 644。systemd 对 world-writable 的 drop-in 会告警
    #   （"is marked world-writable. Please remove world writability"），
    #   而且默认 umask 000 的容器里 `cat >` 出来就是 666。
    chmod 644 "$_dir/10-wayland-env.conf"
    chown -R "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/.config/systemd/user" 2>/dev/null
}

pd_install_rc() {
    drm_phase "③ 装 PowerDevil 配置（关掉空闲变暗/熄屏）"
    _rc="$DESKTOP_HOME/.config/powerdevilrc"
    if cmp -s "$RC_SRC" "$_rc"; then
        drm_log "  $_rc 已是最新，未改动"
        return 0
    fi
    if [ -f "$_rc" ] && ! grep -q 'TurnOffDisplayWhenIdle=false' "$_rc" 2>/dev/null; then
        _bak="$_rc.bak-$(date +%Y%m%d-%H%M%S)"
        cp -a "$_rc" "$_bak" && drm_log "  已备份原配置 → $_bak"
    fi
    cp -f "$RC_SRC" "$_rc" || { drm_warn "写 $_rc 失败"; return 1; }
    chmod 644 "$_rc"
    chown "$DESKTOP_USER:$DESKTOP_USER" "$_rc" 2>/dev/null
    PD_CHANGED=1
    drm_log "  已装 $_rc"
}

pd_restart() {
    # ★ 已经在跑而且配置没变 ⇒ **不要**动它。
    #   无谓 restart 的代价：PowerDevil 要重新跟 KWin 走一轮
    #   kde_external_brightness_v1 握手，这期间亮度控制会短暂失效；
    #   而且用户正在调的亮度会被重置。
    _st=$(pd_user_systemctl is-active plasma-powerdevil.service)
    if [ "$_st" = "active" ] && [ "$PD_CHANGED" != "1" ]; then
        drm_phase "④ PowerDevil 已在跑且配置无变化 —— 不重启"
        return 0
    fi
    _reason="服务未运行"
    [ "$_st" = "active" ] && _reason="配置有变化"
    drm_phase "④ 重启 PowerDevil（原因：$_reason）"
    pd_user_systemctl daemon-reload
    pd_user_systemctl restart plasma-powerdevil.service
    sleep 5
}

# ─────────────────────── 自证 ───────────────────────

pd_check() {
    drm_phase "自证"

    if [ -z "$PD_SOCKET" ]; then
        drm_warn "探不到 Wayland socket —— PowerDevil 会 SIGABRT"
    else
        drm_log "  Wayland socket = $PD_SOCKET"
    fi

    _st=$(pd_user_systemctl is-active plasma-powerdevil.service)
    drm_log "  plasma-powerdevil.service = $_st"
    [ "$_st" = "active" ] || drm_warn "  ✗ 服务没在跑"

    _pid=$(pd_user_systemctl show plasma-powerdevil.service -p MainPID --value)
    drm_log "  MainPID = ${_pid:-（查不到）}"

    # ★ 别用 `busctl list | grep -c 'name$'`：busctl 的表格里名字后面还有
    #   PID/USER/… 几列，`$` 永远匹配不上，会得到恒为 0 的假阴性
    #   （实测踩过）。改成"问它一个问题，看答不答"——功能性判据。
    _prof=$(pd_as_desktop busctl --user call org.kde.Solid.PowerManagement \
        /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement currentProfile 2>/dev/null)
    drm_log "  currentProfile = ${_prof:-（问不到，服务没上总线）}"
    case "$_prof" in
        s\ *) drm_log "  ✓ org.kde.Solid.PowerManagement 在线" ;;
        *)    drm_warn "  ✗ 名字没上总线，PowerDevil 没起来" ;;
    esac

    # ★ 要重试：PowerDevil 起来之后还要跟 KWin 走一轮
    #   kde_external_brightness_v1 握手（导出亮度设备），
    #   这期间 DisplaysDBusNames 会是空的 `as 0`。实测刚 restart 完立刻问
    #   就会拿到 `as 0`，白报一次"背光探测器还是失败"。最多等 20s。
    _disp=""
    _try=0
    while [ "$_try" -lt 10 ]; do
        _disp=$(pd_as_desktop busctl --user get-property org.kde.ScreenBrightness \
            /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames 2>/dev/null)
        case "$_disp" in
            *display*) break ;;
        esac
        sleep 2
        _try=$((_try + 1))
    done
    drm_log "  可调亮度的屏 = ${_disp:-（读不到）}（等了 $((_try * 2))s）"
    case "$_disp" in
        *display*) drm_log "  ✓ 至少有一块屏可调" ;;
        *) drm_warn "  ✗ 没有可调屏 —— 背光探测器还是失败" ;;
    esac

    _max=$(pd_as_desktop busctl --user get-property org.kde.ScreenBrightness \
        /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display MaxBrightness 2>/dev/null)
    drm_log "  display0 MaxBrightness = $_max"
    case "$_max" in
        *10000*) drm_log "  ✓ 是 KWin 侧的量程（0-10000）" ;;
        *) drm_warn "  ? 量程不是 10000，可能是别的探测器" ;;
    esac

    _bl=$(drm_backlight_node 2>/dev/null || true)
    if [ -n "$_bl" ]; then
        drm_log "  当前 sysfs 背光 = $(cat "/sys/class/backlight/$_bl/brightness" 2>/dev/null)/$(cat "/sys/class/backlight/$_bl/max_brightness" 2>/dev/null)"
    fi

    drm_log '  （想验「写下去真的到 sysfs」，跑：sh display/brightness.sh selftest）'
}

# ─────────────────────── 撤销 ───────────────────────

pd_revert() {
    drm_phase "撤销"

    # ★★ 停 PowerDevil **之前**先把当前背光记下来。
    #
    #   实测（2026-10-12）：`systemctl --user stop plasma-powerdevil` 之后
    #   背光会被打到 **0**（全黑）——PowerDevil 退出时把它管的屏
    #   reset 到 knownSafeBrightnessMin=0，而这时候 KWin 的
    #   kde_external_brightness_v1 亮度设备也跟着没了，没有别人会把它写回来。
    #   本设备的兜底只有长按电源键，所以**撤销路径必须自己把背光恢复**。
    #
    #   （对比：`restart` 不会出这个问题 —— 新实例起来会重新接管并写回
    #     当前值。只有"停掉且不重启"才有这个坑。）
    _bl=$(drm_backlight_node 2>/dev/null || true)
    _saved=""
    _max=""
    if [ -n "$_bl" ]; then
        _saved=$(cat "/sys/class/backlight/$_bl/brightness" 2>/dev/null)
        _max=$(cat "/sys/class/backlight/$_bl/max_brightness" 2>/dev/null)
    fi
    # 记不到就退回设备层默认亮度（core/device/opd2511.sh: DEV_BRIGHTNESS=2048）
    case "$_saved" in ''|*[!0-9]*) _saved=${DEV_BRIGHTNESS:-2048} ;; esac
    case "$_max"   in ''|*[!0-9]*) _max=4095 ;; esac
    drm_log "  撤销前背光 = $_saved/$_max"

    pd_user_systemctl stop plasma-powerdevil.service
    rm -f "$DESKTOP_HOME/.config/systemd/user/plasma-powerdevil.service.d/10-wayland-env.conf"
    rmdir "$DESKTOP_HOME/.config/systemd/user/plasma-powerdevil.service.d" 2>/dev/null
    pd_user_systemctl daemon-reload
    pd_system_systemctl disable --now droidspaces-backlight-helper.service 2>/dev/null
    rm -f "$HELPER_UNIT"
    pd_system_systemctl daemon-reload

    if [ -n "$_bl" ]; then
        sleep 2
        _now=$(cat "/sys/class/backlight/$_bl/brightness" 2>/dev/null)
        # 低于 5% 就认为被 reset 了，恢复回去
        _floor=$((_max / 20))
        case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
        if [ "$_now" -lt "$_floor" ]; then
            drm_warn "  背光被 reset 到 $_now，恢复成 $_saved"
            echo "$_saved" >"/sys/class/backlight/$_bl/brightness" 2>/dev/null
            sleep 1
            drm_log "  恢复后背光 = $(cat "/sys/class/backlight/$_bl/brightness" 2>/dev/null)"
        else
            drm_log "  背光保持在 $_now，无需恢复"
        fi
    fi

    drm_log "已撤销（powerdevilrc 保留，它只是关掉空闲熄屏；要还原就删掉那几个段）"
    drm_log "★ 撤销后 KDE 侧没有亮度控制了；想调亮度用：sh display/brightness.sh raw <0-4095>"
}

# ─────────────────────── 入口 ───────────────────────

drm_desktop_user_resolve
PD_SOCKET=$(pd_socket_resolve "$DESKTOP_RUNTIME_DIR" || true)

case "$ACTION" in
    install|--install)
        drm_log "PowerDevil 启用：用户=$DESKTOP_USER runtime=$DESKTOP_RUNTIME_DIR socket=${PD_SOCKET:-未探到}"
        pd_install_helper_unit || true
        pd_install_dropin     || true
        pd_install_rc         || true
        pd_restart
        pd_check
        ;;
    check|--check)
        pd_check
        ;;
    revert|--revert)
        pd_revert
        ;;
    *)
        echo "用法: sh $0 [install|--check|--revert]" >&2
        exit 2
        ;;
esac

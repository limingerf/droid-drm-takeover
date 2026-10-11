#!/bin/sh
# core/switch.sh — 统一切换控制器（状态机 + 子命令）。
#
# ══ 为什么需要它 ══
# 重构前有三个互不知情的入口：
#   · drm-takeover.sh   一次性试验，MODE=kwin 才起 kwin，不起桌面
#   · desk-takeover.sh  无条件起 kwin + Plasma + WiFi
#   · ade.sh（参考仓库） 安卓侧十阶段
# 三者各自维护自己的阶段与回滚，env 块还不一样（KWINWRAP_LEASE vs
# KWINWRAP_FILTER），同一台设备上行为不可复现、排障无法互相印证。
# 唯一的状态是 `takeover.ok` 一个空文件——布尔、无时间戳、无模式、
# 无 PID，而且 drm-takeover.sh 在结尾无条件 touch 它，把自己的保险丝判据弄失效。
#
# 现在：一个状态机、一套阶段、一份日志、一把锁。
#
# ══ 子命令 ══
#   enter     进入 Linux（★ 必须在安卓侧执行）
#   exit      返回安卓（★ 安卓侧执行；动作 = 停容器 + 整机重启）
#   rollback  接管中途放弃，原地把安卓拉回来（尽力而为）
#   status    打印当前状态（两侧都能跑）
#   doctor    环境体检（两侧都能跑）
#   watch     安卓侧常驻守护：轮询共享目录里的退出请求
#
# ══ 用法 ══
#   安卓侧:  su -c 'sh /data/local/drm-takeover/core/switch.sh enter'
#   容器侧:  sh /root/droid-drm-takeover/core/switch.sh status
#
# ══ 环境变量（全部可选）══
#   DRM_DEVICE=opd2511     强制指定设备适配层
#   FULL_STOP=1            连 framework 一起 stop（⚠️ 会永久毁掉音频，默认关）
#   DRM_NET=0              跳过网络接管
#   DRM_WIFI_SSID/PSK      直接给凭据（否则从安卓读）
#   DRM_WAYLAND_SOCKET     合成器 socket 名（默认 taketest）
#   DRM_ADB_SERIAL         容器侧指定 adb 序列号

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/common.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/device.sh"
drm_device_load
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/android.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/container.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/display.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/net.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/enter.sh"

drm_state_init
drm_state_set DEVICE "$DEV_CODENAME"
drm_state_set SIDE "$DRM_SIDE"
drm_state_set BOOT_ID "$(drm_boot_id)"

# 重启后旧状态要能自愈：BOOT_ID 变了说明上一轮已经随重启结束
_bid=$(drm_state_get BOOT_ID 2>/dev/null || true)
_cur_bid=$(drm_boot_id)
if [ -n "$_cur_bid" ] && [ -n "$_bid" ] && [ "$_bid" != "$_cur_bid" ]; then
    drm_state_set PHASE android-active
    drm_state_set BOOT_ID "$_cur_bid"
    drm_state_set LAST_ERROR ""
fi

# ═══════════════════════════════════════════════════════════
# doctor — 环境体检
# ═══════════════════════════════════════════════════════════

cmd_doctor() {
    _fail=0
    _ok()   { printf '  [ OK ] %s\n' "$*"; }
    _bad()  { printf '  [FAIL] %s\n' "$*"; _fail=$((_fail + 1)); }
    _warn() { printf '  [warn] %s\n' "$*"; }

    printf '══ 设备 ══\n'
    printf '  适配层   : %s (%s)\n' "$DRM_DEVICE" "$DEV_MODEL"
    printf '  平台     : %s\n' "$DEV_PLATFORM"
    printf '  当前侧   : %s\n' "$DRM_SIDE"
    printf '  面板     : %sx%s\n' "$DEV_PANEL_W" "$DEV_PANEL_H"

    printf '══ 显示 ══\n'
    [ -c "$DEV_DRM_CARD" ] && _ok "存在 $DEV_DRM_CARD" || _bad "缺 $DEV_DRM_CARD"
    if [ -e "$DEV_DRM_RENDER" ]; then _ok "存在 $DEV_DRM_RENDER"; else _warn "缺 $DEV_DRM_RENDER（Mesa/EGL 可能受限）"; fi
    [ -e /dev/kgsl-3d0 ] && _ok "存在 /dev/kgsl-3d0（渲染链）" || _warn "缺 /dev/kgsl-3d0"

    if drm_android_side; then
        printf '══ 安卓服务 ══\n'
        printf '  %-28s = %s\n' "$DEV_SF_SVC" "$(android_svc_state "$DEV_SF_SVC")"
        printf '  %-28s = %s\n' "$DEV_COMPOSER_SVC" "$(android_svc_state "$DEV_COMPOSER_SVC")"
        _h=$(android_card_holders 2>/dev/null)
        if [ -n "$_h" ]; then
            _warn "$DEV_DRM_CARD 当前持有者：$_h"
        else
            _ok "$DEV_DRM_CARD 无持有者"
        fi
    fi

    printf '══ 容器 ══\n'
    ds_init
    if ds_available; then
        _ok "Droidspaces：$DS_BIN"
        if ds_running; then _ok "容器 $DS_NAME 在跑"; else _warn "容器 $DS_NAME 没在跑"; fi
    else
        _bad "找不到 Droidspaces：$DS_BIN"
    fi
    if ds_shared_ready; then
        _ok "共享目录可写：$(ds_shared_dir)"
    else
        _warn "共享目录不可写：$(ds_shared_dir)（容器没起时属正常）"
    fi

    if ! drm_android_side; then
        printf '══ 桌面（容器侧）══\n'
        drm_desktop_user_resolve 2>/dev/null && _ok "桌面账号：$DESKTOP_USER (uid=$DESKTOP_UID)"
        for _t in kwinwrap setbright setprop crtcstate connprops; do
            if drm_tool "$_t" >/dev/null 2>&1; then _ok "工具 $_t"; else _bad "缺工具 $_t（先 make）"; fi
        done
        for _c in kwin_wayland plasmashell dbus-daemon runuser; do
            if command -v "$_c" >/dev/null 2>&1; then _ok "命令 $_c"; else _bad "缺命令 $_c"; fi
        done
        _kactiv=$(for c in /usr/lib/*/libexec/kactivitymanagerd /usr/libexec/kactivitymanagerd /usr/bin/kactivitymanagerd; do
                      [ -x "$c" ] && { printf '%s' "$c"; break; }; done)
        [ -n "$_kactiv" ] && _ok "kactivitymanagerd：$_kactiv" || _bad "缺 kactivitymanagerd（plasmashell 会 Aborting shell load）"
        _bl=$(drm_backlight_node 2>/dev/null) && _ok "背光节点：$_bl" || _warn "找不到背光节点"
        _sock=${DRM_WAYLAND_SOCKET:-taketest}
        if [ -S "$DESKTOP_RUNTIME_DIR/$_sock" ]; then _ok "合成器 socket 存在"; else _warn "合成器 socket 不存在（未接管？）"; fi
    fi

    printf '══ 状态 ══\n'
    drm_state_show | sed 's/^/  /'
    _lh=$(drm_lock_holder 2>/dev/null) && printf '  锁       : %s\n' "$_lh" || printf '  锁       : 空闲\n'

    printf '\n'
    if [ "$_fail" -gt 0 ]; then
        drm_err "doctor：$_fail 项不通过"
        return 1
    fi
    drm_log "doctor：全部通过"
    return 0
}

# ═══════════════════════════════════════════════════════════
# enter — 进入 Linux（安卓侧）
# ═══════════════════════════════════════════════════════════

cmd_enter() {
    # 时序实现在 core/lib/enter.sh 的 drm_do_enter()，与容器侧的
    # display/desk-takeover.sh 共用同一套阶段顺序（重构前是两个实现）。
    drm_lock_acquire enter || exit 1
    trap 'drm_lock_release' EXIT INT TERM

    if drm_do_enter; then
        drm_log "回安卓：在桌面里点「返回安卓」图标，或跑 exit 子命令"
        drm_lock_release
        trap - EXIT INT TERM
        return 0
    fi

    drm_lock_release
    trap - EXIT INT TERM
    return 1
}

# ═══════════════════════════════════════════════════════════
# rollback — 接管中途放弃，原地拉回安卓
# ═══════════════════════════════════════════════════════════
#
# ⚠️ 这只是"尽力而为"的原地恢复。已知它会留下半死状态：
#    容器启动破坏了安卓 ueventd 的 netlink（热插拔节点建不出来），
#    停容器**不等于**恢复，只有整机重启能回到干净状态。
#    所以正常路径的 exit 一律走 reboot；rollback 只在"还没起容器"
#    或"用户明确接受半死"时用。
cmd_rollback() {
    drm_log "══ rollback：尝试原地恢复安卓 ══"
    drm_state_set PHASE returning

    # 停容器（如果起了）
    ds_stop 2>/dev/null || true

    # 杀容器侧残留（如果共享目录还挂着）
    if ds_shared_ready 2>/dev/null; then
        ds_exec 'pkill -9 -f kwinwrap; pkill -9 -x kwin_wayland; pkill -9 -x plasmashell' >/dev/null 2>&1 || true
    fi

    # 起回安卓显示栈
    android_start_display
    android_exec "setprop ctl.start system_suspend" 2>/dev/null
    android_start_framework

    # 还原我们改过的东西
    android_watchdog_rearm 2>/dev/null || true
    android_kernel_debug_on 2>/dev/null || true

    # 等 SurfaceFlinger
    _i=0
    while [ "$_i" -lt 24 ]; do
        [ "$(android_svc_state "$DEV_SF_SVC")" = running ] && break
        sleep 5
        _i=$((_i + 1))
        android_start_display
    done

    android_stop_bootanim
    android_wake
    android_dismiss_keyguard
    android_set_brightness

    drm_state_set PHASE android-active
    drm_state_set PHASE_AT "$(drm_ts)"
    drm_log "rollback 完成：SF=$(android_svc_state "$DEV_SF_SVC") composer=$(android_svc_state "$DEV_COMPOSER_SVC")"
    drm_warn "若画面仍异常（USB/pogo 键盘不认、莫名重启），只有整机重启能彻底恢复"
    return 0
}

# ═══════════════════════════════════════════════════════════
# exit — 返回安卓（安卓侧执行；动作 = 停容器 + 整机重启）
# ═══════════════════════════════════════════════════════════
#
# ★ 为什么不"停容器 + 原地起安卓"：
#   参考仓库实测过，结果是半死状态——卡开机界面约 1 分钟，进系统后
#   不定时重启（watchdog 在杀 vendor HAL，被 SELinux 拒：
#   avc: denied { signal } for comm="watchdog"
#   tcontext=u:r:oplus_hal_displaypanelfeature），pogo 键盘也断开。
#   根因是容器启动破坏了安卓 ueventd 的 netlink，热插拔节点全建不出来。
#   这些只有重启能恢复。
#
# ★ 为什么必须 /system/bin/reboot：
#   · `svc power reboot` 走 framework，依赖 system_server；停容器后它
#     **静默返回 0 但什么都不做**（所以 `|| reboot` 这种 fallback 永远不触发）
#   · `setprop sys.powerctl reboot` 在厂商改过的 init 上也无反应
#   只有不依赖 framework 的 /system/bin/reboot 可靠。
cmd_exit() {
    drm_log "══ exit：返回安卓（停容器 → 整机重启）══"
    drm_state_set PHASE returning

    ds_stop 2>/dev/null || true

    # 杀掉可能在推音频的安卓侧进程，释放 socket
    for _p in $(pidof argsloop 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done
    rm -f "$(ds_shared_dir)/hal-direct.sock" 2>/dev/null

    sync
    drm_log "执行 /system/bin/reboot"
    /system/bin/reboot
    # 兜底（正常不会执行到）
    sleep 5
    setprop sys.powerctl reboot 2>/dev/null
    return 0
}

# ═══════════════════════════════════════════════════════════
# watch — 安卓侧常驻守护：轮询共享目录里的退出请求
# ═══════════════════════════════════════════════════════════
#
# 容器里的「返回安卓」按钮只需要 `touch $SHARED/.drm-exit-request`，
# 这里 1s 轮询发现后执行 exit。
#
# ★ 顺序要害：请求文件必须在**停容器之前**删掉——容器一停，
#   共享目录（容器 /root 的 host 侧挂载）就没了，那时再删就删不掉，
#   下次开机它还在，会导致一开机就重启。
cmd_watch() {
    _sh=$(ds_shared_dir)
    _req="$_sh/.drm-exit-request"
    _stop="$DRM_RUN_DIR/.watch-stop"
    _pidf="$DRM_RUN_DIR/watch.pid"

    # 单例
    if [ -f "$_pidf" ]; then
        _op=$(cat "$_pidf" 2>/dev/null)
        if [ -n "$_op" ] && [ -d "/proc/$_op" ] && [ "$_op" != "$$" ]; then
            drm_log "watch 已在跑（pid=$_op），退出"
            return 0
        fi
    fi
    mkdir -p "$DRM_RUN_DIR" 2>/dev/null
    printf '%s\n' "$$" >"$_pidf"
    rm -f "$_stop" 2>/dev/null

    drm_log "watch 启动：轮询 $_req"
    while :; do
        [ -f "$_stop" ] && { drm_log "watch 收到停止信号"; rm -f "$_pidf"; return 0; }
        if [ -f "$_req" ]; then
            drm_log "检测到退出请求"
            rm -f "$_req" 2>/dev/null      # ★ 必须在停容器之前
            rm -f "$_pidf"
            cmd_exit
            return 0
        fi
        sleep 1
    done
}

cmd_watch_stop() {
    touch "$DRM_RUN_DIR/.watch-stop" 2>/dev/null
    drm_log "已请求 watch 停止"
}

cmd_watch_status() {
    _pidf="$DRM_RUN_DIR/watch.pid"
    if [ -f "$_pidf" ]; then
        _op=$(cat "$_pidf" 2>/dev/null)
        if [ -n "$_op" ] && [ -d "/proc/$_op" ]; then
            printf 'watch: running (pid=%s)\n' "$_op"
            return 0
        fi
    fi
    printf 'watch: not running\n'
    return 1
}

# ═══════════════════════════════════════════════════════════
# status
# ═══════════════════════════════════════════════════════════

cmd_status() {
    printf '设备      : %s (%s) [%s 侧]\n' "$DRM_DEVICE" "$DEV_MODEL" "$DRM_SIDE"
    drm_state_show
    _lh=$(drm_lock_holder 2>/dev/null) && printf '锁        : %s\n' "$_lh" || printf '锁        : 空闲\n'
    cmd_watch_status
    if drm_android_side; then
        printf 'SF        : %s\n' "$(android_svc_state "$DEV_SF_SVC")"
        printf 'composer  : %s\n' "$(android_svc_state "$DEV_COMPOSER_SVC")"
        _h=$(android_card_holders 2>/dev/null)
        printf 'card0持有 : %s\n' "${_h:-无}"
    else
        printf 'kwin      : %s\n' "$(pgrep -x kwin_wayland 2>/dev/null | tr '\n' ' ')"
        printf 'plasmashell: %s\n' "$(pgrep -x plasmashell 2>/dev/null | tr '\n' ' ')"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════

usage() {
    cat <<EOF
$DRM_PROJECT — 统一切换控制器

用法: $0 <子命令> [参数]

  enter        进入 Linux（★ 必须在安卓侧以 root 执行）
  exit         返回安卓（安卓侧；动作 = 停容器 + 整机重启）
  rollback     接管中途放弃，原地拉回安卓（尽力而为）
  status       打印当前状态
  doctor       环境体检
  watch        安卓侧常驻守护：轮询共享目录的退出请求
  watch-stop   停止 watch
  watch-status 查看 watch 状态

环境变量:
  DRM_DEVICE=opd2511   强制设备适配层（默认自动识别）
  FULL_STOP=1          连 framework 一起 stop（⚠️ 会永久毁掉音频）
  DRM_NET=0            跳过网络接管
  DRM_WIFI_SSID/PSK    直接给 WiFi 凭据
  DRM_WAYLAND_SOCKET   合成器 socket 名（默认 taketest）

当前设备: $DRM_DEVICE ($DEV_MODEL)，本进程在 $DRM_SIDE 侧
EOF
}

# ── payload 可信性自检 ────────────────────────────────────
# 本脚本以 root 执行。如果它所在的树对非 root 可写（例如老版本的
# /data/local/tmp/...），那么任何能写那棵树的本地进程都能拿到 root。
# 特权动作之前先确认一次；只读子命令（status/doctor/help）不拦，
# 方便用户在任何情况下都能查状态、看体检结果。
case "${1:-}" in
    enter|exit|rollback|watch)
        if ! drm_assert_payload_trusted "$DRM_ROOT"; then
            drm_err "已中止（未执行任何特权动作）"
            exit 1
        fi
        ;;
esac

case "${1:-}" in
    enter)        shift; cmd_enter "$@" ;;
    exit)         shift; cmd_exit "$@" ;;
    rollback)     shift; cmd_rollback "$@" ;;
    status)       shift; cmd_status "$@" ;;
    doctor)       shift; cmd_doctor "$@" ;;
    watch)        shift; cmd_watch "$@" ;;
    watch-stop)   shift; cmd_watch_stop "$@" ;;
    watch-status) shift; cmd_watch_status "$@" ;;
    ''|-h|--help|help) usage ;;
    *) drm_err "未知子命令：$1"; usage; exit 2 ;;
esac

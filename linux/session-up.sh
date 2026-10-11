#!/bin/sh
# linux/session-up.sh — 容器侧会话拉起（DRM 交接的现场）。
#
# 由 core/switch.sh 的 cmd_enter 通过 `droidspaces run` 调用：
#   ds_exec "DRM_SIDE=container DRM_DEVICE=<dev> sh <shared>/droid-drm-takeover/linux/session-up.sh"
#
# 调用它时，安卓侧已经完成：停 SF + 点名停 composer + 等 card0 无持有者 + 起容器。
# 本脚本负责剩下的一半：把屏幕从"无人持有"交给 KWin，并把桌面立起来。
#
# ══ 顺序不可调 ══
#   节点 → udev 记录 → 杀旧栈 → kwinwrap 交接 → 自检 → 强制点亮
#   → kactivitymanagerd → plasmashell → 等 kwin 持 DRM → 输入 → 网络
#
# ══ 失败语义 ══
#   ★ kwin 阶段之前失败：直接退出（安卓侧会 rollback）
#   ★ kwin 拿到屏之后失败：只告警不退出——此时屏幕已经归 Linux，
#     退出去也没法把画面还给安卓（只能重启），不如把能起的都起来。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

DRM_SIDE=container
export DRM_SIDE

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

drm_state_init
drm_state_set SIDE container

_launch_ts=$(date +%s)

# ── 1) 桌面账号 ───────────────────────────────────────────
drm_phase "desktop-user"
drm_desktop_user_resolve

# ── 2) 杀掉上一轮的 Linux 栈 ──────────────────────────────
# 必须在 kwinwrap 之前：旧 kwin 还持着 master 的话，新 kwin 的
# SET_MASTER 会 EBUSY（现象是"kwin 起了但立刻退出"）。
drm_phase "kill-old-stack"
drm_kill_linux_stack

# ── 3) DRM 节点 ───────────────────────────────────────────
drm_phase "drm-nodes"
drm_ensure_drm_nodes

# ── 4) 触摸节点 ───────────────────────────────────────────
drm_phase "touch-node"
drm_ensure_touch_node || true

# ── 5) 合成 udev 记录 ─────────────────────────────────────
drm_phase "udev-records"
drm_write_udev_records

# ── 6) kwinwrap 交接 ──────────────────────────────────────
drm_phase "kwin-handover"
if ! drm_start_kwin; then
    drm_err "kwinwrap 交接失败 —— 屏幕仍归 Linux 未接管状态，交给安卓侧 rollback"
    exit 1
fi

# ── 7) Wayland socket 自检 ────────────────────────────────
drm_phase "wayland-selfcheck"
if ! drm_wayland_selfcheck; then
    drm_err "Wayland socket 自检失败"
    exit 1
fi

# ── 8) 强制点亮 ───────────────────────────────────────────
# stop 时 system_server 死前会走关机流程把 connector DPMS 拉 Off 并灭背光，
# kwin 的新 commit 不一定把它拉回来 ⇒ "有模式、有提交、屏是黑的"。
drm_phase "force-display-on"
drm_force_display_on
sleep 2
drm_force_display_on

# ══ 以下失败只告警：屏幕已经在 Linux 手里，退出去也还不了 ══

# ── 9) 桌面会话 ───────────────────────────────────────────
drm_phase "desktop-session"
drm_start_desktop || drm_warn "桌面会话拉起有问题（见 PLASMA-* 日志）"

# ── 10) 等本轮的 kwin 拿到 DRM ────────────────────────────
drm_phase "wait-kwin-drm"
drm_wait_kwin_holds_drm 20 "$_launch_ts" || true

# ── 11) 输入设备 ──────────────────────────────────────────
drm_phase "input-settle"
drm_input_settle || true

# ── 12) 网络（尽力而为，绝不连坐桌面）──────────────────────
net_takeover_wifi || true

# ── 13) 设备专属收尾 ──────────────────────────────────────
drm_phase "device-post-session"
drm_device_hook dev_post_session_fixes

# ── 14) 常驻守护：背光钉住 + 安卓 dmesg 收割 ───────────────
drm_phase "guardians"
_bl=$(drm_tool setbright 2>/dev/null)
if [ -n "$_bl" ]; then
    # 接管期间安卓侧的背光会被反复拉 0，需要自己钉住
    setsid nohup sh -c "while :; do '$DRM_ROOT/display/keepbright.sh' 2>/dev/null; sleep 5; done" \
        >>"${DRM_LOG_DIR}/keepbright.log" 2>&1 &
    drm_log "已起 keepbright 守护"
fi

# ── 15) 汇总 ──────────────────────────────────────────────
drm_phase "done"
_kwin_ok=$(drm_state_get KWIN_HOLDS_DRM 2>/dev/null || echo 0)
_plasma_ok=$(drm_state_get PLASMA_OK 2>/dev/null || echo 0)
_net_ok=$(drm_state_get NET_OK 2>/dev/null || echo 0)

drm_log "════ 会话汇总 ════"
drm_log "  kwin 持DRM : $_kwin_ok"
drm_log "  plasmashell: $_plasma_ok"
drm_log "  网络出口   : $_net_ok"
drm_log "  合成器 socket: ${DESKTOP_RUNTIME_DIR}/${DRM_WAYLAND_SOCKET:-taketest}"
drm_log "  日志目录   : $DRM_LOG_DIR"

if [ "$_kwin_ok" = 1 ]; then
    drm_state_set PHASE linux-active
    drm_state_set PHASE_AT "$(drm_ts)"
    exit 0
fi

drm_err "kwin 最终没有持有 $DEV_DRM_CARD"
exit 1

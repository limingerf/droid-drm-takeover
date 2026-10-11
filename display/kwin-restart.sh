#!/bin/sh
# display/kwin-restart.sh — 只重启容器侧的 KWin（不碰安卓）。
#
# 用途：桌面卡住/花屏/输入丢失时，不重启设备也不动安卓，只把合成器重来一遍。
# Linux 应用的菜单里"重启桌面"走的就是它。
#
# ══ 为什么需要它 ══
# 接管后屏幕归 KWin 持有，安卓已经退场。此时如果 KWin 崩了，屏幕是黑的，
# 但**不能靠重启安卓来修**（那样要等 1 分钟且会连带容器）。
# 只重启 KWin 是秒级恢复。
#
# ══ 用法 ══
#   sudo sh display/kwin-restart.sh

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_detach_and_rerun KWINRESTART_ID "$@"
trap '' HUP INT TERM

drm_log "════ 只重启 KWin ════"
drm_desktop_user_resolve

_launch_ts=$(date +%s)

drm_kill_linux_stack
drm_ensure_drm_nodes
drm_ensure_touch_node || true
drm_write_udev_records

if ! drm_start_kwin; then
    drm_err "kwinwrap 交接失败"
    exit 1
fi
if ! drm_wayland_selfcheck; then
    drm_err "Wayland socket 自检失败"
    exit 1
fi

drm_force_display_on
drm_start_desktop
drm_wait_kwin_holds_drm 20 "$_launch_ts" || true
drm_input_settle || true

drm_log "════ KWin 已重启 ════"

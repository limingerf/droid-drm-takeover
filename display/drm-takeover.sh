#!/bin/sh
# display/drm-takeover.sh — 容器侧「进入 Linux」入口（桌面上的图标调它）。
#
# ══ 它在整个流程里的位置 ══
#   容器侧（本脚本）        写 enter.request，然后等本侧 kwin 拿到 card0
#   安卓侧（core/switch.sh watch）  看到请求 → cmd_enter → 停显示栈 →
#                                   ds_exec 容器里的 linux/session-up.sh
#
# ★ 为什么不在这里直接停安卓的显示栈（重构前的做法）：
#   那需要从容器里调 adb。实测 Droidspaces v6.6.0 的容器里
#   /dev/bus/usb 不存在、adbd 也没监听 TCP ⇒ 容器里 `adb devices`
#   恒为空 ⇒ 这条路在真机上根本不成立。
#   而且停服务靠 init 属性服务（/dev/__properties__），容器里也没有。
#   完整说明见 core/lib/request.sh 顶部。
#
# ══ 用法 ══
#   sh display/drm-takeover.sh                     # 进 Linux，常驻
#   DRM_TRIAL_SECS=150 sh display/drm-takeover.sh  # 试跑，150s 后自动回安卓
#
# ══ 试跑保险丝为什么走"重启"而不是原地恢复 ══
#   容器一启动就会破坏安卓 ueventd 的 netlink（热插拔节点建不出来），
#   停容器**不等于**恢复。原地恢复（display/desk-stop.sh）只在
#   "还没起容器"或"明确接受半死状态"时才用。所以保险丝发的是
#   exit.request —— 与「返回安卓」按钮同一条路，也就是停容器 + 整机重启。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_detach_and_rerun DRMTAKEOVER_ID "$@"
trap '' HUP INT TERM

TRIAL_SECS=${DRM_TRIAL_SECS:-}
WAIT_SECS=${DRM_WAIT_SECS:-120}

drm_phase "请求安卓侧接管显示"

# 没有守护在听的话，请求会石沉大海 —— 与其等超时，不如立刻说清楚。
if ! drm_request_require_watcher; then
    drm_err "接管请求未发出"
    exit 1
fi

drm_request_send enter || exit 1

# ── 保险丝：到点自动返回安卓 ──────────────────────────────
#
# ★ 判据是本侧 kwin 真的拿到了 card0（本侧就能验），不是"脚本跑到哪了"。
#   重构前的保险丝判据是 `[ ! -f takeover.ok ] && ! kill -0 $MAIN`，
#   而主流程结尾**无条件** touch takeover.ok ⇒ 判据永远为假 ⇒
#   那个保险丝从来没生效过。
if [ -n "$TRIAL_SECS" ]; then
    drm_log "试跑模式：${TRIAL_SECS}s 后自动返回安卓"
    (
        sleep "$TRIAL_SECS"
        if [ -n "$(drm_card_fd_holders "$DEV_DRM_CARD" 2>/dev/null)" ]; then
            echo "[$(drm_ts)] FUSE: ${TRIAL_SECS}s 到，发返回安卓请求" >>"$DRM_JOURNAL"
            drm_request_send exit >>"$DRM_JOURNAL" 2>&1
        fi
    ) &
    _fuse=$!
else
    drm_log "常驻模式：不会自动返回安卓"
    _fuse=""
fi

if drm_request_wait_enter "$WAIT_SECS"; then
    drm_log "════ 接管成功：本侧 kwin 已持有 $DEV_DRM_CARD ════"
    if [ -n "$_fuse" ]; then
        drm_log "${TRIAL_SECS}s 后会自动返回安卓；想留下就 kill $_fuse"
        wait "$_fuse" 2>/dev/null
        drm_log "试跑结束，安卓侧正在重启"
    else
        drm_log "返回安卓：点桌面上的「返回安卓」图标（display/drm-stop.sh）"
    fi
    exit 0
fi

drm_err "════ 接管失败 ════"
[ -n "$_fuse" ] && kill "$_fuse" 2>/dev/null
drm_warn "日志：$DRM_JOURNAL"
exit 1

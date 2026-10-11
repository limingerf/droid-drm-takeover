#!/bin/sh
# display/drm-takeover.sh — 一次性试跑（新设备首次上机用）。
#
# ══ 与 desk-takeover.sh 的区别 ══
#   desk-takeover.sh  常驻：进 Linux 就一直待着，直到你点「返回安卓」
#   drm-takeover.sh   试跑：进 Linux，验证完自动回到安卓（默认 150s）
#
# 用途：第一次在新设备上试接管时，你不想被卡在 Linux 里（万一触摸不工作
# 就没法点返回按钮了）。试跑模式会在 N 秒后自己把安卓拉回来。
#
# ══ 用法 ══
#   sudo sh display/drm-takeover.sh                     # 试跑 150s 后自动回滚
#   sudo DRM_TRIAL_SECS=300 sh display/drm-takeover.sh  # 试跑 5 分钟
#   sudo PERSIST=1 sh display/drm-takeover.sh           # 不自动回滚（= desk-takeover）
#   sudo DRM_NET=0 sh display/drm-takeover.sh           # 不碰网络
#
# ══ ★ 修掉重构前的一个真 bug ══
# 旧 drm-takeover.sh 的"150s 保险丝"靠一个子进程判断
#   `if [ ! -f takeover.ok ] && ! kill -0 $MAIN`
# 但主流程在结尾**无条件** touch takeover.ok（成功失败都 touch），
# 所以保险丝判据永远为假 —— 它其实从来没生效过。
# 现在改成显式的定时回滚，判据是状态机阶段，不会再自我欺骗。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_detach_and_rerun DRMTRIAL_ID "$@"
trap '' HUP INT TERM

drm_adb_init

TRIAL_SECS=${DRM_TRIAL_SECS:-150}
PERSIST=${PERSIST:-0}

drm_lock_acquire drm-takeover || exit 1

# ── 保险丝：定时回滚 ──────────────────────────────────────
# 判据用状态机：只有真的进入了 linux-active 才需要回滚；
# 中途失败的话 drm_do_enter 自己已经回滚过了。
if [ "$PERSIST" != 1 ]; then
    drm_log "试跑模式：${TRIAL_SECS}s 后自动返回安卓（PERSIST=1 可关掉）"
    (
        sleep "$TRIAL_SECS"
        _ph=$(drm_state_phase)
        if [ "$_ph" = linux-active ]; then
            echo "[$(drm_ts)] FUSE: ${TRIAL_SECS}s 到，自动回滚" >>"$DRM_JOURNAL"
            sh "$SELF_DIR/desk-stop.sh" >>"$DRM_JOURNAL" 2>&1
        fi
    ) &
    _fuse=$!
else
    drm_log "常驻模式（PERSIST=1）：不会自动返回安卓"
    _fuse=""
fi

if drm_do_enter; then
    drm_log "════ 试跑成功：桌面已上屏 ════"
    if [ -n "$_fuse" ]; then
        drm_log "${TRIAL_SECS}s 后会自动回到安卓；想留下就 kill $_fuse"
        wait "$_fuse" 2>/dev/null
        drm_log "试跑结束"
    else
        drm_log "回安卓：display/desk-stop.sh"
    fi
    _rc=0
else
    drm_err "════ 试跑失败 ════"
    [ -n "$_fuse" ] && kill "$_fuse" 2>/dev/null
    _rc=1
fi

drm_lock_release
exit $_rc

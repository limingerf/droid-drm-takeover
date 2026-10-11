#!/bin/sh
# display/desk-takeover.sh — 容器侧"进入 Linux"入口（桌面里点它 / 终端里跑它）。
#
# ══ 与 core/switch.sh enter 的关系 ══
# 同一套时序，两个前端：
#   · core/switch.sh enter（安卓侧）—— APK 走这条，用 droidspaces 驱动容器
#   · 本脚本（容器侧）—— 桌面里走这条，用 adb 反向驱动安卓
# 两者都调用 core/lib/enter.sh 的 drm_do_enter()，阶段顺序完全一致。
# 重构前它们是两份独立实现，env 块都不一样（KWINWRAP_LEASE vs FILTER），
# 同一台设备上行为不可复现。
#
# 用法:
#   sudo sh display/desk-takeover.sh          # 全自动：停安卓 → 起 KWin+Plasma → 接管 WiFi
#   sudo DRM_NET=0 sh display/desk-takeover.sh    # 不碰网络
#   sudo FULL_STOP=1 sh ...                   # ⚠️ 连 framework 一起 stop（会毁音频）

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

# ── 自脱钩 ────────────────────────────────────────────────
# ★ 从桌面 konsole 里跑的时候，konsole 是"即将被我们杀掉的 kwin"的客户端。
#   kwin 一死 pty 关闭，前台脚本陪葬 —— 而此时安卓已经 stop ⇒ 两头全黑。
#   所以主体必须先 setsid 脱离终端。（参考仓库与本仓库都被咬过。）
drm_detach_and_rerun DESKSTART_ID "$@"
trap '' HUP INT TERM

drm_log "════ desk-takeover 启动（容器侧）════"

# 容器侧要通过 adb 操作安卓
drm_adb_init

drm_lock_acquire desk-takeover || exit 1
trap 'drm_lock_release' EXIT INT TERM

if drm_do_enter; then
    drm_log "════ 完成：桌面已上屏 ════"
    drm_log "回安卓：桌面里点「返回安卓」图标，或跑 display/desk-stop.sh"
    _rc=0
else
    drm_err "════ 失败，已尝试回滚 ════"
    _rc=1
fi

drm_lock_release
trap - EXIT INT TERM
exit $_rc

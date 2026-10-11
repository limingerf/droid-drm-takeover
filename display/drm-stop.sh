#!/bin/sh
# display/drm-stop.sh — 容器侧「返回安卓」入口（桌面图标调它）。
#
# ══ 它做什么 ══
# 写一个 exit.request，安卓侧的常驻守护（core/switch.sh watch）看到后：
#   删请求 → 停容器 → 杀残留 → sync → /system/bin/reboot
#
# ══ ★ 为什么是整机重启，而不是原地把安卓拉回来 ══
# 容器一启动就会破坏安卓 ueventd 的 netlink（热插拔节点建不出来），
# 而且我们停掉了 vendor 的显示 HAL。停容器**不等于**恢复 ——
# 原地恢复会留下一个"半死"状态（显示可能回来，但触摸/音频/热插拔
# 各种不对劲）。只有整机重启能回到干净状态。
# 参考仓库与 target 版都在这条路上被咬过。
#
#   原地恢复的脚本仍然保留：display/desk-stop.sh
#   但它只在两种情况下用：① 还没起容器就失败了 ② 你明确接受半死状态。
#   正常路径不要调它。
#
# ══ 用法 ══
#   sh display/drm-stop.sh

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_phase "请求安卓侧返回"

if ! drm_request_require_watcher; then
    drm_err "返回请求未发出 —— 设备不会自己回到安卓"
    drm_warn "可以在安卓侧手动执行：su -c 'sh $DRM_ANDROID_PAYLOAD/core/switch.sh exit'"
    exit 1
fi

drm_request_send exit || exit 1

drm_log "请求已发出。安卓侧将停容器并整机重启，屏幕会黑一下。"
drm_log "如果 30 秒内没有任何动静，说明守护卡住了："
drm_log "  su -c 'sh $DRM_ANDROID_PAYLOAD/core/switch.sh exit'"

# 等一等，好让用户看到反馈；守护那边一动手我们就没了。
_i=0
while [ "$_i" -lt 30 ]; do
    sleep 1
    _i=$((_i + 1))
done
drm_warn "等了 ${_i}s 仍没重启 —— 守护可能没在跑或已卡住"
exit 1

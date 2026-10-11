#!/bin/sh
# display/keepbright.sh — 接管期间把背光钉住。
#
# ══ 为什么需要 ══
# 接管后安卓侧的关机流程/残留逻辑会反复把背光写 0，表现为"画面明明在动
# 但屏幕是黑的"，极难判断。每 5 秒回写一次即可压住。
#
# ══ 与 setbright 的区别 ══
# 重构前这里直接 `echo 2048 > .../brightness`，而 setbright 会做 clamp —— 
# 两条路径的亮度不一致。现在统一走 setbright（它会自己找 connected connector
# 并 clamp 到合法范围）。
#
# ══ 用法 ══
#   sh display/keepbright.sh          # 前台循环，直到状态不再是 linux-active
#   setsid nohup sh display/keepbright.sh &   # 后台
#
# 循环条件用状态机而不是重构前那个 `takeover.ok` 空文件：
# 那个文件被 drm-takeover.sh 在结尾无条件 touch，判据早就失效了。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

_sb=$(drm_tool setbright 2>/dev/null || true)

drm_log "keepbright 启动（亮度 ${DEV_BRIGHTNESS}）"
while :; do
    _ph=$(drm_state_phase)
    case "$_ph" in
        linux-active|entering) ;;
        *) drm_log "状态变为 $_ph，keepbright 退出"; break ;;
    esac

    if [ -n "$_sb" ]; then
        "$_sb" "$DEV_BRIGHTNESS" >/dev/null 2>&1
    else
        # 没有 setbright 工具时的退化路径
        _bl=$(drm_backlight_node 2>/dev/null || true)
        [ -n "$_bl" ] && echo "$DEV_BRIGHTNESS" >"/sys/class/backlight/$_bl/brightness" 2>/dev/null
    fi
    sleep 5
done

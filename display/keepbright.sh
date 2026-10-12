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
    # ★★ 循环条件必须是"**还没回到安卓**"，不能是"已经 linux-active"。
    #
    #   原来写的是 `linux-active|entering) ;; *) break`，而 session-up.sh 的
    #   顺序是：起 keepbright 守护 → drm_phase "done"（把状态设成 done）
    #   → 汇总 → 最后才设 linux-active。于是 keepbright 每轮一读状态就是
    #   "done"，**第一轮立刻 break**；外层那个 `while :; do ...; sleep 5; done`
    #   每 5 秒把它重启一次 —— 现象是 keepbright.log 里每 5 秒一行
    #   "keepbright 启动 / 状态变为 done，keepbright 退出"，**背光从来没被钉过**。
    #   （实测：接管后背光停在安卓关机时留下的 89，而 DEV_BRIGHTNESS=2048。）
    #
    #   现在改成"只要不是 android-active / returning 就一直钉"。这样它天然
    #   覆盖 entering → done → linux-active 全程，也不依赖 session-up 的设相位顺序。
    _ph=$(drm_state_phase)
    case "$_ph" in
        android-active|returning)
            drm_log "状态变为 $_ph（已回到安卓），keepbright 退出"; break ;;
    esac

    # ★★ 写 sysfs，不是写 DRM connector 属性。
    #
    #   实测（2026-10-12）：接管后 KWin 是 DRM master，任何非 master 写
    #   connector 属性都 EACCES：
    #       setbright 2048 -> set 2048 -> -1 (Permission denied)
    #   所以原来那条 setbright 路径**在接管态下永远失败**，背光其实从来没被钉住。
    #
    #   而 sysfs 的 bl_power/brightness 是**普通文件写**，不需要 master，
    #   实测写 bl_power=0 和 brightness=2048 都成功。
    #
    #   bl_power 尤其关键：安卓关机流程会把它写成 4（FB_BLANK_POWERDOWN），
    #   那是**硬关背光电源**，跟 DPMS 是两条独立的路；只写 brightness 是没用的
    #   （实测 brightness=2048 而 actual_brightness 仍是 0）。
    _bl=$(drm_backlight_node 2>/dev/null || true)
    if [ -n "$_bl" ]; then
        _bp=/sys/class/backlight/$_bl/bl_power
        [ -w "$_bp" ] && [ "$(cat "$_bp" 2>/dev/null)" != 0 ] && \
            echo 0 >"$_bp" 2>/dev/null
        # ★★ 2026-10-12：与按键守护（input/drm-keys.py）协作，别互相打架。
        #
        #   drm-keys 的电源键短按会做"熄屏"：先写背光 0、再 DPMS off，
        #   并置 /run/drm-keys.screenoff=1。而本脚本每 5 秒把背光**钉回**
        #   DEV_BRIGHTNESS —— 两者同时跑的结果是：
        #     用户按一下电源键 → 屏幕黑了 → 最多 5 秒后自己又亮起来。
        #   现象是"电源键熄屏时灵时不灵"，极难查（因为 DPMS 那半是生效的）。
        #
        #   所以熄屏期间**跳过 brightness 回写**。注意 bl_power 仍然要钉 0
        #   （那是"别让安卓把背光电源硬关"的保护，和亮度不是一回事；
        #    亮度已经是 0，钉 bl_power 不会让屏幕亮起来）。
        #
        #   ★ 只认这个明确的标志文件，不猜 DPMS 状态：sysfs 的
        #     /sys/class/drm/*/dpms 实测不可信（kscreen-doctor --dpms off
        #     之后它照样读 On，上游踩过）。
        if [ "$(cat /run/drm-keys.screenoff 2>/dev/null)" = "1" ]; then
            _bn=/sys/class/backlight/$_bl/brightness
            [ -w "$_bn" ] && [ "$(cat "$_bn" 2>/dev/null)" != 0 ] && \
                echo 0 >"$_bn" 2>/dev/null
        else
            _bn=/sys/class/backlight/$_bl/brightness
            [ -w "$_bn" ] && echo "$DEV_BRIGHTNESS" >"$_bn" 2>/dev/null
        fi
    fi
    # 兜底：能写 DRM 属性时也写一次（非接管态下才可能成功）
    if [ -n "$_sb" ]; then
        "$_sb" "$DEV_BRIGHTNESS" >/dev/null 2>&1
    fi
    sleep 5
done

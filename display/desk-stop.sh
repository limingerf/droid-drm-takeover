#!/bin/sh
# display/desk-stop.sh — 容器侧"原地返回安卓"（不重启设备）。
#
# ══ 什么时候用它 ══
# 只在"还没起容器"或"你明确接受半死状态"时用。
# **正常路径请用 Linux 应用里的「返回安卓」**，那条链会停容器 + 整机重启。
#
# ══ 为什么原地恢复不干净 ══
# 容器启动破坏了安卓 ueventd 的 netlink ⇒ U 盘/pogo 键盘等热插拔节点
# 建不出来。**停容器 ≠ 恢复**。原地恢复后常见症状：
#   · 卡开机界面约 1 分钟
#   · 进系统后不定时重启（watchdog 杀 vendor HAL 被 SELinux 拒）
#   · pogo 键盘/触摸板不认
# 这些只有整机重启能彻底恢复。
#
# ══ 用法 ══
#   sudo sh display/desk-stop.sh

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_detach_and_rerun DESKSTOP_ID "$@"
trap '' HUP INT TERM

drm_log "════ desk-stop：原地返回安卓 ════"
drm_adb_init

# ── 保命看门狗 ────────────────────────────────────────────
# ★ 重构前没有这个。参考仓库记录过事故：主流程卡死在第一个 adb 调用上，
#   日志断在 wake_unlock 那行，后面的 `start` 从未执行 ⇒ 纯黑屏。
#   这里 50s 后无条件把安卓拉起来（幂等，重复 start 无害）。
_STARTED=/run/deskstop-started
rm -f "$_STARTED" 2>/dev/null
(
    sleep 50
    if [ ! -f "$_STARTED" ]; then
        echo "[$(date '+%F %T')] WATCHDOG: 主流程 50s 未完成，无条件拉起安卓" >>"$DRM_JOURNAL"
        android_start_display
        android_exec "setprop ctl.start system_suspend" 2>/dev/null
        android_start_framework
    fi
) &
_WD=$!

drm_state_set PHASE returning

# ── 1) 杀容器侧 Linux 桌面栈 ──────────────────────────────
drm_phase "kill-linux-stack"
drm_kill_linux_stack

# ── 2) 交还网络 ───────────────────────────────────────────
# ★ 不 `ip link set down`（红线：down 之后的任何 up 都会让 adbd 陪葬）。
net_release

# ── 3) 解冻 system_server ─────────────────────────────────
# ★ 常驻接管模式（旧 drm-takeover.sh PERSIST=1）会 kill -STOP system_server。
#   不解冻的话安卓永远起不来。这是重构前只有 drm-stop.sh 做、desk-stop.sh
#   漏掉的一步，用错脚本就留下永久卡死的安卓。
drm_phase "thaw-system-server"
android_exec "p=\$(pidof system_server); [ -n \"\$p\" ] && kill -CONT \$p" 2>/dev/null || true

# ── 4) 起回安卓显示栈 ─────────────────────────────────────
# 顺序敏感：先 system_suspend（否则新 system_server 会在
# PowerManagerService.<init> 的 waitForService(android.system.suspend) 卡死
# → 厂商的 framework hang 守护直接重启设备），再点名起 composer，
# 最后才 start。
drm_phase "start-android"
android_exec "echo qoderdbg > /sys/power/wake_unlock" 2>/dev/null || true
android_start_display
android_exec "setprop ctl.start system_suspend" 2>/dev/null || true
android_start_framework

# ── 5) 等 SurfaceFlinger ──────────────────────────────────
drm_phase "wait-surfaceflinger"
_i=0
while [ "$_i" -lt 24 ]; do
    if [ "$(android_svc_state "$DEV_SF_SVC")" = running ]; then
        drm_log "SF running（等了 $((_i * 5))s）"
        break
    fi
    sleep 5
    _i=$((_i + 1))
    # 每 6 轮补刀
    if [ $((_i % 6)) -eq 0 ]; then
        drm_warn "第 $((_i / 6)) 轮补刀"
        drm_kill_linux_stack
        android_start_display
        android_exec "setprop ctl.start system_suspend" 2>/dev/null || true
        android_start_framework
    fi
done

# ── 6) 还原我们改过的东西 ─────────────────────────────────
drm_phase "restore-android-state"
# ★ 重构前 desk-stop.sh 不还原 watchdog/nativehang 设置 —— 若之前跑过
#   常驻接管，这些 settings 会**永久残留**在安卓上（永久失去看门狗）。
android_watchdog_rearm 2>/dev/null || true
android_kernel_debug_on 2>/dev/null || true

# ── 7) 亮屏解锁 ───────────────────────────────────────────
drm_phase "wake-screen"
android_wake
android_stop_bootanim
android_dismiss_keyguard
android_set_brightness

# 主流程完成，撤销看门狗
touch "$_STARTED" 2>/dev/null
kill "$_WD" 2>/dev/null

drm_state_set PHASE android-active
drm_state_set PHASE_AT "$(drm_ts)"

# ── 8) 取证 ───────────────────────────────────────────────
drm_phase "evidence"
drm_log "SF=$(android_svc_state "$DEV_SF_SVC") zygote=$(android_svc_state zygote) composer=$(android_svc_state "$DEV_COMPOSER_SVC")"
drm_log "card0 持有者：$(android_card_holders 2>/dev/null || echo 无)"

if [ "$(android_svc_state "$DEV_SF_SVC")" != running ]; then
    drm_err "SurfaceFlinger 没起来 —— 建议长按电源键强重启"
    exit 1
fi
drm_log "════ 已回到安卓 ════"
drm_warn "若 USB/pogo 键盘仍不认或系统不定时重启，请整机重启一次"
exit 0

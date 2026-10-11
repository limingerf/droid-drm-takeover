#!/bin/sh
# display/dmesg-harvester.sh — 接管期间周期收割安卓 dmesg（保留最近 15 份）。
#
# ══ 为什么需要 ══
# 断流/重启会清掉设备侧的 ring buffer 与 pstore。只有提前落盘才能留下
# 崩溃前的现场。重构后这条链踩过的坑（composer 不放 master、atomic EACCES、
# watchdog 杀 HAL）全都是靠这些历史 dmesg 定位的。
#
# ══ 用法 ══
#   setsid nohup sh display/dmesg-harvester.sh &
#
# 循环条件用状态机（linux-active），不再用重构前那个被无条件 touch 的
# takeover.ok 空文件。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

HARVEST_DIR="${DRM_LOG_DIR}/harvest"
mkdir -p "$HARVEST_DIR" 2>/dev/null

# 容器侧要用 adb 取安卓 dmesg；取不到就安静退出（安卓侧跑这个没意义）
if drm_android_side; then
    drm_log "安卓侧不需要 harvester（dmesg 就在本地），退出"
    exit 0
fi
drm_adb_init 2>/dev/null || { drm_warn "没有 adb 通道，harvester 退出"; exit 0; }

drm_log "dmesg-harvester 启动（每 20s 一份，保留 15 份）→ $HARVEST_DIR"
while :; do
    _ph=$(drm_state_phase)
    case "$_ph" in
        linux-active|entering) ;;
        *) drm_log "状态变为 $_ph，harvester 退出"; break ;;
    esac

    _ts=$(date +%m%d-%H%M%S)
    {
        date "+# local %F %T"
        drm_timeout 12 "$DRM_ADB_BIN" -s "$DRM_ADB_SERIAL" shell uptime 2>/dev/null
        drm_timeout 12 "$DRM_ADB_BIN" -s "$DRM_ADB_SERIAL" shell "su -c 'dmesg'" 2>/dev/null
    } >"$HARVEST_DIR/dmesg-$_ts.log" 2>/dev/null

    # 保留最近 15 份
    ls -t "$HARVEST_DIR"/dmesg-*.log 2>/dev/null | tail -n +16 | while read -r _f; do
        rm -f "$_f"
    done

    sleep 20
done

#!/bin/sh
# display/drm-diag-once.sh — 新设备适配第一步：一次性 KMS 取证。
#
# ══ 用途 ══
# 换设备时，先跑这个把 KMS 拓扑抓下来，据此填 core/device/<codename>.sh。
# 详见 docs/适配新设备.md。
#
# ══ 它做什么 ══
#   1. 解除安卓稳定性守护（★ 重构前这一步漏了，见下）
#   2. 停 SF + composer，让 master 空闲
#   3. 在容器里跑全部探针，把输出 pull 回 logs/drmdiag-*
#   4. 无论成败都恢复安卓（trap）
#
# ══ ★ 修掉重构前的一个真 bug ══
# 旧版 drm-diag-once.sh 直接停 SF+composer，但**没有先解除 watchdog**。
# 而 drm-takeover.sh 自己的注释明确记录过：SF 停约 120s 后 system_server
# 的 watchdog 线程会杀掉 system_server，init 级联 SIGKILL
# wpa_supplicant/netd/zygote ⇒ WiFi 掉线、UI 不可用，只能强重启。
# 旧版探针跑得久（多个工具 + debugfs dump），正好会撞上这个 120s。
#
# ══ 用法 ══
#   sudo sh display/drm-diag-once.sh
#   OUT=/tmp/diag sudo sh display/drm-diag-once.sh

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

OUT=${OUT:-$DRM_LOG_DIR/drmdiag}
mkdir -p "$OUT" 2>/dev/null

drm_adb_init

drm_log "════ DRM 一次性取证（设备 $DRM_DEVICE）════"
drm_log "输出目录：$OUT"

# ── 恢复（无论成败）────────────────────────────────────────
_diag_restore() {
    drm_log "恢复安卓显示栈"
    android_start_display
    android_exec "setprop ctl.start system_suspend" 2>/dev/null || true
    android_start_framework
    android_watchdog_rearm 2>/dev/null || true
    android_kernel_debug_on 2>/dev/null || true
    android_stop_bootanim
    android_wake
    android_set_brightness
    drm_log "已发出恢复指令（SF=$(android_svc_state "$DEV_SF_SVC")）"
}
trap _diag_restore EXIT

# ── 1) 先解除武装（★ 旧版漏了这一步）──────────────────────
drm_phase "diag-disarm"
android_watchdog_disarm

# ── 2) 停显示栈 ───────────────────────────────────────────
drm_phase "diag-stop-display"
android_exec "dmesg -C" 2>/dev/null || true
android_stop_display
sleep 2
android_wait_composer_release 15 || true

# ── 3) 容器内跑探针 ───────────────────────────────────────
drm_phase "diag-probes"

# 容器里的仓库路径（安卓侧要给**容器内**的路径；容器侧就是本仓库）
if drm_android_side; then
    _rroot=$(ds_repo_in_container)
else
    _rroot="$DRM_ROOT"
fi

# 跑一个探针并把结果写进 OUT
_diag_run() {
    _tool=$1
    shift
    _out="$OUT/$_tool.txt"
    if drm_android_side; then
        ds_exec "$_rroot/bin/$_tool $*" >"$_out" 2>&1
    else
        "$_rroot/bin/$_tool" "$@" >"$_out" 2>&1
    fi
    if [ -s "$_out" ]; then
        drm_log "  $_tool → $(wc -l <"$_out") 行"
    else
        drm_warn "  $_tool 无输出"
    fi
}

# ★ 优先跑"设备无关"的探针（运行时发现，不硬编码 ID）。
#   重构前唯一两个不硬编码的是 kmsmatrix / atomiccheck，但它们的
#   docs/tools.md 条目里根本没被提到。这里把它们提到最前面。
for _t in kmsdump kmsmatrix atomiccheck; do
    [ -x "$_rroot/bin/$_t" ] && _diag_run "$_t" "$DEV_DRM_CARD"
done

# 硬编码 ID 的旧探针：只在显式要求时跑（它们默认对着 piano 的
# crtc 206 / conn 67 / plane 157,161，在别的设备上结果无意义）
if [ "${DIAG_LEGACY_PROBES:-0}" = 1 ]; then
    drm_warn "跑旧探针（它们的 ID 是 piano 的，换设备结果不可信）"
    for _t in masterprobe rawprobe stageprobe atombisect replicate; do
        [ -x "$_rroot/bin/$_t" ] && _diag_run "$_t" "$DEV_DRM_CARD"
    done
fi

# ── 4) debugfs / dmesg ────────────────────────────────────
drm_phase "diag-kernel"
if drm_android_side; then
    android_exec "mount -t debugfs none /sys/kernel/debug 2>/dev/null; cat /sys/kernel/debug/dri/0/state" >"$OUT/dri-state.txt" 2>&1 || true
    android_exec "dmesg" >"$OUT/dmesg.txt" 2>&1 || true
else
    android_exec "mount -t debugfs none /sys/kernel/debug 2>/dev/null; cat /sys/kernel/debug/dri/0/state" >"$OUT/dri-state.txt" 2>&1 || true
    android_exec "dmesg" >"$OUT/dmesg.txt" 2>&1 || true
fi

# 容器侧的 sysfs 拓扑（最有用的一份：connector/crtc/plane 的 ID 与能力）
if ! drm_android_side; then
    {
        echo "== connectors =="
        for c in /sys/class/drm/card*/card*-*; do
            [ -d "$c" ] || continue
            echo "-- $(basename "$c")"
            echo "   status: $(cat "$c/status" 2>/dev/null)"
            echo "   enabled: $(cat "$c/enabled" 2>/dev/null)"
            echo "   modes: $(head -3 "$c/modes" 2>/dev/null | tr '\n' ' ')"
        done
        echo
        echo "== crtcs =="
        ls -d /sys/class/drm/card*/card*-* 2>/dev/null | head
    } >"$OUT/sysfs-topology.txt" 2>&1
fi

drm_log "取证完成，文件在 $OUT"
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /' >&2
drm_log "下一步：照着 docs/适配新设备.md 用这些数据填 core/device/<codename>.sh"

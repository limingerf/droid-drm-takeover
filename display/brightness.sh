#!/bin/sh
# display/brightness.sh — 用 KDE 自己的链路调背光（不是直接写 sysfs）
#
# ══════════════════════════════════════════════════════════════════════
# 两条刻度的换算（这是本脚本存在的唯一理由）
# ══════════════════════════════════════════════════════════════════════
#   sysfs  /sys/class/backlight/panel0-backlight/brightness   0 … 4095
#   KDE    org.kde.Solid.PowerManagement…BrightnessControl    0 … 10000
#
# PowerDevil 的 KWinDisplayDetector 把 KWin 的屏报成 0-10000
# （daemon/controllers/kwinbrightness.cpp: maxBrightness() = 10000）。
# KWin 再把这个 0..1 的比例交给背光设备，而设备是
# ExternalBrightnessDeviceV1（KWin src/core/brightnessdevice.h）：
#     const uint32_t minBrightness = m_internal ? 1 : 0;
#     val = round(lerp(minBrightness, m_maxBrightness, clamp(b, 0, 1)))
# 内置屏 minBrightness=1 ⇒
#     sysfs = round(1 + (max-1) * kde / 10000)
#     kde   = round((sysfs - 1) * 10000 / (max-1))
#
# ★ 实测核对（2026-10-12，A/B 都读过 sysfs 回值）：
#     kde=1024 → sysfs 420      kde=3072 → 1259
#     kde=512  → sysfs 211      kde=4095 → 1677
#     kde=5001 → sysfs 2048     kde=10000 → 4095
#   全部落在 round(1+4094*kde/10000) 上 ⇒ 公式正确。
#
# ★ 为什么 min 是 1 而不是 0：所以**走 KDE 这条路永远打不到 0**，
#   最低就是 1。想真关背光得用 `raw 0`（或者电源键，见 input/drm-keys.py）。
#
# ══════════════════════════════════════════════════════════════════════
# 用法
# ══════════════════════════════════════════════════════════════════════
#   sh display/brightness.sh status            现状（两条刻度都读）
#   sh display/brightness.sh get               同 status，机器可读
#   sh display/brightness.sh set <0-4095>      按 sysfs 刻度设（走 KDE）
#   sh display/brightness.sh pct <0-100>       按百分比设（走 KDE）
#   sh display/brightness.sh step up|down [n]  相对调 n%（默认 5）
#   sh display/brightness.sh raw <0-4095>      直接写 sysfs（应急/绕过 KDE）
#   sh display/brightness.sh selftest          写-读回自证（会轻微闪一下）
#
# ★ `set 0` / `raw 0` 会被拒绝，除非显式加 --force：0 就是全黑，
#   本设备唯一的兜底是长按电源键，不要留一个黑屏给用户。
#
# ══════════════════════════════════════════════════════════════════════

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# ★ boot.sh 会打 4 行设备识别横幅（走 stderr）。本脚本是给人/给快捷键
#   反复调的 CLI，横幅是噪声，所以只在 source 期间静音 —— 重定向只作用于
#   这一条命令，之后 drm_log/drm_warn 的输出照常可见（失败信息不会被吞）。
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh" 2>/dev/null

PDA=/org/kde/Solid/PowerManagement/Actions/BrightnessControl
PDAI=org.kde.Solid.PowerManagement.Actions.BrightnessControl
DISPLAY0=/org/kde/ScreenBrightness/display0
DISPLAYI=org.kde.ScreenBrightness.Display
KDE_MAX=10000

drm_desktop_user_resolve
BL=$(drm_backlight_node 2>/dev/null || true)
[ -n "$BL" ] || drm_die "找不到背光节点"
BLN=/sys/class/backlight/$BL/brightness
BLX=/sys/class/backlight/$BL/max_brightness

bl_get()  { cat "$BLN" 2>/dev/null; }
bl_max()  { cat "$BLX" 2>/dev/null; }

# 探测 Wayland socket（判据同 display/powerdevil-enable.sh）
pd_socket() {
    _best=
    for _p in "$DESKTOP_RUNTIME_DIR"/*; do
        [ -S "$_p" ] || continue
        _n=${_p##*/}
        case "$_n" in
            pipewire*|pulse*|bus|systemd*|gnupg*|dconf*|gvfs*|ssh*|drkonqi*) continue ;;
        esac
        [ -e "$_p.lock" ] || continue
        case "$_n" in wayland-*) printf '%s\n' "$_n"; return 0 ;; esac
        [ -n "$_best" ] || _best=$_n
    done
    [ -n "$_best" ] && printf '%s\n' "$_best"
}
SOCK=$(pd_socket || true)

as_desktop() {
    _env="XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus"
    [ -n "$SOCK" ] && _env="$_env WAYLAND_DISPLAY=$SOCK"
    if drm_have runuser; then
        # shellcheck disable=SC2086
        runuser -u "$DESKTOP_USER" -- env $_env "$@" 2>&1
    else
        su -s /bin/sh -c "env $_env $*" "$DESKTOP_USER" 2>&1
    fi
}

kde_get() {
    as_desktop busctl --user call org.kde.Solid.PowerManagement "$PDA" "$PDAI" brightness 2>/dev/null \
        | awk '{print $2}'
}

kde_set() {
    # $1 = 0..10000。setBrightness 的签名是 i（有符号），不是 u —— 实测传 u 报
    # "No such method 'setBrightness' in interface ... (signature 'u')"。
    as_desktop busctl --user call org.kde.Solid.PowerManagement "$PDA" "$PDAI" setBrightness i "$1"
}

sysfs2kde() {
    _m=$(bl_max); _v=$1
    awk -v v="$_v" -v m="$_m" 'BEGIN{
        if (m <= 1) { print 0; exit }
        k = (v - 1) * 10000 / (m - 1)
        if (k < 0) k = 0
        if (k > 10000) k = 10000
        printf "%d\n", int(k + 0.5)
    }'
}

kde2sysfs() {
    _m=$(bl_max); _k=$1
    awk -v k="$_k" -v m="$_m" 'BEGIN{ printf "%d\n", int(1 + (m - 1) * k / 10000 + 0.5) }'
}

status() {
    _b=$(bl_get); _m=$(bl_max)
    _k=$(kde_get)
    _d=$(as_desktop busctl --user get-property org.kde.ScreenBrightness \
            /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames 2>/dev/null)
    echo "背光节点   : /sys/class/backlight/$BL"
    echo "sysfs      : ${_b:-?} / ${_m:-?}  ($(awk -v v="${_b:-0}" -v m="${_m:-1}" 'BEGIN{printf "%.1f%%", v*100/m}'))"
    echo "KDE 刻度   : ${_k:-?} / $KDE_MAX"
    echo "可调屏     : ${_d:-（读不到，PowerDevil 没在跑？）}"
    echo "PowerDevil : $(as_desktop systemctl --user is-active plasma-powerdevil.service 2>/dev/null)"
}

get() {
    echo "sysfs=$(bl_get) max=$(bl_max) kde=$(kde_get)"
}

do_set_kde() {
    _k=$1
    _before=$(bl_get)
    kde_set "$_k" >/dev/null
    sleep 2
    _after=$(bl_get)
    echo "KDE $_k/10000 → sysfs $_before → $_after（预期 $(kde2sysfs "$_k")）"
    [ "$_after" = "$(kde2sysfs "$_k")" ] || \
        drm_warn "读回值和预期不符 —— KDE 那条路可能没接到真背光上"
}

case "${1:-status}" in
    status) status ;;
    get)    get ;;
    set)
        _v=${2:-}
        [ -n "$_v" ] || drm_die "用法: $0 set <0-4095>"
        if [ "$_v" -le 0 ] 2>/dev/null && [ "${3:-}" != "--force" ]; then
            drm_die "拒绝把背光设成 0（全黑）。真要设请加 --force；恢复：echo $(bl_get) > $BLN"
        fi
        _m=$(bl_max)
        [ "$_v" -le "$_m" ] 2>/dev/null || drm_die "超过 max_brightness=$_m"
        do_set_kde "$(sysfs2kde "$_v")"
        ;;
    pct)
        _p=${2:-}
        [ -n "$_p" ] || drm_die "用法: $0 pct <0-100>"
        _m=$(bl_max)
        _v=$(awk -v p="$_p" -v m="$_m" 'BEGIN{ printf "%d\n", int(p*m/100 + 0.5) }')
        [ "$_v" -gt 0 ] || drm_die "0% 就是全黑，拒绝"
        do_set_kde "$(sysfs2kde "$_v")"
        ;;
    step)
        _dir=${2:-up}; _n=${3:-5}
        _m=$(bl_max); _cur=$(bl_get)
        _delta=$(awk -v n="$_n" -v m="$_m" 'BEGIN{ printf "%d\n", int(n*m/100 + 0.5) }')
        if [ "$_dir" = "down" ]; then
            _v=$((_cur - _delta))
            [ "$_v" -lt 1 ] && _v=1
        else
            _v=$((_cur + _delta))
            [ "$_v" -gt "$_m" ] && _v=$_m
        fi
        do_set_kde "$(sysfs2kde "$_v")"
        ;;
    raw)
        _v=${2:-}
        [ -n "$_v" ] || drm_die "用法: $0 raw <0-4095>"
        if [ "$_v" -le 0 ] 2>/dev/null && [ "${3:-}" != "--force" ]; then
            drm_die "拒绝把背光设成 0（全黑）。恢复：echo $(bl_get) > $BLN"
        fi
        echo "$_v" >"$BLN" || drm_die "写 $BLN 失败"
        echo "raw sysfs = $(bl_get)"
        drm_warn "raw 绕过了 KDE，KDE 侧记的亮度已经和硬件不一致（下次拖滑块会跳）"
        ;;
    selftest)
        _orig=$(bl_get)
        _m=$(bl_max)
        _lo=$(awk -v m="$_m" 'BEGIN{ printf "%d\n", int(m*0.20) }')
        _hi=$(awk -v m="$_m" 'BEGIN{ printf "%d\n", int(m*0.60) }')
        echo "原值 sysfs=$_orig；测试 20%→$_lo、60%→$_hi，最后恢复"
        _fails=0
        for _t in "$_lo" "$_hi"; do
            _k=$(sysfs2kde "$_t")
            kde_set "$_k" >/dev/null
            sleep 2
            _got=$(bl_get)
            if [ "$_got" = "$_t" ]; then
                echo "  ✓ kde=$_k → sysfs=$_got"
            else
                echo "  ✗ kde=$_k → sysfs=$_got（预期 $_t）"
                _fails=$((_fails + 1))
            fi
        done
        # 恢复原值
        kde_set "$(sysfs2kde "$_orig")" >/dev/null
        sleep 2
        echo "恢复后 sysfs=$(bl_get)（原 $_orig）"
        [ "$_fails" = 0 ] && echo "===== 自测通过 =====" || echo "===== 自测失败 $_fails 项 ====="
        exit "$_fails"
        ;;
    *)
        echo "用法: sh $0 [status|get|set <0-4095>|pct <0-100>|step up|down [n]|raw <0-4095>|selftest]" >&2
        exit 2
        ;;
esac

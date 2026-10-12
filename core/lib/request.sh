#!/bin/sh
# core/lib/request.sh — 容器侧 ⇄ 安卓侧的请求文件协议。
#
# ══ 为什么需要这么一层 ══
# 接管（进 Linux）必须停掉 surfaceflinger 和 composer HAL。这件事只有
# **安卓侧**做得到，原因有二：
#
#   1. 容器里没有 adb 能力。实测 Droidspaces v6.6.0 的容器里
#      /dev/bus/usb 不存在（没有 USB 节点），adbd 也没监听 TCP，
#      所以容器里的 `adb devices` **恒为空**。
#   2. 停服务靠 init 的属性服务（setprop ctl.stop ...），那需要
#      /dev/__properties__ 与属性 socket —— 容器里没有。
#
# 所以方向反过来：**容器写请求文件，安卓侧的常驻守护执行**。
# 「返回安卓」本来就是这个模式（.drm-exit-request），这里把它推广成
# 一条完整的双向协议，而不是给接管单开一条特殊通道。
#
# ══ 协议 ══
#   会合目录（两侧同一个目录，见 common.sh 的 DRM_RENDEZVOUS）：
#     容器侧  /var/lib/droid-drm-takeover
#     安卓侧  <rootfs>/var/lib/droid-drm-takeover
#
#   容器 → 安卓（只判"文件在不在"，内容不参与决策）：
#     enter.request    请接管，进入 Linux
#     exit.request     请返回安卓（停容器 + 整机重启）
#
#   安卓 → 容器：
#     enter.result     接管结果，首行 ok 或 fail <原因>
#     device           设备代号（容器侧认设备用，见 device.sh）
#     serial           设备序列号
#     heartbeat        守护每轮刷新，容器侧据此判断"安卓侧还在听"
#
# ══ ★ 为什么不做"直接调 adb"的降级路径 ══
# 因为它在真机上**从来不成立**，留着只会让失败点从"请求超时"
# 变成一个语焉不详的 adb 错误。宁可一开始就明确：这个通道是唯一的路。

# ── 安卓侧：发布身份信息 ──────────────────────────────────
#
# ★ 容器侧认不出设备就会退回 generic，而 generic 的 DEV_COMPOSER_SVC
#   之类是"通用默认值"——在真机上就是错的，会去停一个不存在的服务。
#
# ★ 多容器：**每个容器的会合目录都要发一份**。容器侧是各自读自己 rootfs
#   里那份 `device` / `serial` 的；只发默认容器的话，从第二个容器进来就
#   认不出设备。
drm_identity_publish() {
    _sn=$(drm_android_prop ro.serialno 2>/dev/null)
    for _d in $(drm_rendezvous_ensure_all 2>/dev/null); do
        [ -n "$_d" ] || continue
        [ -n "$DRM_DEVICE" ] && printf '%s\n' "$DRM_DEVICE" >"$_d/device" 2>/dev/null
        [ -n "$_sn" ] && printf '%s\n' "$_sn" >"$_d/serial" 2>/dev/null
        chmod 644 "$_d/device" "$_d/serial" 2>/dev/null
    done
    return 0
}

# ── 安卓侧：守护心跳 ──────────────────────────────────────
drm_heartbeat_touch() {
    _d=$(drm_rendezvous_local 2>/dev/null) || return 0
    [ -d "$_d" ] || return 0
    date +%s >"$_d/heartbeat" 2>/dev/null
    return 0
}

# ── 容器侧：发请求 ────────────────────────────────────────
#
# 用法: drm_request_send enter|exit
drm_request_send() {
    _d=$(drm_rendezvous_ensure 2>/dev/null) || {
        drm_err "建不出会合目录 $DRM_RENDEZVOUS —— 无法与安卓侧通信"
        return 1
    }
    case "$1" in
        enter) _f="$_d/enter.request" ;;
        exit)  _f="$_d/exit.request" ;;
        *)     drm_err "未知请求：$1"; return 1 ;;
    esac
    rm -f "$_d/enter.result" 2>/dev/null
    : >"$_f" || { drm_err "写不了 $_f"; return 1; }
    chmod 666 "$_f" 2>/dev/null
    drm_log "已向安卓侧发出请求：$1（$_f）"
    return 0
}

# 安卓侧守护还在听吗？（心跳新鲜度）
drm_android_watcher_alive() {
    _d=$(drm_rendezvous_local 2>/dev/null) || return 1
    [ -r "$_d/heartbeat" ] || return 1
    _hb=$(cat "$_d/heartbeat" 2>/dev/null)
    _now=$(date +%s)
    case "$_hb" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$((_now - _hb))" -le "${1:-30}" ]
}

# 容器侧：读接管结果。返回 0=ok，1=fail，2=还没有结果
drm_request_result() {
    _d=$(drm_rendezvous_local 2>/dev/null) || return 2
    [ -r "$_d/enter.result" ] || return 2
    _r=$(head -1 "$_d/enter.result" 2>/dev/null | tr -d '\r')
    case "$_r" in
        ok)   return 0 ;;
        fail*) drm_err "安卓侧报告接管失败：${_r#fail }"; return 1 ;;
        *)    return 2 ;;
    esac
}

# 容器侧：等一个请求被处理完。
#
# ★ 判据不能只看 result 文件：接管**成功**的标志是本侧 kwin 拿到了
#   card0（本侧就能验，不需要任何跨侧信息）。result 只是用来区分
#   "失败了" 和 "还在进行中"，避免把失败也等成超时。
#
# 用法: drm_request_wait_enter <秒数>
drm_request_wait_enter() {
    _max=${1:-120}
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        if drm_card_fd_holders "$DEV_DRM_CARD" 2>/dev/null | grep -q .; then
            return 0
        fi
        drm_request_result
        case $? in
            0) return 0 ;;
            1) return 1 ;;
        esac
        sleep 1
        _i=$((_i + 1))
    done
    drm_err "等 ${_max}s 安卓侧仍未完成接管"
    return 1
}

# 容器侧：等待前先确认安卓侧守护在跑，否则请求会石沉大海
drm_request_require_watcher() {
    if drm_android_watcher_alive 60; then
        return 0
    fi
    drm_err "安卓侧的接管守护没有在跑（心跳过期）—— 请求不会被处理"
    drm_warn "请先在安卓侧执行：su -c 'sh $DRM_ANDROID_PAYLOAD/android/exit-watch.sh start'"
    return 1
}

#!/bin/sh
# core/lib/device.sh — 设备适配层的加载器与自动探测。
#
# 【设计原则】★ 这是本次重构最重要的一条约定：
#
#   core/device/<codename>.sh  =  **纯数据**（变量赋值 + 可选钩子函数）
#   core/lib/*.sh              =  **全部逻辑**
#
#   重构前设备差异散落在 ade.sh / device-opd2413.sh / desk-takeover.sh
#   三条链里，同名常量写了两三份（连桌面用户名都不一致：Gold vs xieyizhou），
#   换设备要改 10+ 个文件。现在只改一个数据文件。
#
# 【加载顺序】
#   1. 调用方可以显式指定：DRM_DEVICE=opd2511
#   2. 否则读安卓的 ro.product.device / ro.product.model 自动匹配
#   3. 匹配不到就用 core/device/generic.sh（全运行时发现，功能最少但不报错）

DRM_DEVICE_DIR=${DRM_DEVICE_DIR:-}

drm_device_dir_resolve() {
    [ -n "$DRM_DEVICE_DIR" ] && return 0
    # ★ 第一项用 DRM_ROOT —— 所有入口（core/switch.sh、core/lib/boot.sh、
    #   linux/*.sh、tools/verify/*.sh）都会在 source 本文件之前设好它。
    #
    #   这里原来是 `$(dirname "$0")/../device`，注释写着"相对本文件定位"，
    #   但它是错的：POSIX 里被 source 的文件看到的 $0 是**调用方**的路径。
    #   从 core/switch.sh 调用时算出的是 `core/../device` = `device`，
    #   根本不存在。设备上之所以还能跑，纯粹是被后面的绝对路径兜底救了 ——
    #   换句话说换个安装前缀（linux/install.sh --prefix /opt/foo）就会直接 die，
    #   而在仓库里直接跑任何脚本都会 die。
    for _c in \
        "$DRM_ROOT/core/device" \
        "/root/$DRM_PROJECT/core/device" \
        "${DRM_ANDROID_PAYLOAD:-/data/local/$DRM_PROJECT}/core/device" \
        "/opt/$DRM_PROJECT/core/device"
    do
        [ -d "$_c" ] && { DRM_DEVICE_DIR="$_c"; return 0; }
    done
    return 1
}

# 读安卓属性（安卓侧直接 getprop；容器侧没有，返回空）
drm_android_prop() {
    if [ "$DRM_SIDE" = android ]; then
        getprop "$1" 2>/dev/null | tr -d '\r'
    else
        return 1
    fi
}

# 共享目录的候选列表（容器视角 + host 视角）。
#
# ★ 这里存在一个**先有鸡还是先有蛋**，必须显式解开：
#   容器侧认设备靠读共享目录里的 .drm-device，而共享目录路径 DEV_SHARED
#   本身**定义在设备适配层里** —— 适配层还没选中，DEV_SHARED 就是空的。
#   结果容器侧永远读不到 .drm-device ⇒ 退回 generic ⇒ DEV_COMPOSER_SVC
#   之类全是通用默认值 ⇒ 停错服务。
#   解法：不依赖 DEV_SHARED，把所有可能的视角都列出来试。
#   · /root 和 $HOME 是**容器自己的视角** —— 容器的 /root 就是 host 侧的
#     <rootfs>/root，所以这条在容器里几乎总是命中。
#   · 后两条是 host 视角，容器里通常看不到，但万一是 bind 进来的就有用。
drm_shared_candidates() {
    [ -n "${DEV_SHARED:-}" ] && printf '%s\n' "$DEV_SHARED"
    [ -n "${HOME:-}" ] && printf '%s\n' "$HOME"
    printf '%s\n' /root
    _hn=$(head -1 /etc/hostname 2>/dev/null | tr -d '\r')
    [ -n "$_hn" ] && printf '%s\n' "/data/local/Droidspaces/Containers/$_hn/rootfs/root"
    [ -n "${DEV_CONTAINER:-}" ] && printf '%s\n' "/data/local/Droidspaces/Containers/$DEV_CONTAINER/rootfs/root"
    return 0
}

# 本侧的共享目录 —— 容器 /root ↔ host 侧 <rootfs>/root，是同一个目录的
# 两个视角。请求文件协议（.drm-enter-request / .drm-exit-request /
# .drm-enter-result）靠它落地，两侧必须指到同一个地方。
drm_shared_local() {
    if [ "$DRM_SIDE" = android ]; then
        ds_shared_dir 2>/dev/null && return 0
        printf '%s\n' "${DEV_SHARED:-}"
    else
        for _d in $(drm_shared_candidates); do
            [ -n "$_d" ] && [ -d "$_d" ] && { printf '%s\n' "$_d"; return 0; }
        done
        printf '%s\n' "${HOME:-/root}"
    fi
}

# 请求会合目录的**本侧**路径（两侧指向同一个目录的两个视角）。
#
# ★ 安卓侧必须用 rootfs 的**根**，不是 ds_shared_dir（那是 `<rootfs>/root`，
#   即容器的 /root）。用错了会得到容器里的 `/root/var/lib/...`，
#   与容器侧算出来的 `/var/lib/...` 不是同一个地方 ⇒ 请求永远送不到。
# 详见 common.sh 里 DRM_RENDEZVOUS 的注释。
drm_rendezvous_local() {
    if [ "$DRM_SIDE" = android ]; then
        _rf=$(ds_rootfs_dir 2>/dev/null) || _rf=""
        [ -n "$_rf" ] || return 1
        printf '%s\n' "$_rf/var/lib/$DRM_PROJECT"
    else
        printf '%s\n' "$DRM_RENDEZVOUS"
    fi
}

# 确保会合目录存在且可写（1777）。两侧都会调，谁先跑谁建。
drm_rendezvous_ensure() {
    _d=$(drm_rendezvous_local 2>/dev/null) || return 1
    [ -n "$_d" ] || return 1
    if [ ! -d "$_d" ]; then
        mkdir -p "$_d" 2>/dev/null || return 1
    fi
    # 每次都纠正权限：rootfs 可能是别人建的，或者 umask 不对。
    chmod 1777 "$_d" 2>/dev/null || true
    [ -d "$_d" ] || return 1
    printf '%s\n' "$_d"
}

# 自动识别设备代号
drm_detect_codename() {
    if [ "$DRM_SIDE" = android ]; then
        _p=$(drm_android_prop ro.product.device)
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
        _p=$(drm_android_prop ro.product.model)
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
    fi
    # 容器侧：从落盘记录读（安卓侧守护会写，见 core/lib/request.sh）
    for _d in $(drm_shared_candidates); do
        [ -n "$_d" ] || continue
        if [ -r "$_d/.drm-device" ]; then
            head -1 "$_d/.drm-device"
            return 0
        fi
    done
    # 再试会合目录里的 device（容器侧桌面用户也读得到，权限 1777）
    _rd=$(drm_rendezvous_local 2>/dev/null) || _rd=""
    if [ -n "$_rd" ] && [ -r "$_rd/device" ]; then
        head -1 "$_rd/device"
        return 0
    fi
    return 1
}

# 把设备文件里的 "别名" 映射到文件名。一个设备可能同时有
# 厂商代号（OP6546L1）和市场型号（OPD2511），两个都要能命中。
drm_device_alias_file() {
    case "$1" in
        OPD2511|OP6546L1|pineapple|sm8650|SM8650Q) echo opd2511 ;;
        OPD2413|sun|sm8750)                          echo opd2413 ;;
        piano|xiaomi-piano|24018RPACC)               echo piano ;;
        *)                                           echo "" ;;
    esac
}

drm_device_load() {
    drm_device_dir_resolve || drm_die "找不到 core/device 目录（DRM_DEVICE_DIR 未设置）"

    _want=${DRM_DEVICE:-}
    if [ -z "$_want" ]; then
        _cn=$(drm_detect_codename 2>/dev/null || true)
        _want=$(drm_device_alias_file "$_cn")
        [ -n "$_want" ] && drm_log "自动识别设备：$_cn → 适配层 $_want"
    fi

    if [ -n "$_want" ] && [ -f "$DRM_DEVICE_DIR/$_want.sh" ]; then
        # shellcheck source=/dev/null
        . "$DRM_DEVICE_DIR/$_want.sh"
    else
        drm_warn "没有匹配的设备适配层，回退 generic（全部运行时发现）"
        # shellcheck source=/dev/null
        . "$DRM_DEVICE_DIR/generic.sh"
        _want=generic
    fi

    DRM_DEVICE=$_want
    export DRM_DEVICE

    # 通用兜底：适配层没定义的键，给一个安全默认值。
    # 这样新增设备时只需写真正不同的那几项。
    drm_device_defaults

    drm_log "设备适配层：$DEV_CODENAME ($DEV_MODEL) 面板 ${DEV_PANEL_W}x${DEV_PANEL_H}"
}

# 未定义项的默认值。★ 这里的默认值必须是"运行时发现"而不是"抄某个设备的常量"——
# 重构前 setprop.c 默认 connector 67、kwinwrap.c 默认 SPLIT_CRTC 200，
# 换设备后静默写错对象，排查一整天。
drm_device_defaults() {
    : "${DEV_CODENAME:=unknown}"
    : "${DEV_MODEL:=unknown}"
    : "${DEV_PLATFORM:=unknown}"

    : "${DEV_SF_SVC:=surfaceflinger}"
    : "${DEV_COMPOSER_SVC:=vendor.qti.hardware.display.composer}"

    : "${DEV_CONTAINER:=drm}"
    : "${DEV_DS_BIN:=/data/local/Droidspaces/bin/droidspaces}"
    : "${DEV_DS_CFG:=/data/local/Droidspaces/Containers/$DEV_CONTAINER/container.config}"

    : "${DEV_DRM_CARD:=/dev/dri/card0}"
    : "${DEV_DRM_RENDER:=/dev/dri/renderD128}"
    : "${DEV_DRM_MAJOR:=226}"
    : "${DEV_DRM_MINOR:=0}"
    : "${DEV_DRM_RENDER_MINOR:=128}"
    : "${DEV_DRM_DEVPATH:=}"
    : "${DEV_DRM_DRIVER_ALIAS:=vmwgfx}"

    : "${DEV_BACKLIGHT:=}"
    : "${DEV_BRIGHTNESS:=2048}"

    : "${DEV_PANEL_W:=0}"
    : "${DEV_PANEL_H:=0}"

    : "${DEV_TOUCH_NAME:=}"
    : "${DEV_TOUCH_CALIB:=}"
    : "${DEV_TOUCH_GROUP:=}"

    : "${DEV_POGO_TTY:=}"
    : "${DEV_POGO_STATUS_NODE:=}"
    : "${DEV_TOUCHPAD_NAME:=}"

    : "${DEV_WIFI_IF:=wlan0}"
    : "${DEV_ROUTE_TABLE:=1042}"
    : "${DEV_ROUTE_PREF:=31500}"

    : "${DEV_NEEDS_KSU_XWL_SHIM:=0}"
    : "${DEV_KWIN_EXTRA_ARGS:=}"
    : "${DEV_MESA_OVERRIDE:=}"

    # 这些是"设备相关的动作"，适配层可以覆盖成自己的命令串。
    # 默认值只覆盖 AOSP 通用部分，厂商私有开关留给适配层。
    : "${DEV_WATCHDOG_DISARM:=}"
    : "${DEV_WATCHDOG_REARM:=}"
    : "${DEV_KERNEL_DEBUG_OFF:=}"
    : "${DEV_KERNEL_DEBUG_ON:=}"

    # 共享目录：容器 /root ←→ 安卓 /mnt/Droidspaces/<容器>/root
    : "${DEV_SHARED:=/mnt/Droidspaces/$DEV_CONTAINER/root}"
    : "${DEV_DESKTOP_USER_HINT:=}"
}

# ── 可选钩子 ──
# 适配层可以定义这些函数，lib 会在对应时机调用（未定义则跳过）。
# 用 `command -v` 判断，所以适配层不写就完全没有开销。

drm_device_hook() {
    _h=$1; shift
    if command -v "$_h" >/dev/null 2>&1; then
        drm_log "设备钩子 $_h"
        "$_h" "$@"
    fi
}

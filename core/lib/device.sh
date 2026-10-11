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

# 自动识别设备代号
drm_detect_codename() {
    if [ "$DRM_SIDE" = android ]; then
        _p=$(drm_android_prop ro.product.device)
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
        _p=$(drm_android_prop ro.product.model)
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
    fi
    # 容器侧：从共享目录里的落盘记录读（安卓侧每次接管会写）
    if [ -n "${DEV_SHARED:-}" ] && [ -r "$DEV_SHARED/.drm-device" ]; then
        head -1 "$DEV_SHARED/.drm-device"
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

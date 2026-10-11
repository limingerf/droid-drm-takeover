#!/bin/sh
# core/device/generic.sh — 未知设备的兜底适配层。
#
# 定位：**不抄任何设备的常量**，全部交给 lib 在运行时发现。
# 功能最少（没有 pogo、没有厂商 quirk），但绝不会因为 ID 写错而静默失败。
# 换新设备时先跑这个确认通路，再照 docs/适配新设备.md 生成专属适配层。
#
# ★ 这正是重构前最大的技术债：kwinwrap.c 里 SPLIT_CRTC=200 / SPLIT_CONN=67
#   是 piano 的 ID，setprop.c 默认 connector 也是 67。换设备后它们**不报错**，
#   只是往错误的对象上写属性，现象是"kwin 起来了、也有 master、就是不出画"。

DEV_CODENAME=generic
DEV_MODEL="unknown device"
DEV_PLATFORM=unknown

DEV_SF_SVC=surfaceflinger
DEV_COMPOSER_SVC=vendor.qti.hardware.display.composer

DEV_CONTAINER=drm
DEV_DS_BIN=/data/local/Droidspaces/bin/droidspaces
DEV_DS_CFG=/data/local/Droidspaces/Containers/drm/container.config

DEV_DRM_CARD=/dev/dri/card0
DEV_DRM_RENDER=/dev/dri/renderD128
DEV_DRM_MAJOR=226
DEV_DRM_MINOR=0
DEV_DRM_RENDER_MINOR=128
DEV_DRM_DEVPATH=""
DEV_DRM_DRIVER_ALIAS=vmwgfx

DEV_BACKLIGHT=""
DEV_BRIGHTNESS=2048
DEV_PANEL_W=0
DEV_PANEL_H=0

DEV_TOUCH_NAME=""
DEV_TOUCH_PEN_NAME=""
DEV_TOUCH_CALIB=""
DEV_TOUCH_GROUP=""

DEV_POGO_TTY=""
DEV_POGO_STATUS_NODE=""
DEV_TOUCHPAD_NAME=""

DEV_WIFI_IF=wlan0
DEV_ROUTE_TABLE=1042
DEV_ROUTE_PREF=31500

DEV_NEEDS_KSU_XWL_SHIM=0
DEV_MESA_OVERRIDE=""
DEV_KWIN_EXTRA_ARGS="--no-lockscreen"

DEV_WATCHDOG_DISARM="settings put global watchdog_timeout 86400000"
DEV_WATCHDOG_REARM="settings delete global watchdog_timeout"
DEV_KERNEL_DEBUG_OFF="echo 0x0 > /sys/module/drm/parameters/debug 2>/dev/null"
DEV_KERNEL_DEBUG_ON="echo 0xffffffff > /sys/module/drm/parameters/debug 2>/dev/null"

DEV_DESKTOP_USER_HINT=""

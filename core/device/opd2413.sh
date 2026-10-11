#!/bin/sh
# core/device/opd2413.sh — 一加平板 2 Pro（OPD2413 / sun / sm8750 / Adreno 830）
#
# 这一台是参考仓库 Goldzxcbug/droid-drm-takeover 的验证机。
# 数值来自该仓库的 ade/device-opd2413.sh 与 README（未在本机复测）。
# 保留它有两个用处：
#   1) 让你能对比"同一套 lib 在两个设备上分别喂什么数据"；
#   2) 换设备时照着它抄格式。

DEV_CODENAME=opd2413
DEV_MODEL="OnePlus Pad 2 Pro (OPD2413)"
DEV_PLATFORM=sun

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

DEV_BACKLIGHT=panel0-backlight
DEV_BRIGHTNESS=1024
DEV_PANEL_W=3392
DEV_PANEL_H=2400

# 参考仓库 device-opd2413.sh:316 的触摸屏名是 `touchpanel`
DEV_TOUCH_NAME=touchpanel
DEV_TOUCH_PEN_NAME=""
DEV_TOUCH_CALIB="0 1 0 -1 0 1 0 0 1"
DEV_TOUCH_GROUP="11/6/15d9"

DEV_POGO_TTY=/dev/ttyHS5
DEV_POGO_STATUS_NODE=/proc/pogopin/kbd_keypad_status
DEV_TOUCHPAD_NAME=pogo_touchpad

DEV_WIFI_IF=wlan0
DEV_ROUTE_TABLE=1042
DEV_ROUTE_PREF=31500

DEV_NEEDS_KSU_XWL_SHIM=1
DEV_MESA_OVERRIDE=""
DEV_KWIN_EXTRA_ARGS="--no-lockscreen --xwayland"

DEV_WATCHDOG_DISARM="settings put global watchdog_timeout 86400000; settings put global watchdog 0; setprop persist.sys.stability.nativehang.enable false; settings put global stay_on_while_plugged_in 7"
DEV_WATCHDOG_REARM="settings delete global watchdog_timeout; settings delete global watchdog; settings delete global stay_on_while_plugged_in; setprop persist.sys.stability.nativehang.enable true"
DEV_KERNEL_DEBUG_OFF="echo 0x0 > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0x0 > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"
DEV_KERNEL_DEBUG_ON="echo 0xffffffff > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x3f > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0xffffffff > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"

DEV_DESKTOP_USER_HINT=""

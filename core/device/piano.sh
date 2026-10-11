#!/bin/sh
# core/device/piano.sh — 小米平板 8 Pro（codename piano，Adreno 830 / msm_geni_serial）
#
# 这一台是本仓库（limingerf 版）重构前脚本里**硬编码常量**的来源：
#   · kwinwrap.c  SPLIT_CRTC=200 / SPLIT_CONN=67 / SPLIT_W=1600 / SPLIT_H=2136
#   · setprop.c   默认 connector 67
#   · touchinj.c  PANEL_W=3200 / PANEL_H=2136
#   · 各探针      crtc 206 / conn 67 / plane 157,161
# 那些常量**只对这台设备成立**。现在它们退回适配层，运行时发现优先。
#
# 数值来自重构前脚本与 README（未在本机复测）。

DEV_CODENAME=piano
DEV_MODEL="Xiaomi Pad 8 Pro (piano)"
DEV_PLATFORM=msm_geni_serial

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
# piano 上 card0 被厂商从文件系统里删掉了，但驱动仍在内核里活着；
# lib 会用 sysfs 读出主次号后 mknod 重建，不依赖这个 DEVPATH。
DEV_DRM_DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0
DEV_DRM_DRIVER_ALIAS=vmwgfx

DEV_BACKLIGHT=panel0-backlight
DEV_BRIGHTNESS=2048
DEV_PANEL_W=3200
DEV_PANEL_H=2136

DEV_TOUCH_NAME=NVTCapacitiveTouchScreen
DEV_TOUCH_PEN_NAME=""
DEV_TOUCH_CALIB="0 1 0 -1 0 1 0 0 1"
DEV_TOUCH_GROUP=""

DEV_POGO_TTY=""
DEV_POGO_STATUS_NODE=""
DEV_TOUCHPAD_NAME=""

DEV_WIFI_IF=wlan0
DEV_ROUTE_TABLE=1042
DEV_ROUTE_PREF=31500

DEV_NEEDS_KSU_XWL_SHIM=1
DEV_MESA_OVERRIDE=""
DEV_KWIN_EXTRA_ARGS="--no-lockscreen"

# piano 是 HyperOS/MIUI，除 AOSP watchdog 外还有小米自己的稳定性守护。
# ★ 重构前的教训（drm-takeover.sh:97-105 注释）：
#   SF 停 ~120s 后 system_server 自己的 watchdog 线程会杀掉 system_server，
#   init 级联 SIGKILL wpa_supplicant/netd/zygote ⇒ WiFi 掉线且 UI 不可用，
#   只能强重启。必须在动手之前就解除武装。
DEV_WATCHDOG_DISARM="settings put global watchdog_timeout 86400000; settings put global watchdog 0; setprop persist.sys.stability.nativehang.enable false; setprop persist.sys.stability.nativehangII.enable false; setprop persist.sys.stability.qcom_hang_task.enable false; settings put global stay_on_while_plugged_in 7"
DEV_WATCHDOG_REARM="settings delete global watchdog_timeout; settings delete global watchdog; settings delete global stay_on_while_plugged_in; setprop persist.sys.stability.nativehang.enable true; setprop persist.sys.stability.nativehangII.enable true; setprop persist.sys.stability.qcom_hang_task.enable true"
DEV_KERNEL_DEBUG_OFF="echo 0x0 > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0x0 > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"
DEV_KERNEL_DEBUG_ON="echo 0xffffffff > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x3f > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0xffffffff > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"

DEV_DESKTOP_USER_HINT=""

#!/bin/sh
# core/device/opd2511.sh — 一加/OPPO 平板 OPD2511（高通 pineapple / SM8650Q）
#
# 【本文件只放数据】逻辑一律在 core/lib/*.sh。
# 【标注约定】
#   ✔实测 = 在这台设备上确认过
#   ~推测 = 按平台惯例填的，首次上机请用 docs/适配新设备.md 的探针核对
#   ✗未知 = 留空，由 lib 在运行时发现
#
# 设备事实（✔实测，2026-10-11）：
#   ro.product.model  = OPD2511
#   ro.product.device = OP6546L1
#   ro.board.platform = pineapple
#   ro.soc.model      = SM8650Q
#   ro.build.version.release = 17 (SDK 37)
#   kernel            = 6.1.177-android14-11-g4056c236e4c84 (aarch64)
#   SELinux           = Enforcing；root = KernelSU (context u:r:ksu:s0)
#   panel             = card0-DSI-1 3200x2000@120（另有 144 / 90 模式），dual DSI
#   touch             = NVTCapacitiveTouchScreen（+ NVTCapacitivePen 手写笔）
#   crtc              = sde-crtc-0..5（6 个）
#   drm               = /dev/dri/card0 226:0、renderD128 226:128（world rw）
#   gpu               = /dev/kgsl-3d0（world rw）
#   composer          = vendor.qti.hardware.display.composer（init.svc running）
#   audio             = /dev/snd 存在（controlC0 + 大量 pcmC0D*）

DEV_CODENAME=opd2511
DEV_MODEL="OnePlus/OPPO OPD2511 (OP6546L1)"
DEV_PLATFORM=pineapple

# ── 安卓服务 ──────────────────────────────────────────────
DEV_SF_SVC=surfaceflinger
DEV_COMPOSER_SVC=vendor.qti.hardware.display.composer    # ✔实测

# ── Droidspaces 容器 ──────────────────────────────────────
# 容器名沿用参考仓库的 `drm`；若你建的是别的名字，只改这两行。
DEV_CONTAINER=drm
DEV_DS_BIN=/data/local/Droidspaces/bin/droidspaces
DEV_DS_CFG=/data/local/Droidspaces/Containers/drm/container.config

# ── 显示 ──────────────────────────────────────────────────
DEV_DRM_CARD=/dev/dri/card0                              # ✔实测
DEV_DRM_RENDER=/dev/dri/renderD128                       # ✔实测
DEV_DRM_MAJOR=226
DEV_DRM_MINOR=0
DEV_DRM_RENDER_MINOR=128
# ✗未知：本机 sysfs 路径待确认。留空则 lib 用 /sys/class/drm/card0 反查，
# 合成的 udev 记录里 DEVPATH 用不到就省掉（kwin 只依赖 DEVTYPE/DEVNAME/DRIVER）。
DEV_DRM_DEVPATH=""
# kwin 的 Hardware 白名单只收 i915/amdgpu/nouveau/vmwgfx；msm_drm 会被过滤。
# vmwgfx 在 kwin 里没有特殊 quirk，是最安全的伪装（参考仓库实测结论）。
DEV_DRM_DRIVER_ALIAS=vmwgfx

DEV_PANEL_W=3200                                         # ✔实测
DEV_PANEL_H=2000                                         # ✔实测

# ✗未知：待 `ls /sys/class/backlight/` 确认。留空则 lib 运行时扫描，
# 扫不到就退回直接写 DRM connector 的 brightness 属性。
DEV_BACKLIGHT=""
DEV_BRIGHTNESS=2048

# ── 触摸 ──────────────────────────────────────────────────
DEV_TOUCH_NAME=NVTCapacitiveTouchScreen                  # ✔实测
DEV_TOUCH_PEN_NAME=NVTCapacitivePen                      # ✔实测
# ✗未知：旋转/翻转矩阵需要上机用 docs/适配新设备.md 的触摸校准流程实测。
# 参考机 OPD2413 用的是 "0 1 0 -1 0 1 0 0 1"（90° 旋转 + 垂直翻转）。
# 留空则不改矩阵（libinput 用驱动自带值），先跑通再加。
DEV_TOUCH_CALIB=""
DEV_TOUCH_GROUP=""

# ── 磁吸键盘 / 触摸板（pogo）──────────────────────────────
# ✗未知：本机是否有 pogo 键盘、走哪个 tty。留空则完全跳过 pogo 逻辑。
DEV_POGO_TTY=""
DEV_POGO_STATUS_NODE=""
DEV_TOUCHPAD_NAME=""

# ── 网络 ──────────────────────────────────────────────────
DEV_WIFI_IF=wlan0                                        # ✔实测
# 安卓 netd 用 per-interface 路由表 + fwmark；`stop` 杀掉 netd 后没人维护，
# 一路落到 `32000: from all unreachable`（现象：有 IP、ping 通网关、外网不通）。
# 兜底要加**独立表**，且 rule 优先级夹在 netd 的 31000 与 32000 之间。
DEV_ROUTE_TABLE=1042
DEV_ROUTE_PREF=31500

# ── 平台 quirk ────────────────────────────────────────────
# KernelSU 的 enhanced_security 会把 Xwayland `PrivsElevated()` 的
# seteuid(0) 试探当提权攻击直接 SIGKILL（现象：Wayland 应用全好、
# X11 应用一个都起不来）。本机是 KernelSU ⇒ 需要垫片。
DEV_NEEDS_KSU_XWL_SHIM=1                                 # ✔实测（root context=u:r:ksu:s0）
# 本机 kernel 6.1 + msm_drm：不注入 MESA_* 到 kwin（参考仓库实测会花屏转纯黑）
DEV_MESA_OVERRIDE=""
DEV_KWIN_EXTRA_ARGS="--no-lockscreen --xwayland"

# ── 安卓稳定性开关（接管期间要解除武装）────────────────────
# ✗未知：本机是 ColorOS 17，是否仍有 MIUI 那套 nativehang / qcom_hang_task
# 需要上机用 `settings list global | grep -i watchdog` 核对。
# 下面是 AOSP 通用项 + 高通常见项，不存在的设置写进去也无害（会报 not found）。
DEV_WATCHDOG_DISARM="settings put global watchdog_timeout 86400000; settings put global stay_on_while_plugged_in 7"
DEV_WATCHDOG_REARM="settings delete global watchdog_timeout; settings delete global stay_on_while_plugged_in"

# ── 内核调试参数（接管期间必须关，否则每次 atomic 打印数百行、帧率崩）──
# 本机是 msm_drm（✔实测 CONFIG_DRM=y）。drm.debug 是通用项。
DEV_KERNEL_DEBUG_OFF="echo 0x0 > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0x0 > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"
DEV_KERNEL_DEBUG_ON="echo 0xffffffff > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x3f > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0xffffffff > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"

# ── 桌面账号 ──────────────────────────────────────────────
# 留空 = 运行时用 getent passwd 1000 解析（重构前写死 Gold/xieyizhou 是错的）
DEV_DESKTOP_USER_HINT=""

# ── 钩子：接管前的设备专属准备 ─────────────────────────────
# 需要"在 framework 还活着时"做的修复放这里（例如音量归零、蓝牙复位）。
# 本机暂时没有必须项；保留空实现作为后续扩展点。
dev_pre_stop_fixes() {
    :
}

# ── 钩子：会话起来之后的设备专属收尾 ───────────────────────
dev_post_session_fixes() {
    :
}

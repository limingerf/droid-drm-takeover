#!/bin/sh
# core/device/opd2511.sh — 一加/OPPO 平板 OPD2511（高通 pineapple / SM8650Q）
#
# 【本文件只放数据】逻辑一律在 core/lib/*.sh。
# 【标注约定】
#   ✔实测 = 在这台设备上确认过
#   ~推测 = 按平台惯例填的，首次上机请用 docs/适配新设备.md 的探针核对
#   ✗未知 = 留空，由 lib 在运行时发现
#
# 设备事实（✔实测，2026-10-11 真机）：
#   ro.product.model  = OPD2511
#   ro.product.device = OP6546L1
#   ro.board.platform = pineapple
#   ro.soc.model      = SM8650Q
#   ro.build.version.release = 17 (SDK 37)
#   kernel            = 6.1.177-android14-11-g4056c236e4c84 (aarch64)
#   SELinux           = Enforcing；root = KernelSU (context u:r:ksu:s0)
#   panel             = card0-DSI-1 3200x2000（完整宽度**单模式**，120/144/90/60）
#                       ✔实测 2026-10-12：安卓用**一个** CRTC + 一个 3200 宽平面
#                       点亮它。之前记的 "dual DSI 需拆两个 1600 半屏" 是错的
#                       （那是旧参考机 OPD2413 的形态），见下面 DEV_KWINWRAP_NO_SPLIT
#   touch             = NVTCapacitiveTouchScreen (event5) + NVTCapacitivePen (event6)
#   backlight         = panel0-backlight（max 4095）
#   crtc              = sde-crtc-0..5（6 个，drm id 200..205）
#   drm               = /dev/dri/card0 226:0、renderD128 226:128
#   gpu               = /dev/kgsl-3d0 484:0
#   composer          = vendor.qti.hardware.display.composer（init.svc running）
#
# 【Droidspaces 容器事实】（✔实测 2026-10-11，v6.6.0）
#   · 容器名 DEBIAN，Debian 13 (trixie)，systemd 作 PID 1
#   · CLI 与旧版不同：`droidspaces --name=DEBIAN run '<cmd>'`，
#     **没有** `-C <config> run` 这种用法
#   · rootfs 是普通目录：/data/local/Droidspaces/Containers/DEBIAN/rootfs
#     容器里的 /root 就是它下面的 root/ —— 安卓可直接读写，这就是共享目录
#   · 没有 /mnt/Droidspaces 这种挂载点（那是旧版行为）
#   · net_mode=host ⇒ 容器直接继承安卓网络，**不需要 WiFi 接管**
#   · enable_hw_access=1 ⇒ /dev 是容器自己的 devtmpfs，
#     Droidspaces 只**挑着挂**几个节点进去（实测有 renderD128 + kgsl，**没有 card0**，
#     /dev/input 也是空的）。所以 card0 和输入节点必须我们自己 mknod。
#     实测 mknod 出来的节点功能完整（kmsdump/connprops/kwinwrap 都能用，
#     输入节点可读，容器内 udev 已有 ID_INPUT_TOUCHSCREEN=1）。
#   · 容器里预装了完整 KDE Plasma（kwin_wayland / plasmashell / Xwayland），
#     由 desktop-session.service 在开机时以 Anland 后端拉起（渲染走 renderD128，
#     帧通过 /run/display.sock 送给安卓端显示，**不上物理屏**）。
#     我们的接管要把这个会话停掉，换成 kwinwrap + DRM 后端直接驱动面板。

DEV_CODENAME=opd2511
DEV_MODEL="OnePlus/OPPO OPD2511 (OP6546L1)"
DEV_PLATFORM=pineapple

# ── 安卓服务 ──────────────────────────────────────────────
DEV_SF_SVC=surfaceflinger
DEV_COMPOSER_SVC=vendor.qti.hardware.display.composer    # ✔实测

# ── Droidspaces 容器 ──────────────────────────────────────
DEV_CONTAINER=DEBIAN                                     # ✔实测
DEV_DS_BIN=/data/local/Droidspaces/bin/droidspaces       # ✔实测
DEV_DS_CFG=/data/local/Droidspaces/Containers/DEBIAN/container.config   # ✔实测
# 共享目录 = 容器 rootfs 下的 root/（容器里看到的 /root）
DEV_SHARED=/data/local/Droidspaces/Containers/DEBIAN/rootfs/root        # ✔实测
# 容器里开机自启的桌面会话单元。接管前要停掉它，否则两套合成器抢同一个面板。
DEV_SESSION_SVC=desktop-session                          # ✔实测

# ── 显示 ──────────────────────────────────────────────────
DEV_DRM_CARD=/dev/dri/card0                              # ✔实测
DEV_DRM_RENDER=/dev/dri/renderD128                       # ✔实测
DEV_DRM_MAJOR=226
DEV_DRM_MINOR=0
DEV_DRM_RENDER_MINOR=128
DEV_DRM_DEVPATH=""
# kwin 的 Hardware 白名单只收 i915/amdgpu/nouveau/vmwgfx；msm_drm 会被过滤。
# vmwgfx 在 kwin 里没有特殊 quirk，是最安全的伪装。
DEV_DRM_DRIVER_ALIAS=vmwgfx
# 我们自己 mknod 出来的节点，属组要跟 Droidspaces 自己挂的 renderD128 一致
# （实测 renderD128 是 root:droidspaces-gpu 660，Gold 在这个组里）
DEV_DRM_GROUP=droidspaces-gpu                            # ✔实测

DEV_PANEL_W=3200                                         # ✔实测
DEV_PANEL_H=2000                                         # ✔实测

DEV_BACKLIGHT=panel0-backlight                           # ✔实测
DEV_BRIGHTNESS=2048                                      # max=4095，取中间值

# ── 触摸 ──────────────────────────────────────────────────
DEV_TOUCH_NAME=NVTCapacitiveTouchScreen                  # ✔实测（event5）
DEV_TOUCH_PEN_NAME=NVTCapacitivePen                      # ✔实测（event6）
DEV_TOUCH_GROUP=input                                    # ✔实测（容器里 Gold 在 input 组）
# ✗未知：旋转/翻转矩阵需要上机实测。留空则不改矩阵（libinput 用驱动自带值），
# 先跑通再加。参考机 OPD2413 用的是 "0 1 0 -1 0 1 0 0 1"。
DEV_TOUCH_CALIB=""

# ── 磁吸键盘 / 触摸板（pogo）──────────────────────────────
# ✗未知：本机是否有 pogo 键盘、走哪个 tty。留空则完全跳过 pogo 逻辑。
DEV_POGO_TTY=""
DEV_POGO_STATUS_NODE=""
DEV_TOUCHPAD_NAME=""

# ── 网络 ──────────────────────────────────────────────────
# ★ 本机 net_mode=host：容器与安卓共享网络命名空间，直接继承安卓的
#   IP/路由/DNS。所以**完全不需要** WiFi 接管 —— 那套逻辑（wpa_supplicant
#   + DHCP + 兜底路由表）是为 net_mode=nat 的旧容器写的，这里跳过。
#   实测：容器里 `ip addr` 看到的就是安卓的接口，/etc/resolv.conf 已有 DNS。
DEV_NET_MODE=host                                        # ✔实测
DEV_WIFI_IF=wlan0
DEV_ROUTE_TABLE=1042
DEV_ROUTE_PREF=31500

# ── 平台 quirk ────────────────────────────────────────────
# KernelSU 的 enhanced_security 会把 Xwayland `PrivsElevated()` 的
# seteuid(0) 试探当提权攻击直接 SIGKILL（现象：Wayland 应用全好、
# X11 应用一个都起不来）。本机是 KernelSU ⇒ 需要垫片。
DEV_NEEDS_KSU_XWL_SHIM=1                                 # ✔实测
DEV_MESA_OVERRIDE=""
DEV_KWIN_EXTRA_ARGS="--no-lockscreen --xwayland"

# ⚠️⚠️ 保持**置空**！分屏是这台机器的**硬件必需**，不是可选优化。
#
# 曾经以为"安卓用完整宽度单模式，所以全宽单平面就行"——**这个判断是错的**，
# 实测被内核直接打回（2026-10-12）：
#
#   把本开关打开（=1，禁用分屏、让 KWin 原始提交透传）后：
#     · KWin 的提交全部 ret=-7 (E2BIG)，一个都没成功
#     · kwin_core: Applying output config failed!
#     · 内核 dmesg 把根因说得很清楚：
#         [_sde_crtc_check_plane_layout] [sde error]invalid horizontal destination
#         [sde error]x:0 w:3200 hdisp:1600 layout:1
#         [_sde_crtc_atomic_check] [sde error]crtc200 failed plane layout check -7
#       六个 CRTC（200/265/274/283/292/301）各失败 4 次，w:3200 hdisp:1600 共 24 次。
#
#   ⇒ SDE 的**每个 CRTC 最大水平显示宽度是 1600**，不是 3200。
#     面板 3200 宽必须由**两个 1600 半屏**（两个 CRTC/plane）拼出来。
#
#   安卓日志里的 `dsi_display_set_mode: hactive=3200` 是**整块面板**的
#   合成时序参数，不代表单个 CRTC 能吃 3200 宽 —— 我一度按后者理解，
#   把因果搞反了。
#
# 结论：分屏方向是对的，黑屏是**分屏改写的实现问题**（kwinwrap 把 KWin 的
# nobj=3 真提交改写成只剩 2 个对象，丢了 connector 与 CRTC 的
# MODE_ID/ACTIVE，内核判 EINVAL），不是"该不该分屏"的问题。
# 这个开关留着是为了将来换到真·对称单 CRTC 面板时能一键切回来。
DEV_KWINWRAP_NO_SPLIT=""                                 # ✔实测：必须为空

# ── 安卓稳定性开关（接管期间要解除武装）────────────────────
# ~推测：本机是 ColorOS 17。实测 `settings list global` 里看不到
# watchdog/nativehang 项，但 SF 停掉后 system_server 仍可能自杀，
# 所以保留写入（不存在的键写进去只是 not found，无害）。
DEV_WATCHDOG_DISARM="settings put global watchdog_timeout 86400000; settings put global stay_on_while_plugged_in 7"
DEV_WATCHDOG_REARM="settings delete global watchdog_timeout; settings delete global stay_on_while_plugged_in"

# ── 内核调试参数 ──────────────────────────────────────────
# 本机是 msm_drm（✔实测）。drm.debug 是通用项。
DEV_KERNEL_DEBUG_OFF="echo 0x0 > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0x0 > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"
DEV_KERNEL_DEBUG_ON="echo 0xffffffff > /sys/module/drm/parameters/debug 2>/dev/null; echo 0x3f > /sys/module/msm_drm/parameters/debugpolicy 2>/dev/null; echo 0xffffffff > /sys/module/msm_drm/parameters/debug_level 2>/dev/null"

# ── 桌面账号 ──────────────────────────────────────────────
# ✔实测：容器里是 Gold (uid 1000)。仍走运行时解析，这里只给 hint。
DEV_DESKTOP_USER_HINT=Gold

# ── 钩子：接管前的设备专属准备 ─────────────────────────────
# 需要"在 framework 还活着时"做的修复放这里（例如音量归零、蓝牙复位）。
dev_pre_stop_fixes() {
    :
}

# ── 钩子：会话起来之后的设备专属收尾 ───────────────────────
dev_post_session_fixes() {
    :
}

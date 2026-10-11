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
#     所以整块 3200 宽面板必须拆成多段分别驱动。
#
#   ⚠️ 一度据此推断"两个 1600 半屏"，**这是错的**。真正的形态由
#      conn67 的 topology_name 决定，本机实测 = 13 = sde_quadpipe_dscmerge
#      （IMMUTABLE，驱动按面板能力定）⇒ **四管 + DSC 合并**，
#      必须由 **4 个 Primary(VIG) 平面各 800 宽**驱动同一帧缓冲。
#      Android 侧实测（容器里 kmsdump 读，不需要 master）：
#        PLANE 131  CRTC_X=0    SRC_X=0
#        PLANE 127  CRTC_X=800  SRC_X=800
#        PLANE 123  CRTC_X=0    SRC_X=1600
#        PLANE 92   CRTC_X=800  SRC_X=2400
#      即双 DSI 每条链路 2 管、链路内目的坐标 0/800，源列是整幅图上的真实列。
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

# ── 分屏平面顺序（✔实测，照抄 Android）─────────────────────
# 运行时发现只能按 id 升序给出 Primary 平面（92,123,127,131），
# 但"哪个 VIG 管驱动哪一段"是硬件固定的。上面那条 Android 基线给出的
# 顺序是 131,127,123,92，对应源列 0/800/1600/2400。
# 顺序错了画面会错位/错配，所以在这里固化核对过的顺序。
# （kwinwrap 的几何规则：SRC_X = 下标*段宽，CRTC_X = (下标%2)*段宽）
DEV_KWINWRAP_SPLIT_PLANES="131,127"                      # ✔实测：2 平面 × 1600，唯一不 panic 的组合
# 目的坐标：1 = 链路内地址 (0,800,0,800)（Android 原样，但被 SDE 拒）；
# 0 = 全局单调 (0,1600)，与 SPLIT_PLANES 只有 2 个配合时正好覆盖整幅面板。
# ★ 为什么必须是"2 平面 + 单调"：
#   _sde_crtc_validate_src_split_order 会把同 stage 的平面**按 CRTC_X 排序后
#   配对相邻两个**，要求目的坐标严格递增（实测报错 stage:0 l:0-800 r:0-800）。
#   Android 的 0,800,0,800 因此被拒（我们试过，dmesg 里 90 条报错）。
#   而 4 平面 + 单调 0,800,1600,2400 虽然能过校验，却让内核在 ~20s 后
#   BUG() → Fatal exception → panic（目的 1600~3200 超出单条 DSI 链路的
#   本地地址范围）。2 平面 × 1600 是唯一同时满足两者的形式：实测
#   src_split_order 报错 0 条、CRTC mode_valid=1、不 panic。
DEV_KWINWRAP_SPLIT_DST_INTERLEAVE="0"                    # ✔实测：必须单调

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
    # ★ 抓一帧合成结果存档到 /data/local/tmp/fb.ppm（诊断用，失败不影响会话）。
    #
    # 为什么需要：接管后安卓显示栈已停，`screencap` 不可用，而"提交被内核
    # 接受"不等于"画面正确"。实测踩过两种光看日志区分不了的情况：
    #   · 4 个平面且目的坐标非单调时内核判 -22 ⇒ CRTC 根本没激活（黑屏）；
    #   · 2 个平面时提交全过、CRTC mode_valid=1，但屏幕只有左半有条纹噪声。
    # 有这一帧就能直接看 KWin 到底合成了什么，不用靠猜。
    #
    # 做法：容器里 /root 与安卓侧 <rootfs>/root 是**同一个目录**（见
    # container.sh 的 ds_shared_dir），所以帧写在容器 /root/fb.ppm，
    # 安卓侧直接从 <rootfs>/root/fb.ppm 拷走。
    _sd=$(ds_shared_dir 2>/dev/null) || return 0
    [ -x "$_sd/droid-drm-takeover/bin/fbdump" ] || return 0

    # 用第一个分屏平面当探针；它一定挂在 CRTC 上且有 fb。
    _probe=${DEV_SPLIT_PROBE_PLANE:-131}
    _fb=$(ds_exec "/root/droid-drm-takeover/bin/kmsdump /dev/dri/card0 2>&1 | grep -E '^PLANE $_probe ' | sed 's/.*fb=\([0-9]*\).*/\1/'" 2>/dev/null | tr -d '\r' | tail -1)
    case "$_fb" in
        ''|0|*[!0-9]*) drm_log "抓帧跳过：plane $_probe 没有 fb（CRTC 可能未激活）"; return 0 ;;
    esac

    rm -f "$_sd/fb.ppm"
    ds_exec "/root/droid-drm-takeover/bin/fbdump /dev/dri/card0 $_fb /root/fb.ppm" >/dev/null 2>&1
    if [ -f "$_sd/fb.ppm" ]; then
        cp "$_sd/fb.ppm" /data/local/tmp/fb.ppm 2>/dev/null && \
            chmod 644 /data/local/tmp/fb.ppm 2>/dev/null
        drm_log "已抓一帧合成结果：/data/local/tmp/fb.ppm（plane $_probe fb=$_fb）"
    else
        drm_log "抓帧失败：fbdump 没产出 $_sd/fb.ppm"
    fi
}

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
# ★★★ 2026-10-12 上机实测定标：只做纵向翻转，平移量用 Y 量程 32000 ★★★
#
# 触摸 IC 报的是**面板原生竖屏坐标系**，与我们的横屏扫描不一致：
#     ABS_MT_POSITION_X : min 0, max 20000    ← 2000px（短边）× 10
#     ABS_MT_POSITION_Y : min 0, max 32000    ← 3200px（长边）× 10
# 两者纵横比 20000:32000 = 0.625 与显示 2000:3200 = 0.625 相同，所以
# libinput 默认的"按 ABS 量程线性归一化再铺满输出"**方向是对的**，
# 只是纵轴反了 —— 不校准的话手指点上边、指针跑到下边，看起来就是"乱跳"。
#
# 实测方法：`getevent -lt /dev/input/event5` 抓原始落点，让用户按
# "视觉左上 → 右上 → 右下 → 左下"点四个角，归一化后得到 4 个簇：
#     A (u=0.120, v=0.960)   B (u=0.936, v=0.961)
#     C (u=0.111, v=0.066)   D (u=0.921, v=0.095)
# ⚠️ 这个四角簇测量的**排序结论不可靠**（用户反馈"我好像点多了几次碰到了
#    别的地方"）。最终结论由下面的**物理滑动实验**定死，不要再用这段推断。
#    原始数据（归一化）：
#       A (u=0.120, v=0.960)   B (u=0.936, v=0.961)
#       C (u=0.111, v=0.066)   D (u=0.921, v=0.095)
#
# ★ 决定性实验（用户手沿物理边缘滑动，2026-10-12）：
#   · 手指沿**物理上边缘**从左滑到右 ⇒ 反馈出现在**画面右边缘**
#   · 手指沿**物理左边缘**从上滑到下 ⇒ 反馈出现在**画面上边缘**、方向右→左
#   ⇒ 真实变换是**绕屏幕中心旋转 90°**：  n_x = v ,  n_y = 1 - u
#     （u = rawX/20000 跨 2000 px、v = rawY/32000 跨 3200 px，
#       两者都是 10 单位/px，旋转后仍是 1:1 等比。）
#   该变换已由端到端注入验证（6 个非对角点全部落屏内，越界日志 0 条）。
#
# ── 横向不用动（实测证明，别去"修"那个 2.25）────────────────────
# kwinoutputconfig.json 里本机 "scale": 2.25，模式 3200x2000
#   ⇒ KWin 的**逻辑尺寸 = 3200/2.25 x 2000/2.25 = 1422.2 x 888.9**
#   ⇒ KWin 日志里打印的坐标是逻辑坐标，不是物理像素。
# 用合成触摸注入实测（probe/touchinject.c，见下）：
#     x_kwin = 1422.0 * u      ← 正好 = 逻辑宽度 * u   ⇒ 横向完全正确
#     y_kwin = -888.9 * v      ← 纵轴反了，且平移量丢了
# 所以 3200/1422 = 2.25 不是 bug，是输出缩放。
#
# ── 校准矩阵：libinput 1.28.1 **只用 2×2，平移项被完全忽略** ──────────
# 这是本机最耗时的坑，结论由 4 组矩阵变体实测得出（6 值与 9 值都试过，
# 平移量放 val[5] / val[6] / val[7] 都试过，全部无效）：
#     "0 -1 0 1 0 0 ..."   ⇒ n = (v, -u)
#     "0  1 0 -1 0 ...  "  ⇒ n = (-v, u)      （上一条的转置）
# 交叉项完全生效、精确可复现，**唯独平移项一点效果都没有**。
# ⇒ 90° 旋转需要的那个 "+1" 在数学上必须靠平移
#   ⇒ **校准矩阵这条路在本机是死的**。
#   上游参考机一个矩阵就能搞定，是因为它跑 libinput ≥1.31。
#
# ── 修法：把那个 "+1" 挪进量程，就不用平移项了 ────────────────────
# libinput 的归一化是   U = (raw - min) / (max - min)
# 把 X 轴量程整体平移 +20000（报成 [20000, 40000]）就得到
#     U = (rawX - 20000) / 20000 = u - 1
# 于是只要一个**纯 2×2** 矩阵就能拿到目标变换：
#     "0 -1 0 1 0 0"   ⇒  n_x = V = v ,  n_y = -U = 1 - u
# 量程由 tools/runtime/touchabs.c 这个 LD_PRELOAD 垫片在 EVIOCGABS 上改写，
# 由 DEV_TOUCH_ABS_X_MIN / DEV_TOUCH_ABS_X_MAX 驱动。
#
# ★ 前提已验证：libinput **不会**把原始值 clamp 到 [min,max]。
#   判定实验：量程报成 [-20000, 0]（U = u+1 ∈ [1,2]，必定越界）+ 恒等矩阵，
#   KWin 日志里的 x 精确随注入点变为 -1422.2*(1+u)
#   （u=0.1/0.3/0.5/0.7/0.9 → 1564/1849/2133/2418/2702）⇒ **没被夹住**。
#
# 端到端验证：6 个非对角点（u≠v）注入后全部落在屏内，越界日志 0 条。
#
# ⚠️ 不要照抄参考机 OPD2413 的 "0 1 0 -1 0 1 0 0 1" —— 那是对调轴 + 平移 1，
#    本机套上去会变成"点左上角、指针去右下角"（实测 7 条越界日志）。
DEV_TOUCH_CALIB="0 -1 0 1 0 0"
# X 轴量程覆盖（touchabs.so 读它）。留空 = 不覆盖。
DEV_TOUCH_ABS_X_MIN="20000"
DEV_TOUCH_ABS_X_MAX="40000"


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
# （kwinwrap 的几何规则：SRC_X = 下标*段宽，CRTC_X = 由 DST_INTERLEAVE 决定）
#
# ★★ 2026-10-12 重测：改回 **4 平面**（Android 真实形态）★★
#   之前退回 2 平面是因为 4 平面被 SDE 判 -22，报：
#       [_sde_crtc_validate_src_split_order] invalid coordinates,
#           stage:0 l:0-800 r:0-800
#   当时的猜测写在 kwinwrap.c 里：**可能只是那 4 个非原子属性
#   （blend_op/alpha/zpos/rotation）还没设**（alpha=0 全透明）。
#   后来查明：zpos 被硬写成 0（旧 pprops[] 里 { "zpos", 0u }），
#   4 条平面 zpos 全同 ⇒ 全归到同一个 stage ⇒ 按 CRTC_X 排序得
#   0,0,800,800（当时的链路内坐标）⇒ 配成 (0,0)/(800,800) 全被拒。
#   （注：安卓 4 条 logo 平面 zpos 也确实全是 0、也确实同 stage —— 它之所以
#    不报错，是因为安卓的 CRTC_X 是整屏全局坐标，减完 1600 后同一 stage 内
#    按 layout 分成 LEFT{0,800} 与 RIGHT{0,800} 两组，各自都是"左<右"。
#    我们当时用的是链路内坐标，同一 stage 内全挤在一组，才配错。）
#
#   ★★ 2026-10-12 二次修正：目的坐标**必须**是整屏全局的单调 0,800,1600,2400 ★★
#   拿到厂商驱动源码（SM8650/pineapple 的 qcom/opensource/display-drivers，
#   日志行号 _sde_crtc_check_plane_layout:6221 与设备完全对上）后真相大白：
#
#     static int _sde_crtc_check_plane_layout(crtc, crtc_state)   /* sde_crtc.c */
#     {
#         if (!sde_rm_topology_is_group(rm, crtc_state, QUADPIPE))
#             return 0;
#         sde_crtc_get_resolution(crtc, crtc_state, mode, &crtc_width, ...);
#                                 /* = mode->hdisplay = 3200（整块面板） */
#         layout_split = crtc_width >> 1;                  /* 1600 */
#         if (plane_state->crtc_x >= layout_split) {       /* ★ 入口是全局坐标 */
#             plane_state->crtc_x -= layout_split;         /* 驱动自己减 1600 */
#             pstate->layout_offset = layout_split;
#             pstate->layout = SDE_LAYOUT_RIGHT;
#         } else {
#             pstate->layout_offset = -1;
#             pstate->layout = SDE_LAYOUT_LEFT;
#         }
#         if (CHECK_LAYER_BOUNDS(plane_state->crtc_x, plane_state->crtc_w,
#                                 layout_split))     /* 减完必须落在 0~1600 内 */
#             return -E2BIG;
#     }
#
#   而 _sde_crtc_blend_setup_mixer() 用 layout 选 LM 组：
#         if (pstate->layout <= SDE_LAYOUT_LEFT) layout_idx = 0;  /* LM0/LM1 */
#         else                                   layout_idx = 1;  /* LM2/LM3 */
#   sde_plane.h 里 enum sde_layout 的注释也直说：
#         SDE_LAYOUT_LEFT : SSPPs will be staged on left  two LMs
#         SDE_LAYOUT_RIGHT: SSPPs will be staged on right two LMs
#   最后 _sde_crtc_blend_setup() 按 lm_layout = mixer_idx / MAX_MIXERS_PER_LAYOUT
#   把 stage_cfg[0] 发给 LM0/LM1、stage_cfg[1] 发给 LM2/LM3。
#
#   ⇒ **提交时必须给整屏全局坐标**。给链路内的 (0,800,0,800) 会让 4 条平面
#     全部 < 1600 ⇒ 全部 SDE_LAYOUT_LEFT ⇒ 全部塞进 LM0/LM1 ⇒ 只有 DSI0
#     有图层，LM2/LM3（右半屏）永远拿不到图层 ⇒ **右半屏全黑**。
#     这正是用户报的症状："位置对了，但右半屏不亮"。
#
#   ⇒ 之前记的"1600~3200 超出单链路本地地址范围、会 panic"是**误判**：
#     kmsdump 读到的 0/800/0/800 是驱动**减完之后**的值（get 拿的是
#     plane_state->crtc_x），拿它当"安卓提交的原样"反推，因果搞反了。
#     驱动自己的 evtlog 也证明安卓提交的是全局坐标：安卓 4 条 logo 平面在
#     _sde_crtc_blend_setup_mixer 里 layout_idx = 1,1,0,0（按 src 段 3,2 → RIGHT）。
#
#   校验侧也自洽（4 平面 + 全局坐标 + zpos 模式 5）：
#     _sde_crtc_check_plane_layout 减完：131→0(L) 127→800(L) 123→0(R) 92→800(R)
#     _sde_crtc_validate_src_split_order：只有"同 stage 且同 layout"的相邻平面
#       才配对。模式 5 下 4 条平面各自独占 stage ⇒ 一对都不配 ⇒ 直接通过。
#     _sde_crtc_check_zpos：每个 (stage,layout) 只有 1 条平面，远低于上限 2。
DEV_KWINWRAP_SPLIT_PLANES="131,127,123,92"               # Android 实测形态：4 个 Primary(VIG)，各 800 宽
DEV_KWINWRAP_SPLIT_DST_INTERLEAVE="0"                    # ✔整屏全局单调 0,800,1600,2400（驱动靠它判 LEFT/RIGHT）
# zpos 分组（见 kwinwrap.c 的 SPLIT_ZPOS_MODE）：
#   5 = ★★ 当前采用：zv = 3-s ⇒ {131,127,123,92} → 3,2,1,0（4 条各占一个 stage）
#   2 = 每段独占一个 stage，但**升序**（zv=s ⇒ 0,1,2,3）—— 与模式 5 只差先后
#   1 = 每 2 段一个 zpos（s/2）⇒ {131,127}→0、{123,92}→1（4 条挤进 2 个 stage）
#   3 = 全部 0 ⇒ 与安卓 logo 图层完全同形（每 layout 2 条同 stage，会触发
#       SDE 的 source-split 配对）
#   4 = 反转配对
#
# ★★ 2026-10-12 更正：安卓 4 条 logo 平面的 stage 全是 1，之前读错了 ★★
#   debug/dump 里 _sde_crtc_blend_setup_mixer 第二条 EVT32 的字段是：
#       crtc, plane, stage_idx, sspp, stage, multirect_index,
#       multirect_mode, format, modifier, layout_idx        （对应 sde_crtc.c:1977）
#   安卓四条 logo 平面解出来是：
#       plane 92  sspp=VIG0 stage=1 stage_idx=0 layout=1
#       plane 123 sspp=VIG1 stage=1 stage_idx=1 layout=1
#       plane 127 sspp=VIG2 stage=1 stage_idx=0 layout=0
#       plane 131 sspp=VIG3 stage=1 stage_idx=1 layout=0
#   ⇒ **stage 全是 1**（raw zpos 全是 0，stage = zpos + SDE_STAGE_0），
#     之前当成"每平面独占一个 stage、按下标降序"的那组 0/1/2/3 其实是
#     **stage_idx**，不是 stage。stage_idx 只是"同一 stage 内的第几条"，
#     由 zpos_cnt[layout][stage]++ 按 plane id 升序发号。
#
#   几何也一样：kmsdump 读到的 (0,800,0,800) 是驱动减完 1600 的**链路内**值，
#   安卓实际提交的是整屏全局 (0,800,1600,2400)，减完正好是 (0,800,0,800)，
#   而 layout 由"减之前"的全局值决定 ⇒ 131,127 → LEFT、123,92 → RIGHT。
#   ⇒ 与我们的 (SRC_X=段下标*800, dst=段下标*800) 一一对应，映射完全一致。
#
#   ★ 为什么仍用模式 5 而不是模式 3：
#     模式 5 下 4 条平面各自独占 stage ⇒ _sde_crtc_validate_src_split_order
#     里没有任何"同 stage 同 layout"的相邻对 ⇒ 不做 source-split 配对，
#     每条 SSPP 都是单 LM 取数。这与当前**已经证明能正确出左半屏**的形态
#     只差 dst 一个变量，改动面最小。
#     模式 3 会额外触发 source-split 配对（131↔127、123↔92 各自成对），
#     是安卓的同形配置，留作模式 5 不成时的下一步对照实验。
#     两者都满足 _sde_crtc_check_zpos 的"每 (stage,layout) ≤ 2 条"上限。
DEV_KWINWRAP_SPLIT_ZPOS="5"                              # ✔4 条各占一个 stage，不做 src-split 配对
# ★★★ 2026-10-12 真正阻塞点（已修，见 kwinwrap.c 里 CONN-ADD 那段）★★★
#   上面几何/坐标/zpos 全部正确，但右半屏还是不出画面。kmsdump 实测：
#       plane 92  CRTC_X=2400  SRC_X=2400<<16      ← 提交什么就读回什么
#       plane 123 CRTC_X=1600  SRC_X=1600<<16         驱动**没有**减 1600
#       plane 127 CRTC_X=800   SRC_X=800<<16      ⇒ _sde_crtc_check_plane_layout
#       plane 131 CRTC_X=0     SRC_X=0                **整段没执行**
#   原因：该函数第一句是
#       if (!sde_rm_topology_is_group(&kms->rm, crtc_state, QUADPIPE)) return 0;
#   而它靠**遍历 crtc_state 上的 connector** 取拓扑；KWin 的增量页翻转提交
#   只有 plane+CRTC、不带 connector ⇒ crtc_state->connector_mask=0 ⇒
#   num_connectors=0 ⇒ 拓扑判 false ⇒ 布局检查不执行 ⇒ pstate->layout 恒为
#   LEFT ⇒ 4 条平面全进 stage_cfg[0]（LM0/LM1），LM2/LM3 空转。
#   evtlog 旁证：安卓 sde_encoder_virt_atomic_check 出现 82 次，我们 0 次。
#   修法：kwinwrap 在提交里补 connector（只写 CRTC_ID，不能写 DPMS —— 本内核
#   DPMS 没有 DRM_MODE_PROP_ATOMIC，塞原子提交会被判 EINVAL）。
#
#   验证：修好后 kmsdump 读回 plane 123/92 的 CRTC_X 应变成 0/800（链路内），
#   evtlog 的 layout_idx 应变成 131,127→0 与 123,92→1，underrun 归零。
#
# ★ 逐帧调试痕迹（BUILT/FBSCAN/DROP-CAND/CONN-ADD/CONN-CRTC）。
#   默认关（每帧都打会把 kwinatomic.log 撑爆）。
#   2026-10-12：右半屏黑已定位并修好（见上面 CONN-ADD 那段），验证通过
#   ⇒ **恢复默认关闭**。下次查布局问题时再临时开成 "1"。
DEV_KWINWRAP_TRACE=""

# 给 kwin 进程注入的环境变量（空格分隔）。空 = 不注入。
#
# ★★ 必须是 msm —— 不是 freedreno，更不是 kgsl ★★
#
# 这个值**必须是 dri 目录里真实存在的模块名**。本容器实测：
#     ls /usr/lib/aarch64-linux-gnu/dri/  →  msm_dri.so  kgsl_dri.so
#                                            zink_dri.so swrast_dri.so
#   **没有 freedreno_dri.so** —— 曾经这里写的 `freedreno` 是个无效名字，
#   Mesa 找不到就**静默掉到 zink**（GL-over-Vulkan），而 zink 有额外开销，
#   桌面肉眼可见地卡。用户对照证据：系统设置里"图形处理器"以前直接显示
#   高通具体型号，改成 freedreno 后变成了 "zink vulkan 1.4"。
#
# 用 eglinfo 做的严格对照（同机同会话）：
#     MESA_LOADER_DRIVER_OVERRIDE=kgsl      → vendor freedreno / renderer FD750
#                                             但刷 "MESA-LOADER: failed to
#                                             retrieve device information"
#     MESA_LOADER_DRIVER_OVERRIDE=msm       → vendor freedreno / renderer FD750
#                                             **零错误** ← 选它
#     MESA_LOADER_DRIVER_OVERRIDE=freedreno → zink Vulkan 1.4(Turnip Adreno 750)
#     MESA_LOADER_DRIVER_OVERRIDE=zink      → 同上
#
# 为什么不用 kgsl：kgsl 那条 winsys 在本容器里写出来的 buffer 布局与 DRM fb
#   声明的线性布局不一致（fbdump 只有约 1% 字节非零）⇒ 密集彩色竖条纹噪声。
#   msm 走的是 DRM 分配器，buffer 布局天然与 fb 一致。
#   ★ 这条**与位深无关**：kgsl 在 8 位和 10 位下都是垃圾。
#
# 注意 display.sh 里 KWin 的 env 是先 `-u` 掉再显式赋值的，
# 这里注入的值排在其后，所以能覆盖掉硬编码的 kgsl。
#
# ★ 曾经这里还带一个 `KWIN_DRM_PREFER_COLOR_DEPTH=8` —— **已删除**。
#   它被证明无效：读 KWin 6.3 源码（drm_output.cpp:379-382）可见它只写
#   连接器 max bpc 属性（preferred/3），**不改缓冲格式**。
#   本机"面板彩色条纹"的根因**不是**位深（那是个误判，见下），
#   而是 plasmashell 的硬件 GL 渲染 —— 修法见 DEV_QT_QUICK_BACKEND。
#
# 写成 ${VAR-默认} 而不是硬赋值：这样 `DEV_KWIN_ENV=... sh switch.sh enter`
# 能临时覆盖（含覆盖成空串），做驱动对照实验时不用改文件重打包。
# 注意用 `-` 不是 `:-` —— 后者会把"显式设为空"也当成未设置。
#
# ★ 2026-10-12 追加 touchabs.so：触摸方向的量程垫片（见上面触摸那段）。
#   它必须进 **KWin 的**进程环境 —— libinput 是在 KWin 里读设备的。
#   ⚠️ 这里的 LD_PRELOAD 会**覆盖** display.sh 里 _fmt_preload 那一份，
#   所以必须把 drmfmt.so 一并写上，否则格式垫片就丢了。
#   两个 .so 都在 /usr/local/lib/droid-drm-takeover/。
DEV_KWIN_ENV="${DEV_KWIN_ENV-MESA_LOADER_DRIVER_OVERRIDE=msm LD_PRELOAD=/usr/local/lib/droid-drm-takeover/drmfmt.so:/usr/local/lib/droid-drm-takeover/touchabs.so TOUCHABS_X_MIN=$DEV_TOUCH_ABS_X_MIN TOUCHABS_X_MAX=$DEV_TOUCH_ABS_X_MAX}"

# plasmashell 的 Qt Quick 后端。
#
# ★★ 2026-10-12 结论翻转：原来的"必须 software"是**误判** ★★
#   当年那次对照实验自称"只改这一个变量"，但**漏了一个未受控变量**：
#   设备层只给 **KWin** 注入了 freedreno，plasmashell 一直继承容器全局的
#   **kgsl**。所以当年那两组其实是：
#       留空（硬件 GL）+ kgsl   → 满屏垂直彩色条纹（248564 色，非黑 15.4%）
#       software        + kgsl  → 完整桌面（100241 色）
#   而本文件上面那段自己就写明：**kgsl 在 8 位和 10 位下输出都是垃圾**
#   （fbdump 只有约 1% 字节非零，tiling/UBWC 与线性 fb 声明不一致）。
#   ⇒ **条纹是 kgsl 造成的，不是硬件 GL 造成的。**
#   现在 DEV_PLASMA_ENV 把 freedreno 也注给 plasmashell，硬件 GL 才第一次
#   被真正测过。
#
# ⚠️ 面板/启动器/部件全在 plasmashell 里。它走软件渲染时，在
#   3200x2000、scale 2.25 下**明显卡顿**（用户实测反馈"变得特卡"）。
#   而且 KWin 的合成是硬件 GL —— 只让 shell 软渲染是纯粹的净损失。
#
# 留空 = 不注入（Qt 默认硬件 GL）。若将来又出现条纹，再改回 software 对照。
DEV_QT_QUICK_BACKEND="${DEV_QT_QUICK_BACKEND-}"

# 给 plasmashell 注入的环境变量（空格分隔）。空 = 不注入。
#
# ★★ 必须和 KWin 用同一个 Mesa 驱动名：msm ★★
#   容器全局（/etc/environment）把它设成了 kgsl —— 那条 winsys 在本机写出来的
#   buffer 布局与 DRM fb 声明的线性布局不一致 ⇒ 彩色条纹噪声。
#   而写成 `freedreno` 是个**无效模块名**（dri 目录里只有 msm_dri.so /
#   kgsl_dri.so），Mesa 会静默掉到 zink（GL-over-Vulkan），桌面明显变卡。
#   详见上面 DEV_KWIN_ENV 那段里的 eglinfo 对照表。
#   ★ 2026-10-12 追加：**不要再设 FD_MESA_DEBUG=noubwc**。
#   它关掉 UBWC 带宽压缩，是 kgsl 时代为了让 buffer 布局对上而加的。
#   现在走 msm（DRM 分配器），UBWC 本来就正确 ⇒ 关压缩变成纯粹的带宽负担。
#   在 3200x2000@144Hz 上这足以造成"整个 KDE 掉帧"。
DEV_PLASMA_ENV="${DEV_PLASMA_ENV-MESA_LOADER_DRIVER_OVERRIDE=msm}"

# LD_PRELOAD shim 路径（tools/runtime/drmfmt.c）。留空 = 用默认
#   /usr/local/lib/droid-drm-takeover/drmfmt.so（deploy-all.sh 装到那儿）。
# ★ 别指到 payload 的 bin/ 下：容器里 /root 是 700，而 kwin 以桌面账号
#   （uid 1000）运行，读不到 /root 下的 .so ⇒ ld.so 静默忽略 LD_PRELOAD。
# 只有把 payload 装在 /root 之外、或改过 /root 权限时，才需要在这里覆盖。
DEV_DRMFMT_SO="${DEV_DRMFMT_SO-}"

# ── 限制 KWin 能看到的刷新率（交给 drmfmt.so 过滤）──────────────────
# 本机面板（connector 67）暴露 4 个 3200x2000 模式：
#     [0] ★PREFERRED 120vid  htotal=3524  clock=955708
#     [1]            144vid  htotal=3328  clock=1083064
#     [2]             90vid  htotal=3916  clock=796514
#     [3]             60vid  htotal=3524  clock=955708
# 120vid 带 DRM_MODE_TYPE_PREFERRED ⇒ **KWin 必然选它**。
#
# ★ 但实测（tools/probe/modelist + kmsdump）：接管后 CRTC 200 上真正生效的
#   是 **144vid**（clock=1083064，htotal=3328），行时序与 120vid 完全不同。
#   面板收到的行频/像素时钟与它预期不符 ⇒ 满屏彩色噪声。
#   （实测记录：CRTC 200 mode_valid=1 mode=3200x2000x144vid）
#
# 所以这里把候选模式收窄到 144，逼 KWin 去选和 CRTC 一致的那个。
# 留空 = 不限制（回到 KWin 自己按 preferred 选，用于对照实验）。
DEV_DRM_MODE_KEEP_HZ="${DEV_DRM_MODE_KEEP_HZ-144}"

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

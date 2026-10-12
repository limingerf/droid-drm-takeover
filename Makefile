# droid-drm-takeover — 交叉编译入口
#
# ══ 目录约定（重构后）══
#   tools/runtime/   真正要上设备、被脚本硬依赖的工具
#   tools/probe/     设备适配期的一次性探针（换设备时用，平时不参与流程）
#   tools/protocol/  wayland-scanner 生成的协议桩（随仓库分发，免 scanner）
#
# ══ 目标 ══
#   make            全部产物 → bin/
#   make runtime    只编 runtime（真正需要随 APK/容器分发的那几个）
#   make clean
#
# ══ 交叉编译 ══
#   本 Makefile **不硬编码** aarch64 工具链，靠 CC= 传入。
#   ⚠️ PKG_CFLAGS/DRM_LIBS/WL_LIBS 用的是 $(shell pkg-config ...)，
#      make 在**解析期**就求值了，所以交叉编译必须走环境变量：
#
#        export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
#        make -j"$(nproc)" CC=aarch64-linux-gnu-gcc
#
#      用 `make PKG_CFLAGS=...` 是**无效**的（已经求值过了）。
#      CI 见 .github/workflows/build.yml。
#
# ══ 为什么目标只有 aarch64 ══
#   touchdraw.c 含 ARM64 内联汇编（dc civac / dsb sy 做缓存维护），
#   x86 原生全量构建没有意义（编得过，上设备 SIGILL）。

CC      ?= gcc
CFLAGS  += -O2 -g -Wall -Wno-unused-parameter
PKG_CFLAGS := $(shell pkg-config --cflags libdrm wayland-client 2>/dev/null)
DRM_LIBS := $(shell pkg-config --libs libdrm)
WL_LIBS  := $(shell pkg-config --libs wayland-client)

SRC_RUNTIME  := tools/runtime
SRC_PROBE    := tools/probe
SRC_PROTOCOL := tools/protocol
# 输出目录：用 ?= 以便命令行覆盖。
#   make BIN=/tmp/b BLD=/tmp/o runtime
# 这很有用 —— 比如 CI 里单独验证 runtime 子集时，不能把完整的 bin/ 覆盖掉
# （早期版本就是 `make clean && make runtime` 直接跑在 bin/ 上，结果上传给
#   APK job 的 artifact 里只剩 6 个 runtime 工具）。
BIN ?= bin
BLD ?= build

# ── runtime：脚本硬依赖，缺一个流程就跑不起来 ──
#   kwinwrap    DRM 交接桥（全项目心脏）
#   setbright   背光（5 个脚本共 8 处调用，没有 fallback）
#   setprop     connector 属性写（DPMS 点亮）
#   drmbl       ★ 真正的熄面板（写 DRM connector 的 brightness）。
#               为什么必须有它：本机 sysfs /sys/class/backlight 是**死的**
#               （内核 dmesg: `bypass bl 0`，写 brightness=0/bl_power=4 都无效），
#               唯一生效的是 DRM connector 属性；而那个属性没有 ATOMIC 位、
#               又要求 master 权限，从外面写一律 EACCES。
#               drmbl 用 pidfd_getfd(2) 从 KWin 那里偷一份 master fd 出来解决权限。
#               ★ 它**只写 brightness，不碰 DPMS** —— DPMS 归 KWin 管，从旁边改
#                 会让 KWin 原子提交全部 EINVAL（双 DSI 面板会左半屏不亮）。
#               详见 tools/runtime/drmbl.c 顶部注释。
#   crtcstate   取证
#   connprops   取证
#   atomicspy.so LD_PRELOAD 钩子，录每次 atomic commit
#   drmfmt.so   LD_PRELOAD 钩子，摘掉 10 位像素格式（面板噪声修复，见下）
#   touchabs.so LD_PRELOAD 钩子，改写触摸位置轴的 EVIOCGABS 量程
#               （触摸方向修复，见下 —— 与 drmfmt.so 一起进 KWin 的 LD_PRELOAD）
RUNTIME_TOOLS := kwinwrap setbright setprop drmbl crtcstate connprops
RUNTIME_LIBS  := $(BIN)/atomicspy.so $(BIN)/drmfmt.so $(BIN)/touchabs.so

# ── probe：设备适配期用，不参与日常流程 ──
#   前三个是**设备无关**的（运行时发现 conn/crtc/mode/plane），换设备先跑它们。
PROBE_DYNAMIC := kmsdump kmsmatrix atomiccheck fbinfo dscset kmspaint modelist moderead conntest frameseq kmsmode blobdump
#   其余默认对着 piano 的 ID（crtc 206 / conn 67 / plane 157,161），
#   在别的设备上结果无意义，只在 DIAG_LEGACY_PROBES=1 时被调用。
PROBE_LEGACY  := drmatomic planecrtc informats masterprobe rawprobe kwinprobe \
                 atombisect stageprobe replicate atomic-spy
PROBE_TOOLS   := $(PROBE_DYNAMIC) $(PROBE_LEGACY)
UDEV_TOOLS    := udevprobe udevmatch
# 触摸验证客户端。注意 touchdraw 是**纯 libdrm**（审计报告说它需要
# wayland-client 是错的，已核对其 include 与 wl_ 符号）。
TOUCH_DRM_TOOLS := touchdraw
WAYLAND_TOOLS   := touchtest touchinj

PROT_OBJS := $(BLD)/xdg-shell-protocol.o $(BLD)/fake-input-protocol.o

ALL_TOOLS := $(RUNTIME_TOOLS) $(PROBE_TOOLS) $(UDEV_TOOLS) $(TOUCH_DRM_TOOLS) $(WAYLAND_TOOLS)

all: $(addprefix $(BIN)/,$(ALL_TOOLS)) $(RUNTIME_LIBS)

runtime: $(addprefix $(BIN)/,$(RUNTIME_TOOLS)) $(RUNTIME_LIBS)

$(BIN) $(BLD):
	mkdir -p $@

# ── 协议桩 ──
$(BLD)/%.o: $(SRC_PROTOCOL)/%.c | $(BLD)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -fPIC -c $< -o $@

# ── runtime（libdrm）──
$(addprefix $(BIN)/,$(RUNTIME_TOOLS)): $(BIN)/%: $(SRC_RUNTIME)/%.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< -o $@ $(DRM_LIBS)

# ── probe（libdrm）──
$(addprefix $(BIN)/,$(PROBE_TOOLS)): $(BIN)/%: $(SRC_PROBE)/%.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< -o $@ $(DRM_LIBS)

# ── 触摸裸绘（libdrm + ARM64 内联汇编）──
$(addprefix $(BIN)/,$(TOUCH_DRM_TOOLS)): $(BIN)/%: $(SRC_PROBE)/%.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< -o $@ $(DRM_LIBS)

# ── udev ──
$(addprefix $(BIN)/,$(UDEV_TOOLS)): $(BIN)/%: $(SRC_PROBE)/%.c | $(BIN)
	$(CC) $(CFLAGS) $< -o $@ -ludev

# ── wayland 客户端 ──
# -I$(SRC_PROTOCOL)：协议桩头文件在 tools/protocol/（重构前和源码混在 src/，
# 所以原来不需要 -I）。
# $(DRM_LIBS)：touchinj 现在还会从 DRM 读面板尺寸（原来写死 3200x2136），
# 所以同时要链 libdrm。touchtest 不需要，多链一个库无害。
$(addprefix $(BIN)/,$(WAYLAND_TOOLS)): $(BIN)/%: $(SRC_PROBE)/%.c $(PROT_OBJS) | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -I$(SRC_PROTOCOL) $< $(PROT_OBJS) -o $@ $(WL_LIBS) $(DRM_LIBS)

# ── LD_PRELOAD 钩子 ──
# ★ 修掉重构前的源文件错配：旧 Makefile 用 src/atomic-spy.c（ptrace 版）
#   去生成 atomicspy.so，而真正的 LD_PRELOAD 版 src/atomicspy.c 从未被编译。
#   结果 docs/tools.md 教用户 `LD_PRELOAD=bin/atomicspy.so`，加载的是一个
#   带 main() 的 ptrace 程序 —— 完全不是那个意思。
$(BIN)/atomicspy.so: $(SRC_RUNTIME)/atomicspy.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -shared -fPIC $< -o $@ $(DRM_LIBS) -ldl

# ★ drmfmt.so —— 面板密集彩色条纹噪声的修复。
#   根因：KWin 的 filterAndSortFormats() 在 AR24 与 AR30（同为 32bpp）
#   平手时按 bitsPerColor 选大的，**必然**选 10 位；而本设备 10 位渲染
#   产出的缓冲就是垃圾。没有任何 KWin 配置项能改掉这个偏好，所以只能
#   在能力列表这一层把 10 位格式摘掉。
#
#   注意它拦的是 drmModeGetPropertyBlob（IN_FORMATS blob），**不是**
#   drmModeGetPlane —— KWin 的 DrmPlane::updateProperties() 在
#   addFB2ModifiersSupported() 为真时只读 blob，p->formats 被完全忽略。
#   本设备实测 DRM_CAP_ADDFB2_MODIFIERS=1 ⇒ 必须拦 blob。
#   详见 tools/runtime/drmfmt.c 顶部注释。
$(BIN)/drmfmt.so: $(SRC_RUNTIME)/drmfmt.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -shared -fPIC $< -o $@ $(DRM_LIBS) -ldl

# ★ touchabs.so —— 触摸方向修复（绕屏幕中心 90° 旋转）。
#   本机触摸屏的坐标系与显示差一个旋转：需要 n_x = v, n_y = 1 - u。
#   正路是 LIBINPUT_CALIBRATION_MATRIX，但实测本容器 libinput 1.28.1
#   **只用矩阵的 2×2 部分，平移项被完全忽略**（4 组变体、6/9 值都试过），
#   而 90° 旋转的 "+1" 恰恰必须靠平移 ⇒ 校准矩阵在数学上表达不了它。
#   （上游参考机能用一个矩阵搞定，是因为它跑 libinput ≥1.31。）
#
#   修法：libinput 归一化是 U = (raw - min) / (max - min)。把 X 轴量程
#   报成 [20000, 40000] 就有 U = u - 1，于是**纯 2×2** 矩阵
#   "0 -1 0 1 0 0" 就给出 n = (v, 1-u)。量程由本垫片在 EVIOCGABS 上改写，
#   值来自设备层的 DEV_TOUCH_ABS_X_MIN / _MAX。
#   已验证 libinput **不会**把原始值 clamp 到 [min,max]（把量程报成
#   [-20000,0] 时日志坐标精确随注入点变化）。
#   详见 tools/runtime/touchabs.c 顶部注释与 core/device/opd2511.sh。
$(BIN)/touchabs.so: $(SRC_RUNTIME)/touchabs.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -shared -fPIC $< -o $@ -ldl

clean:
	rm -rf $(BLD)
	rm -f $(addprefix $(BIN)/,$(ALL_TOOLS)) $(RUNTIME_LIBS)

.PHONY: all runtime clean

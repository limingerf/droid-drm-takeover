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
BIN := bin
BLD := build

# ── runtime：脚本硬依赖，缺一个流程就跑不起来 ──
#   kwinwrap    DRM 交接桥（全项目心脏）
#   setbright   背光（5 个脚本共 8 处调用，没有 fallback）
#   setprop     connector 属性写（DPMS 点亮）
#   crtcstate   取证
#   connprops   取证
#   atomicspy.so LD_PRELOAD 钩子，录每次 atomic commit
RUNTIME_TOOLS := kwinwrap setbright setprop crtcstate connprops
RUNTIME_LIBS  := $(BIN)/atomicspy.so

# ── probe：设备适配期用，不参与日常流程 ──
#   前三个是**设备无关**的（运行时发现 conn/crtc/mode/plane），换设备先跑它们。
PROBE_DYNAMIC := kmsdump kmsmatrix atomiccheck
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

clean:
	rm -rf $(BLD)
	rm -f $(addprefix $(BIN)/,$(ALL_TOOLS)) $(RUNTIME_LIBS)

.PHONY: all runtime clean

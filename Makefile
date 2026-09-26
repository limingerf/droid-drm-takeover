CC      ?= gcc
CFLAGS  += -O2 -g -Wall -Wno-unused-parameter
PKG_CFLAGS := $(shell pkg-config --cflags libdrm wayland-client 2>/dev/null)
DRM_LIBS := $(shell pkg-config --libs libdrm)
WL_LIBS  := $(shell pkg-config --libs wayland-client)

SRC := src
BIN := bin
BLD := build

# 纯 DRM/ioctl 工具
DRM_TOOLS := kwinwrap drmatomic touchdraw setprop setbright connprops crtcstate \
             informats masterprobe planecrtc rawprobe kmsdump kwinprobe atombisect \
             stageprobe replicate kmsmatrix atomiccheck
UDEV_TOOLS := udevprobe udevmatch
# 需要 wayland-client + 随仓库分发的协议桩(免 wayland-scanner)
WAYLAND_TOOLS := touchtest touchinj

PROT_OBJS := $(BLD)/xdg-shell-protocol.o $(BLD)/fake-input-protocol.o

all: $(addprefix $(BIN)/,$(DRM_TOOLS)) $(addprefix $(BIN)/,$(UDEV_TOOLS)) \
     $(addprefix $(BIN)/,$(WAYLAND_TOOLS)) $(BIN)/atomicspy.so

$(BIN) $(BLD):
	mkdir -p $@

$(BLD)/%.o: $(SRC)/%.c | $(BLD)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -fPIC -c $< -o $@

$(BIN)/%: $(SRC)/%.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< -o $@ $(DRM_LIBS)

$(BIN)/udevprobe $(BIN)/udevmatch: $(BIN)/%: $(SRC)/%.c | $(BIN)
	$(CC) $(CFLAGS) $< -o $@ -ludev

$(addprefix $(BIN)/,$(WAYLAND_TOOLS)): $(BIN)/%: $(SRC)/%.c $(PROT_OBJS) | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< $(PROT_OBJS) -o $@ $(WL_LIBS)

$(BIN)/atomicspy.so: $(SRC)/atomic-spy.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -shared -fPIC $< -o $@ $(DRM_LIBS) -ldl

clean:
	rm -rf $(BLD)
	rm -f $(addprefix $(BIN)/,$(DRM_TOOLS) $(UDEV_TOOLS) $(WAYLAND_TOOLS)) $(BIN)/atomicspy.so

.PHONY: all clean

#!/bin/sh
# ============================================================================
# audio/ct-snd-nodes.sh —— 在容器里补出 /dev/snd/* 设备节点（容器侧，需 root）
#
# 用法：
#   sh ct-snd-nodes.sh          # 建节点 + 自检
#   sh ct-snd-nodes.sh --check  # 只报告，不建
#
# ============================================================================
# ★ 为什么需要这个脚本（根因，2026-10-12 实测确认）
# ============================================================================
# 症状：容器里 `aplay -l` 报 "no soundcards found"，`/dev/snd/` 里**只有一个 timer**，
#       而 `cat /proc/asound/cards` 明明能看到 card0 `pineapplemtpsnd`。
#       ⇒ 驱动、/sys、/proc/asound 全都在，**缺的只是设备节点**。
#
# 根因：**devtmpfs 在开机时从未被挂载过**，所以内核从来没往里面建过任何节点。
#   · Linux 的节点自动创建走 `drivers/base/devtmpfs.c: devtmpfs_create_node()`，
#     而它的**第一句就是**：
#         if (!devtmpfs_mount) return 0;
#     `devtmpfs_mount` 只有在**有人 mount devtmpfs 时**才被置位。
#   · 安卓不用 devtmpfs：它把 **tmpfs** 挂在 /dev，再由 ueventd 按 ueventd.rc 建节点。
#     实测：`grep ' /dev ' /proc/self/mountinfo` → `tmpfs tmpfs`（安卓侧）
#     ⇒ 整个开机过程里 devtmpfs_mount == 0 ⇒ **一个节点都没建**（连 /dev/null 都没有）。
#   · 容器起来时 droidspaces 把 **devtmpfs 新挂到 /dev**（实测 mountinfo:
#     `0:5 / /dev ... - devtmpfs devtmpfs`）。devtmpfs 是**全局单例**，
#     但里面**只有"挂载之后才被创建"的那些节点** ⇒ 所以容器 /dev 里
#     /dev/dri、/dev/input、/dev/binder 这些都在（它们后来被 device_add 过），
#     唯独 snd 的 pcm/control 节点**永远补不上**（snd 卡在开机早期就注册完了）。
#   · 佐证：droidspaces 二进制的 /dev 白名单里**根本没有 /dev/snd**
#     （`strings droidspaces | grep '^/dev'` 无 snd）⇒ 它不负责这件事。
#
# ⇒ **正解就是在容器里 mknod**。节点号**不要硬编码**：从 /proc/asound/devices 读，
#   它每行的第一列就是该节点在 snd 主设备号（116）上的 minor。
#   （本机特例：controlC0 的 minor 是 **56**，不是教科书上的 0 ⇒ 更说明不能写死。）
#
# ⚠️ 这个脚本**不是** bind_mounts、不碰 /data/a2lrootfs、不重启任何东西。
#    mknod 只是往 devtmpfs 里加 inode，**删掉即还原**（rm /dev/snd/pcmC0D* 等）。
#
# ⚠️⚠️ **建出节点 ≠ 能出声**。见 audio/README.md：
#    本机是 AudioReach（SM8650Q/pineapple）平台，FE PCM 的**后端图只能由安卓侧建**，
#    容器里对任何一个 FE PCM `write()` 都返回 **EINVAL**（10 个设备实测全失败）。
#    本脚本解决的是"ALSA 工具连声卡都看不到"这一层，是**必要但不充分**条件。
# ============================================================================
set -u

SND_MAJOR=116          # ALSA 的字符设备主号（内核固定）
DEVICES=/proc/asound/devices
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

[ -r "$DEVICES" ] || die "$DEVICES 不可读 —— 容器看不到 ALSA 子系统？"

# ---------------------------------------------------------------------------
# 1) 解析 /proc/asound/devices
#    行形如：
#        2: [ 0- 0]: digital audio playback      → /dev/snd/pcmC0D0p   (116,2)
#       56: [ 0]   : control                     → /dev/snd/controlC0  (116,56)
#       33:        : timer                       → /dev/snd/timer      (116,33)
#    第一列 = minor。名字按类型+设备号拼。
# ---------------------------------------------------------------------------
mkdir -p /dev/snd

created=0; existed=0; failed=0
say "=== 解析 $DEVICES ==="
while read -r line; do
    minor=$(printf '%s\n' "$line" | sed -n 's/^ *\([0-9][0-9]*\):.*/\1/p')
    [ -n "$minor" ] || continue
    case "$line" in
        *"digital audio playback"*) dev=$(printf '%s\n' "$line" | sed -n 's/.*\[ *0- *\([0-9][0-9]*\)\].*/pcmC0D\1p/p') ;;
        *"digital audio capture"*)  dev=$(printf '%s\n' "$line" | sed -n 's/.*\[ *0- *\([0-9][0-9]*\)\].*/pcmC0D\1c/p') ;;
        *"control"*)                dev=controlC0 ;;
        *"timer"*)                  dev=timer ;;
        *)                          dev="" ;;
    esac
    [ -n "$dev" ] || continue

    node=/dev/snd/$dev
    if [ -e "$node" ]; then
        existed=$((existed + 1))
        continue
    fi
    if [ "$CHECK" = 1 ]; then
        say "  缺: $node  (c $SND_MAJOR $minor)"
        continue
    fi
    if mknod "$node" c "$SND_MAJOR" "$minor" 2>/dev/null; then
        chmod 660 "$node" 2>/dev/null
        created=$((created + 1))
    else
        failed=$((failed + 1))
        say "  建失败: $node  (c $SND_MAJOR $minor)"
    fi
done < "$DEVICES"

say "=== 节点统计：新建 $created / 已存在 $existed / 失败 $failed ==="
say "=== /dev/snd 现有 $(ls /dev/snd 2>/dev/null | wc -l) 个节点 ==="

# ---------------------------------------------------------------------------
# 2) 自检
# ---------------------------------------------------------------------------
say ""
say "=== 自检 aplay -l ==="
if aplay -l >/tmp/.aplay.$$ 2>&1; then
    say "  OK：ALSA 能列出播放设备"
    sed -n '1,6p' /tmp/.aplay.$$
    say "  ...（共 $(grep -c '^card ' /tmp/.aplay.$$) 个播放设备）"
else
    say "  ✗ aplay -l 失败："
    sed -n '1,6p' /tmp/.aplay.$$
fi
rm -f /tmp/.aplay.$$

say ""
say "=== 自检 mixer 访问（★ 必须用 cget numid=，不能用 sget 名字）==="
# 实测坑：`amixer -c0 sget "<名字>"` 一律报
#     "Mixer sysdefault:0 load error: Operation not permitted"
# 这是 alsa-lib 走 default/sysdefault 插件时的假错误；
# 同一张卡用 **numid** 读就正常（`amixer -D hw:0 cget numid=251` → values=0）。
# ⇒ 脚本/上层一律走 numid，别按名字读。
if amixer -D hw:0 cget numid=251 >/tmp/.amix.$$ 2>&1; then
    say "  OK：amixer -D hw:0 cget numid=251 →"
    sed -n '1,4p' /tmp/.amix.$$
else
    say "  ✗ amixer cget 失败："
    sed -n '1,4p' /tmp/.amix.$$
fi
rm -f /tmp/.amix.$$

say ""
say "完成。⚠️ 节点齐了也**不代表能出声**，见 audio/README.md 第 3 节。"

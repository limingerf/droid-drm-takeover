#!/bin/sh
# core/lib/boot.sh — 容器侧脚本的统一引导（source 它即可，不要执行）。
#
# 用法（容器侧脚本开头两行）:
#   SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
#   . "$SELF_DIR/../core/lib/boot.sh"
#
# 它负责：定位仓库根、确定 DRM_SIDE=container、按依赖顺序 source 全部 lib、
# 初始化状态文件。安卓侧脚本不要用它（安卓侧只 source 需要的 lib）。

DRM_SIDE=container
export DRM_SIDE

# 定位仓库根：优先用调用方已算好的 SELF_DIR，否则从 $0 推
if [ -z "${SELF_DIR:-}" ]; then
    SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
fi
if [ -z "${DRM_ROOT:-}" ]; then
    for _c in "$SELF_DIR/.." "$SELF_DIR/../.." "/root/droid-drm-takeover" "/opt/droid-drm-takeover"; do
        if [ -f "$_c/core/lib/common.sh" ]; then
            DRM_ROOT=$(cd "$_c" && pwd)
            break
        fi
    done
fi
[ -n "${DRM_ROOT:-}" ] || { echo "boot.sh: 找不到仓库根" >&2; exit 1; }
export DRM_ROOT

# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/common.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/device.sh"
drm_device_load
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/android.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/container.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/display.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/net.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/enter.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/request.sh"

drm_state_init

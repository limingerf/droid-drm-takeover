#!/bin/sh
# display/drm-stop.sh — 结束接管并把安卓拉回来（原地，不重启）。
#
# ══ 与 desk-stop.sh 的区别 ══
# 历史上本脚本对应"常驻接管模式"（旧 drm-takeover.sh PERSIST=1），
# 那条路径会把 system_server SIGSTOP 冻住，所以它必须 `kill -CONT`。
# 现在两条路径的恢复逻辑已经合并到 core/lib，本脚本保留为兼容入口，
# 实际行为 = desk-stop.sh。旧脚本名字继续可用，但**不再有第二套语义**。
#
# ══ 用法 ══
#   sudo sh display/drm-stop.sh

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")

echo "提示：drm-stop.sh 已合并进 desk-stop.sh（两条恢复路径重构后语义统一）。" >&2
echo "      现在转发到 desk-stop.sh。" >&2

exec sh "$SELF_DIR/desk-stop.sh" "$@"

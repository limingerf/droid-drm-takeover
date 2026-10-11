#!/bin/sh
# display/kill-desktop.sh — 收掉容器侧的 Linux 桌面栈（在容器内执行）
#
# 【为什么需要这个脚本】
# 安卓侧的 core/switch.sh 在返回安卓时要清理容器里的残留进程，但它只能通过
# `ds_exec` 往容器里发一段命令字符串。那段命令原来写的是：
#
#     pkill -9 -f kwinwrap; pkill -9 -x kwin_wayland; pkill -9 -x plasmashell
#
# 两个问题：
#   · 容器是个精简 rootfs，`pkill` 来自 procps，**不保证装了**。
#     没装的话这行静默失败（外面套了 `|| true`），残留的 kwinwrap/kwin
#     会继续握着 DRM 节点，影响随后的安卓显示栈启动。
#   · `pkill -f` 按正则匹配整条命令行，会误伤无关进程。
#
# 现在改成这个脚本：它 source boot.sh 拿到全套 /proc 扫描助手，
# 走和 linux/session-up.sh 完全一样的清理逻辑（drm_kill_linux_stack）。
#
# 幂等，失败无害 —— 调用方本来就忽略它的退出码。

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

drm_kill_linux_stack
exit 0

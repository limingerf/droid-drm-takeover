#!/system/bin/sh
# android/enter.sh — 安卓侧"进入 Linux"入口（APK 与命令行都走它）。
#
# 这是 core/switch.sh enter 的薄封装：补上安卓侧特有的环境准备
# （PATH、SELinux 上下文、日志重定向），然后交给状态机。
#
# 用法（安卓侧，root）:
#   su -c 'sh /data/local/drm-takeover/android/enter.sh'
#
# ⚠️ 执行前请确认：
#   · 已保存所有工作（安卓的 framework 会被停掉）
#   · 电源键长按是逃生阀（本脚本从不拦截 input 事件）
#   · 屏幕会在约 10-30 秒内黑掉，然后由 KWin 接管点亮

set -u

# ★ 默认 /data/local/drm-takeover（/data/local 是 0711 root:root），
#   不是 /data/local/tmp。后者是 0771 shell:shell，任何 adb shell 都能写，
#   而本脚本以 root 执行 —— 那等于把 root 代码执行权交出去。
#   详见 core/lib/common.sh 里 DRM_ANDROID_PAYLOAD 的注释。
DRM_PAYLOAD=${DRM_PAYLOAD:-/data/local/drm-takeover}
DRM_SIDE=android
export DRM_SIDE
# 安卓侧 PATH 经常不全（toybox 的 coreutils 在 /system/bin）
export PATH="/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:/sbin:/bin:$PATH"

DRM_ROOT=$DRM_PAYLOAD
[ -f "$DRM_ROOT/core/switch.sh" ] || {
    echo "找不到 $DRM_ROOT/core/switch.sh" >&2
    echo "请先在 APK 里点一次「安装/更新 payload」，或手动 push 仓库到该目录" >&2
    exit 1
}

LOG_DIR="$DRM_ROOT/logs"
mkdir -p "$LOG_DIR" 2>/dev/null

echo "════ droid-drm-takeover：进入 Linux ════"
echo "payload : $DRM_ROOT"
echo "日志    : $LOG_DIR"

# 残留的"返回安卓"请求由 core/lib/enter.sh 在容器起来后清理
# （真正的请求文件在**共享目录**下，不是 payload 目录 —— 这里原来清错了地方）。

exec sh "$DRM_ROOT/core/switch.sh" enter

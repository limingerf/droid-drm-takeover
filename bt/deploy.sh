#!/bin/sh
# bt/deploy.sh — 在**主机**上把桥和验收脚本推到设备并跑起来。
#
# 用法（在仓库根目录，或任意位置）：
#   sh bt/deploy.sh                构建 → 推送 → 跑完整验收（跑完收桥）
#   sh bt/deploy.sh --stay         跑完验收后把桥留着（容器里能直接用蓝牙）
#   sh bt/deploy.sh --down         只把设备上的桥收掉并验残留
#   sh bt/deploy.sh --no-build     跳过构建，推现在 bt/out 里的产物
#   ADB=... SERIAL=... sh bt/deploy.sh
#
# 为什么主机侧也要有脚本：桥必须在**安卓侧**以 root 跑（它要访问
# hwservicemanager 和 vendor HAL），而 bluetoothd/bluetoothctl 在容器里。
# 两边的手工步骤（push → chmod → su → droidspaces run ...）错一步就会得到
# 误导性的结果（比如把"桥没起来"看成"BlueZ 不认控制器"），所以固化下来。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-adb}
SERIAL=${SERIAL:-}
TMP=/data/local/tmp

MODE=full
DO_BUILD=1
for a in "$@"; do
    case "$a" in
        --stay) MODE=stay ;;
        --down) MODE=down ;;
        --no-build) DO_BUILD=0 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

if [ -n "$SERIAL" ]; then
    A() { "$ADB" -s "$SERIAL" "$@"; }
else
    A() { "$ADB" "$@"; }
fi

# Windows 的 adb.exe 看不懂 WSL/Unix 路径（会报 "cannot stat ..."）。
# 本项目的实际工作环境就是 WSL 里调 Windows 的 adb，所以这里必须转。
to_adb_path() {
    case "$ADB" in
        *.exe|*.EXE)
            if command -v wslpath >/dev/null 2>&1; then
                wslpath -w "$1"
            else
                printf '%s' "$1"
            fi
            ;;
        *) printf '%s' "$1" ;;
    esac
}

say() { echo "── $* ──"; }

say "检查设备"
A wait-for-device
A shell 'id' >/dev/null
echo "device: $(A shell getprop ro.product.model | tr -d '\r') ($(A shell getprop ro.build.version.release | tr -d '\r'))"
echo "surfaceflinger: $(A shell getprop init.svc.surfaceflinger | tr -d '\r')"
echo "容器: $(A shell "su -c '/data/local/Droidspaces/bin/droidspaces show'" 2>/dev/null | tr -d '\r' | grep -o DEBIAN || echo '未找到 DEBIAN')"

if [ "$DO_BUILD" = 1 ] && [ "$MODE" != down ]; then
    say "构建（NDK）"
    sh "$HERE/build.sh"
fi

if [ "$MODE" != down ]; then
    [ -f "$HERE/out/bthci-bridge" ] || { echo "✗ 缺少 $HERE/out/bthci-bridge（先跑 sh bt/build.sh）" >&2; exit 1; }
    say "推送 bthci-bridge"
    A push "$(to_adb_path "$HERE/out/bthci-bridge")" "$TMP/bthci-bridge"
    # adb push 会把权限重置，不 chmod 就是 Permission denied
    A shell "su -c 'chmod 755 $TMP/bthci-bridge'"
    A shell "su -c 'ls -l $TMP/bthci-bridge'"
fi

say "推送 bt-bridge-up.sh"
A push "$(to_adb_path "$HERE/bt-bridge-up.sh")" "$TMP/bt-bridge-up.sh"

say "在安卓侧以 root 跑验收"
case "$MODE" in
    stay) A shell "su -c 'sh $TMP/bt-bridge-up.sh --stay'" ;;
    down) A shell "su -c 'sh $TMP/bt-bridge-up.sh --down'" ;;
    *)    A shell "su -c 'sh $TMP/bt-bridge-up.sh'" ;;
esac

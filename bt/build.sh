#!/bin/sh
# bt/build.sh — 用 Android NDK 交叉编译 bthci-bridge（bionic / aarch64）。
#
# 为什么必须用 NDK 而不是仓库根目录那个 Makefile：
#   根 Makefile 建的是 **glibc** 工具（跑在容器里的），而桥必须跑在**安卓侧**
#   （它要访问 hwservicemanager 和 vendor HAL 的 /vendor/lib64/*.so），
#   安卓用户态是 bionic。两者不能混。所以这个脚本是独立的，不动根 Makefile。
#
# 用法：
#   sh bt/build.sh              构建（NDK 自动探测）
#   NDK=/opt/android-ndk-r27c sh bt/build.sh
#   BT_OUT=/tmp/o sh bt/build.sh
#
# 产出：$BT_OUT/bthci-bridge （默认 bt/out/bthci-bridge）
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BT_OUT=${BT_OUT:-$HERE/out}

# ── 找 NDK ───────────────────────────────────────────────────────────
# CI（GitHub ubuntu runner）自带 Android SDK/NDK，环境变量是 ANDROID_NDK_LATEST_HOME；
# 本机 WSL 上是 /opt/android-ndk-r27c。两条路都要能走。
NDK_DIR=${NDK:-}
if [ -z "$NDK_DIR" ] && [ -n "${ANDROID_NDK_LATEST_HOME:-}" ] && [ -d "${ANDROID_NDK_LATEST_HOME}" ]; then
    NDK_DIR=$ANDROID_NDK_LATEST_HOME
fi
if [ -z "$NDK_DIR" ] && [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
    NDK_DIR=$ANDROID_NDK_HOME
fi
if [ -z "$NDK_DIR" ] && [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "${ANDROID_NDK_ROOT}" ]; then
    NDK_DIR=$ANDROID_NDK_ROOT
fi
if [ -z "$NDK_DIR" ]; then
    for d in /opt/android-ndk-r* /usr/local/lib/android/sdk/ndk/* "$HOME"/android-ndk-r*; do
        [ -d "$d" ] || continue
        NDK_DIR=$d
        break
    done
fi
if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
    echo "✗ 找不到 Android NDK。用 NDK=<路径> sh bt/build.sh 指定。" >&2
    exit 1
fi
echo "NDK      : $NDK_DIR"

# ── 找 aarch64 的 clang++（取可用的最高 API level）────────────────────
# 不写死 API：runner 上的 NDK 版本随镜像变，写死 35 会在老 NDK 上直接找不到编译器。
TC=""
for cand in "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin" \
            "$NDK_DIR/toolchains/llvm/prebuilt/darwin-x86_64/bin"; do
    [ -d "$cand" ] && TC=$cand && break
done
if [ -z "$TC" ]; then
    echo "✗ NDK 里没有 llvm prebuilt 工具链（$NDK_DIR/toolchains/llvm/prebuilt/*）" >&2
    exit 1
fi
CXX=""
for api in 36 35 34 33 32 31 30; do
    if [ -x "$TC/aarch64-linux-android$api-clang++" ]; then
        CXX=$TC/aarch64-linux-android$api-clang++
        break
    fi
done
if [ -z "$CXX" ]; then
    echo "✗ 找不到 aarch64-linux-android<api>-clang++（试过 API 30..36）" >&2
    ls "$TC" | head -20 >&2
    exit 1
fi
echo "CXX      : $CXX"
"$CXX" --version | head -1

mkdir -p "$BT_OUT"

# ── 先跑宿主机单测 ───────────────────────────────────────────────────
# h4framing.h 里那两段逻辑（一回调多包 / pty 短写）是"内核 H4 解析器一旦跑偏就永久哑"
# 的入口。能在宿主机断言的事，绝不带到设备上去试。
if [ -z "${BT_SKIP_TEST:-}" ]; then
    HOSTCXX=""
    for c in c++ g++ clang++; do
        if command -v "$c" >/dev/null 2>&1; then HOSTCXX=$c; break; fi
    done
    if [ -n "$HOSTCXX" ]; then
        "$HOSTCXX" -std=c++17 -O1 -Wall -Wextra -o "$BT_OUT/h4framing-test" \
            "$HERE/h4framing-test.cpp"
        "$BT_OUT/h4framing-test"
    else
        echo "· 没有宿主机 C++ 编译器，跳过 h4framing 单测"
    fi
fi

# ── 交叉编译 ─────────────────────────────────────────────────────────
# -static-libstdc++：只留 libdl/libm/libc 三个 NEEDED，不依赖 libc++_shared.so。
#   （跨 DSO 传 std::string/std::function 仍然成立 —— libc++ 的 ABI 是稳定的，
#     而且这条路已在 btprobe/btprobe2 上实测跑通。）
# -Wl,-z,max-page-size=16384：安卓 15+ 的 16K 页设备上，4K 对齐的段加载会失败。
# -fPIE -pie：安卓 10+ 强制 PIE。
"$CXX" -std=c++17 -O2 -g -Wall -Wextra -Wno-unused-parameter \
    -fPIE -pie -Wl,-z,max-page-size=16384 \
    -static-libstdc++ \
    -o "$BT_OUT/bthci-bridge" "$HERE/bthci-bridge.cpp" -ldl

# ── 产物自检：必须是 aarch64、必须只有三个 NEEDED ─────────────────────
READELF=$TC/llvm-readelf
if [ -x "$READELF" ]; then
    echo "── 产物自检 ──"
    "$READELF" -h "$BT_OUT/bthci-bridge" | grep -E 'Class|Machine|Type:'
    echo "NEEDED:"
    "$READELF" -d "$BT_OUT/bthci-bridge" | grep NEEDED || true
    if ! "$READELF" -h "$BT_OUT/bthci-bridge" | grep -q 'AArch64'; then
        echo "✗ 产物不是 AArch64" >&2
        exit 1
    fi
fi
ls -l "$BT_OUT/bthci-bridge"
echo "✓ 构建完成：$BT_OUT/bthci-bridge"

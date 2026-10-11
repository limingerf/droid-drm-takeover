#!/bin/sh
# ============================================================================
# android/build.sh — 构建 DRM 切换器 APK（纯 SDK 工具链，无 Gradle）
#
# 为什么不用 Gradle：构建环境没有 Gradle，也没有到 Google Maven 的网络。
# 这里手工走一遍 Gradle 的活儿：
#
#   aapt2 compile  → 编译 res/
#   aapt2 link     → 链接 manifest + 资源 + assets，产出基础 APK 和 R.java
#   javac          → 用 android.jar 编译 Java 源码
#   d8             → 把 .class 转成 classes.dex
#   zip            → 把 classes.dex 塞进 APK
#   zipalign       → 4 字节对齐
#   apksigner      → 用调试密钥签名
#
# 用法:
#   sh android/build.sh            # 构建
#   sh android/build.sh clean      # 清掉 build/ 目录
#
# 环境变量（都可选）:
#   ANDROID_HOME / ANDROID_SDK_ROOT   SDK 位置
#   BUILD_DIR                         输出目录（默认 android/build）
#   OUT_APK                           最终 APK 路径
#   D8                                d8 可执行文件路径
#   R8_JAR                            含 D8 的 r8.jar 路径
#   KEYSTORE                          签名密钥库路径
#
# 退出码 0 表示成功，最后一行打印 APK 绝对路径。
# ============================================================================

set -eu

# ---------------------------------------------------------------- 路径

SELF=$0
case "$SELF" in
    */*) ANDROID_DIR=$(cd "$(dirname "$SELF")" && pwd) ;;
    *)   ANDROID_DIR=$(pwd) ;;
esac
WORK_ROOT=$(cd "$ANDROID_DIR/.." && pwd)
APP_DIR=$ANDROID_DIR/app

BUILD_DIR=${BUILD_DIR:-$ANDROID_DIR/build}
OUT_APK=${OUT_APK:-$BUILD_DIR/drmswitch.apk}
KEYSTORE=${KEYSTORE:-$BUILD_DIR/debug.keystore}

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
step() { printf '\n── %s\n' "$*"; }

if [ "${1:-}" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    log "已清理 $BUILD_DIR"
    exit 0
fi

[ -d "$APP_DIR" ] || die "找不到 $APP_DIR"

# ---------------------------------------------------------------- 找 SDK

find_sdk() {
    for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             /tmp/android-sdk /opt/android-sdk "$HOME/Android/Sdk" \
             /usr/lib/android-sdk /usr/local/android-sdk; do
        [ -n "$c" ] || continue
        [ -d "$c" ] || continue
        printf '%s\n' "$c"
        return 0
    done
    return 1
}

SDK=$(find_sdk || true)
[ -n "$SDK" ] || die "找不到 Android SDK。
请设置 ANDROID_HOME / ANDROID_SDK_ROOT，或把 SDK 放到 /tmp/android-sdk、/opt/android-sdk、\$HOME/Android/Sdk。
（注意 /tmp 是易失的：如果 SDK 在 /tmp/android-sdk 且不见了，需要重新准备，本脚本不会联网下载。）"

step "SDK: $SDK"

# build-tools：挑一个含 aapt2 的目录
BT_DIR=""
for d in "$SDK"/build-tools/*; do
    [ -d "$d" ] || continue
    [ -x "$d/aapt2" ] || continue
    BT_DIR=$d
done

# 平台：优先 android-35，其次版本号最大的
ANDROID_JAR=""
for d in "$SDK"/platforms/* /usr/lib/android-sdk/platforms/*; do
    [ -f "$d/android.jar" ] || continue
    case "$d" in
        */android-35) ANDROID_JAR=$d/android.jar; break ;;
    esac
done
if [ -z "$ANDROID_JAR" ]; then
    for d in "$SDK"/platforms/* /usr/lib/android-sdk/platforms/*; do
        [ -f "$d/android.jar" ] || continue
        ANDROID_JAR=$d/android.jar
    done
fi
[ -n "$ANDROID_JAR" ] || die "在 $SDK/platforms 下找不到 android.jar"
[ -f "$ANDROID_JAR" ] || die "android.jar 不存在: $ANDROID_JAR"

# 逐个解析工具：优先 build-tools，其次 PATH
find_tool() {
    _n=$1
    if [ -n "$BT_DIR" ] && [ -x "$BT_DIR/$_n" ]; then
        printf '%s\n' "$BT_DIR/$_n"; return 0
    fi
    _p=$(command -v "$_n" 2>/dev/null || true)
    if [ -n "$_p" ]; then printf '%s\n' "$_p"; return 0; fi
    return 1
}

AAPT2=$(find_tool aapt2 || true)
APKSIGNER=$(find_tool apksigner || true)
ZIPALIGN=$(find_tool zipalign || true)
KEYTOOL=$(command -v keytool 2>/dev/null || true)
JAVAC=$(command -v javac 2>/dev/null || true)
JAVA=$(command -v java 2>/dev/null || true)
JAR=$(command -v jar 2>/dev/null || true)
ZIP=$(command -v zip 2>/dev/null || true)

[ -n "$AAPT2" ]    || die "找不到 aapt2（既不在 build-tools 也不在 PATH）"
[ -n "$APKSIGNER" ] || die "找不到 apksigner"
[ -n "$ZIPALIGN" ] || die "找不到 zipalign"
[ -n "$KEYTOOL" ]  || die "找不到 keytool（需要 JDK）"
[ -n "$JAVAC" ]    || die "找不到 javac（需要 JDK）"
[ -n "$ZIP" ]      || die "找不到 zip"

# D8：优先真 d8，否则用 r8.jar 里的 com.android.tools.r8.D8
D8_MODE=""
D8_BIN=""
D8_JAR=""
if [ -n "${D8:-}" ] && [ -x "${D8:-}" ]; then
    D8_MODE=bin; D8_BIN=$D8
elif [ -n "$BT_DIR" ] && [ -x "$BT_DIR/d8" ]; then
    D8_MODE=bin; D8_BIN=$BT_DIR/d8
elif command -v d8 >/dev/null 2>&1; then
    D8_MODE=bin; D8_BIN=$(command -v d8)
else
    for j in "${R8_JAR:-}" /tmp/r8.jar /tmp/codex-dex-tools/r8.jar; do
        [ -n "$j" ] || continue
        if [ -f "$j" ] && [ -s "$j" ]; then D8_JAR=$j; break; fi
    done
    if [ -z "$D8_JAR" ] && [ -n "$JAVA" ]; then
        for root in /opt /usr/share /usr/lib /tmp "$HOME"; do
            [ -d "$root" ] || continue
            j=$(find "$root" -maxdepth 6 -name 'r8.jar' -size +1M 2>/dev/null | head -n 1 || true)
            if [ -n "$j" ]; then D8_JAR=$j; break; fi
        done
    fi
    [ -n "$D8_JAR" ] || die "找不到 d8，也找不到含 D8 的 r8.jar。
请安装 build-tools（含 d8），或把 r8.jar 放到 /tmp/r8.jar，或用 R8_JAR=/path/to/r8.jar 指定。"
    [ -n "$JAVA" ] || die "用 r8.jar 跑 D8 需要 java"
    D8_MODE=jar
fi

log "build-tools : ${BT_DIR:-（用 PATH 上的工具）}"
log "android.jar : $ANDROID_JAR"
log "aapt2       : $AAPT2"
log "d8          : $([ "$D8_MODE" = bin ] && echo "$D8_BIN" || echo "java -cp $D8_JAR com.android.tools.r8.D8")"

# ---------------------------------------------------------------- 准备目录

step "准备构建目录"
# 注意：只删中间产物，不删 build/ 本身 —— 调试密钥库必须跨构建稳定，
# 否则每次重编都换签名，覆盖安装会报 "signatures do not match"。
# 想连密钥库一起清掉请用 `sh build.sh clean`。
rm -rf "$BUILD_DIR/assets" "$BUILD_DIR/res" "$BUILD_DIR/gen" \
       "$BUILD_DIR/classes" "$BUILD_DIR/dex" \
       "$BUILD_DIR/base.apk" "$BUILD_DIR/unsigned.apk" "$BUILD_DIR/aligned.apk" \
       "$BUILD_DIR/res.zip" "$BUILD_DIR/classes.jar" \
       "$BUILD_DIR/sources.txt" "$BUILD_DIR/classes.txt" "$BUILD_DIR/javac.log"
mkdir -p "$BUILD_DIR/assets/payload" "$BUILD_DIR/res" "$BUILD_DIR/gen" \
         "$BUILD_DIR/classes" "$BUILD_DIR/dex"

# ---------------------------------------------------------------- 组装 assets

step "组装 assets/payload"
ASSETS=$BUILD_DIR/assets

copy_tree() {
    _src=$1; _dst=$2; _label=$3
    if [ -d "$_src" ]; then
        mkdir -p "$_dst"
        cp -R "$_src/." "$_dst/"
        log "  + $_label"
    else
        warn "  ! 跳过 $_label（源目录不存在：$_src）"
    fi
}

copy_tree "$WORK_ROOT/core"    "$ASSETS/payload/core"    "core/"
copy_tree "$WORK_ROOT/linux"   "$ASSETS/payload/linux"   "linux/"
copy_tree "$WORK_ROOT/display" "$ASSETS/payload/display" "display/"
copy_tree "$WORK_ROOT/tools"   "$ASSETS/payload/tools"   "tools/"
copy_tree "$WORK_ROOT/configs" "$ASSETS/payload/configs" "configs/"
copy_tree "$WORK_ROOT/bin"     "$ASSETS/payload/bin"     "bin/"

# ★ bin/ 是**硬要求**，不能像上面那样"缺了就跳过"。
#   缺了照样能打出 APK，但里面只有脚本、一个二进制都没有 —— 装到设备上
#   点「进入 Linux」会在拉起会话那一步失败，现场信息还很间接。
#   所以这里直接失败，并把补救命令写在错误信息里。
if [ ! -f "$ASSETS/payload/bin/kwinwrap" ]; then
    die "APK 里没有 bin/kwinwrap —— 编译产物缺失。

  bin/ 是 payload 的必需部分（kwinwrap 是全项目的 DRM 交接桥）。
  先编译再打包：

      export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
      make -j\"\$(nproc)\" CC=aarch64-linux-gnu-gcc
      ls bin/kwinwrap

  或者直接在目标容器里原生 make（容器是 aarch64，不需要交叉编译）。
  期望 bin/ 里有 24 个产物。"
fi
_nbin=$(find "$ASSETS/payload/bin" -type f | wc -l | tr -d ' ')
log "  payload/bin: $_nbin 个产物"
if [ "$_nbin" -lt 24 ]; then
    warn "  ! payload/bin 只有 $_nbin 个（期望 24）—— 可能编到一半失败了"
fi

# android/ 只带 .sh 包装脚本，不带 app/ 和 build.sh
mkdir -p "$ASSETS/payload/android"
for f in "$ANDROID_DIR"/*.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        build.sh) continue ;;
    esac
    cp "$f" "$ASSETS/payload/android/"
    log "  + android/$(basename "$f")"
done

# 清掉不该进 APK 的杂物
find "$ASSETS" \( -name '.git' -o -name '.gitignore' -o -name '*.pyc' \
    -o -name '__pycache__' -o -name '.DS_Store' -o -name '*.swp' \) \
    -exec rm -rf {} + 2>/dev/null || true

ASSET_COUNT=$(find "$ASSETS" -type f | wc -l | tr -d ' ')
log "  assets 文件总数: $ASSET_COUNT"

# ---------------------------------------------------------------- 资源

step "编译资源"
cp -R "$APP_DIR/res/." "$BUILD_DIR/res/"

# 图标：base64 内嵌在脚本里，构建时解码成 PNG。
# 这样仓库里不用存二进制文件，构建也不依赖任何图像库。
mkdir -p "$BUILD_DIR/res/mipmap-xxhdpi"
ICON_B64='iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAACtElEQVR42u3dh07bUBiG4dwFe5VdZtnz7rpLJyPsvffeeyZsOum4l68ElEpFqJBix8a8r+Qb8CM58TlH/l0uIiIigyo8fqfC4/cqOPqggsNK5R9UKX+/Wnl7NcrbdSvXW6tcT51yPPXK2WnQo+2za6tR2ZtNyt5oVvZ6i7LWWpW12qbM1XZlrnQoY7lTGUtdSl/sVvpCj9Lme5U216eHs/0X18yAUqcHlTo1pJTJYaVMjCh5fFTJY2NKGh1X0siEEkcmlTg8pYShaSUMzihhYFbx/XOK75vXg96zq2dBcT2LiuteUmzXsmI7VxTTsaqY9jVFt60runVDUS2bstXNLv5SoeLPFSr69FpFH9+o8OStnA4Q1bKlqOZtRTbtKLLRo4gGb/BRSr69VMnXVwLgAiCi3qvwul3zIUpPn6v09IUAuBogvHZPYe59cyDKvj8TADcDCHMfGItQ9uOpAAgMILTm0BiE8p9PBMD/AYRWH90OofzXYwFwO4CQqmMBcBcBzm8+AIYAhFSeCIC7BPDn5gNgGEBACAAAAAAAANxPgL9uPgCGAtwIAQAAAHAygC8ALAY4RwDAWgB/AFgM4AsAiwH8AWAxwDkCANYC+APAYgBfdxrASQFgBwQA7BEAdkAAAAAeQQDwI8zfUADMjTdhliJYjAOA5Wg2ZABgS5JNeQA4lsLBLAAAMBfAFwAWAfgDIMgAlwMgiABXBUAQAP4VACYDXBcAJgHcNABMAAgkAAwEcN6GPFuSAFwH4OjzQHYHcHoAAMAjiB9hAPgb6ugXMQBYimAxDgCWo9mQAYAtSTblAeBYCgezAAAAgHsFwIdb+XIuAAAAAAAAFgIwwoQZMgAwxoo5YgAwytDiUYYM87TBME/G2dpgnC0DnW0w0JmR5jYYaX45AC4AXHbK6QAuIiIig/oNBD9lsaN5kj0AAAAASUVORK5CYII='
printf '%s' "$ICON_B64" | base64 -d > "$BUILD_DIR/res/mipmap-xxhdpi/ic_launcher.png"
log "  图标: $(wc -c < "$BUILD_DIR/res/mipmap-xxhdpi/ic_launcher.png") 字节"

"$AAPT2" compile --dir "$BUILD_DIR/res" -o "$BUILD_DIR/res.zip"

step "链接资源 + manifest + assets"
# 注意：编译产物用「位置参数」传入（不是 -R）。-R 是 overlay 语义，
# 单一资源包走 -R 会被 aapt2 当成覆盖而报 "does not override an existing resource"。
"$AAPT2" link \
    -o "$BUILD_DIR/base.apk" \
    -I "$ANDROID_JAR" \
    --manifest "$APP_DIR/AndroidManifest.xml" \
    -A "$ASSETS" \
    --java "$BUILD_DIR/gen" \
    "$BUILD_DIR/res.zip"

# ---------------------------------------------------------------- 编译 Java

step "编译 Java"
find "$APP_DIR/src" "$BUILD_DIR/gen" -name '*.java' > "$BUILD_DIR/sources.txt"
SRC_COUNT=$(wc -l < "$BUILD_DIR/sources.txt" | tr -d ' ')
log "  java 源文件: $SRC_COUNT"
[ "$SRC_COUNT" -gt 0 ] || die "没有找到任何 .java 源文件"

# -source/-target 8：D8 最稳的输入形态，Android 26+ 完全支持。
if ! "$JAVAC" \
    -encoding UTF-8 \
    -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -classpath "$ANDROID_JAR" \
    -d "$BUILD_DIR/classes" \
    @"$BUILD_DIR/sources.txt" > "$BUILD_DIR/javac.log" 2>&1; then
    cat "$BUILD_DIR/javac.log" >&2
    die "javac 编译失败"
fi
grep -v 'bootstrap class path' "$BUILD_DIR/javac.log" || true

[ -f "$BUILD_DIR/classes/dev/limingerf/drmswitch/MainActivity.class" ] \
    || die "javac 没有产出 MainActivity.class，编译失败"

# ---------------------------------------------------------------- dex

step "生成 classes.dex"
# D8 8.x 不接受裸目录作为输入（"Unsupported source file type"），
# 所以先把 class 打成 jar 再喂给它。
run_d8() {
    if [ "$D8_MODE" = bin ]; then
        "$D8_BIN" --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" "$@"
    else
        "$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 \
            --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" "$@"
    fi
}

if [ -n "$JAR" ]; then
    "$JAR" cf "$BUILD_DIR/classes.jar" -C "$BUILD_DIR/classes" .
    run_d8 "$BUILD_DIR/classes.jar"
else
    warn "  ! 没有 jar 命令，直接把 .class 列表交给 d8"
    find "$BUILD_DIR/classes" -name '*.class' > "$BUILD_DIR/classes.txt"
    # shellcheck disable=SC2046
    run_d8 $(cat "$BUILD_DIR/classes.txt")
fi
[ -f "$BUILD_DIR/dex/classes.dex" ] || die "d8 没有产出 classes.dex"

# ---------------------------------------------------------------- 打包

step "组装 APK"
cp "$BUILD_DIR/base.apk" "$BUILD_DIR/unsigned.apk"
( cd "$BUILD_DIR/dex" && "$ZIP" -q -X "$BUILD_DIR/unsigned.apk" classes.dex )

step "对齐"
"$ZIPALIGN" -f -p 4 "$BUILD_DIR/unsigned.apk" "$BUILD_DIR/aligned.apk"

step "签名"
if [ ! -f "$KEYSTORE" ]; then
    log "  生成调试密钥库: $KEYSTORE"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KEYSTORE" \
        -storepass android -keypass android \
        -alias androiddebugkey \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 \
        || die "keytool 生成密钥库失败"
fi

"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    --min-sdk-version 26 \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

step "自检"
"$APKSIGNER" verify --print-certs "$OUT_APK" | sed 's/^/  /'

# ---------------------------------------------------------------- 结果

SIZE=$(wc -c < "$OUT_APK" | tr -d ' ')
HUMAN=$(du -h "$OUT_APK" | cut -f1)
SHA=$(sha256sum "$OUT_APK" | cut -d' ' -f1)
log ""
log "════════════════════════════════════════"
log "构建成功"
log "  APK   : $OUT_APK"
log "  大小  : $SIZE 字节 ($HUMAN)"
log "  SHA256: $SHA"
log "  assets: $ASSET_COUNT 个文件"
log "════════════════════════════════════════"
log "$OUT_APK"

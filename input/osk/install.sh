#!/bin/sh
# install.sh —— 把 PC 风格布局装进 maliit-keyboard
#
# 用法（在容器里执行）：
#     sh install.sh              # 安装
#     sh install.sh restore      # 还原成发行版原版
#
# ★ 为什么是替换发行版文件而不是放"用户布局目录"
# maliit 的布局路径是写死在语言插件目录里的：
#     /usr/lib/aarch64-linux-gnu/maliit/keyboard2/languages/<lang>/Keyboard_<lang>.qml
# GSettings 里确实有个 plugin-paths，但它搜的是**插件**（.so），不是布局 QML。
# 所以只能替换那个文件。为了可回退，装之前先把原版备份到
#     <原文件>.orig-<时间戳>
# 并且 restore 会把最近一次备份还原回去。
#
# 幂等：已经装过（内容一致）就不重复备份。

set -e

LANGDIR=/usr/lib/aarch64-linux-gnu/maliit/keyboard2/languages
TARGET_LANG=${OSK_LANG:-zh-hans}
TARGET="$LANGDIR/$TARGET_LANG/Keyboard_$TARGET_LANG.qml"
SRC=$(dirname "$0")/Keyboard_zh-hans.qml

if [ "$1" = "restore" ]; then
    echo "=== 还原 $TARGET ==="
    BAK=$(ls -1t "$TARGET".orig-* 2>/dev/null | head -1)
    if [ -z "$BAK" ]; then
        echo "  找不到备份（$TARGET.orig-*），无法还原"
        exit 1
    fi
    cp -a "$BAK" "$TARGET"
    echo "  已从 $BAK 还原"
    ls -l "$TARGET" | sed 's/^/  /'
    echo "  ★ 需要重启屏幕键盘才生效（KWin 会自己重新拉起）"
    exit 0
fi

echo "=== 1. 前置检查 ==="
if [ ! -d "$LANGDIR/$TARGET_LANG" ]; then
    echo "  ✗ 没有 $LANGDIR/$TARGET_LANG —— maliit-keyboard 装了吗？"
    echo "    可用语言：$(ls -1 "$LANGDIR" 2>/dev/null | tr '\n' ' ')"
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "  ✗ 找不到源文件 $SRC"
    exit 1
fi
echo "  ✓ 目标 $TARGET"
echo "  ✓ 源   $SRC"

echo
echo "=== 2. 内容是否已经一致（幂等）==="
if [ -f "$TARGET" ] && cmp -s "$SRC" "$TARGET"; then
    echo "  内容一致，无需安装"
    exit 0
fi

echo
echo "=== 3. 备份原版（只备份一次）==="
# 如果现有 TARGET 本身已经是我们的版本，就不要把它当"原版"备份 ——
# 否则会把备份覆盖成我们的版本，restore 就还原不回去了。
if ls -1 "$TARGET".orig-* >/dev/null 2>&1; then
    echo "  已有备份，跳过：$(ls -1t "$TARGET".orig-* | head -1)"
else
    BAK="$TARGET.orig-$(date +%Y%m%d-%H%M%S)"
    cp -a "$TARGET" "$BAK"
    echo "  已备份到 $BAK"
fi

echo
echo "=== 4. 安装 ==="
cp -a "$SRC" "$TARGET"
chmod 644 "$TARGET"
ls -l "$TARGET" | sed 's/^/  /'
echo "  行数：$(wc -l < "$TARGET")"

echo
echo "=== 5. 校验 QML 语法（用 qmllint，有就查）==="
if command -v qmllint >/dev/null 2>&1; then
    qmllint "$TARGET" 2>&1 | head -20 | sed 's/^/  /' || true
    echo "  (以上为命中)"
else
    echo "  没有 qmllint，跳过（装 qt6-declarative-dev-tools 可得到）"
fi

echo
echo "=== 6. 让新布局生效 ==="
# maliit 会把 QML 编译缓存放在 ~/.cache/maliit-keyboard/qmlcache/，
# 不清掉的话可能仍旧加载旧布局。
for H in /home/*; do
    [ -d "$H/.cache/maliit-keyboard/qmlcache" ] || continue
    rm -rf "$H/.cache/maliit-keyboard/qmlcache"
    echo "  已清 $H/.cache/maliit-keyboard/qmlcache"
done
echo "  ★ KWin 会自己重新拉起 maliit，无需手工启动（手工起会造成双实例拖影）"
echo "  若要立刻生效，可以重启会话或让 KWin 重启键盘进程"
echo
echo "装好了。还原：sh $0 restore"

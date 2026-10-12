#!/bin/sh
# install.sh —— 把 PC 风格布局装进 maliit-keyboard，并修掉高度抖动
#
# 用法（在容器里执行）：
#     sh install.sh              # 安装
#     sh install.sh restore      # 还原成发行版原版
#
# ══════════════════════════════════════════════════════════════════════
# 这个脚本解决三类"高度不一致"问题，它们都会表现为键盘闪烁 / 缺一块
# ══════════════════════════════════════════════════════════════════════
#
# 【问题一】maliit 的键高循环依赖
#
#     上游布局让每个键用 `height: panel.keyHeight`，而 panel.keyHeight 是
#     C++ 按"可用高度 / 行数"算出来的：
#
#         panel.keyHeight (C++) → 布局 implicitHeight → 窗口高度
#             → panel 高度 (C++) → panel.keyHeight      ← 闭环
#
#     maliit 靠迭代收敛。原版 4 行能收敛；我们的 5 行顶到上限收敛不了，
#     实测在 429/438 之间来回跳（60 次上报里高度变了 59 次）。
#
#     修法：给键高一个**固定值**（keyH），让 implicitHeight 不再依赖
#     panel.keyHeight，环就断了。代价是键盘高度不再随屏幕自适应。
#     keyH 当前是 54 —— 取值必须照 KBGEO 日志算，不能估（见下）。
#
# 【问题二】★★ 同一个键盘有 4 个布局变体，行数还不一样 ★★
#
#     KeyboardContainer.qml 按输入框的 contentType 选文件：
#
#         contentType 0 FreeText → Keyboard_<lang>.qml            （我们的，5 行）
#         contentType 3 Email    → Keyboard_<lang>_email.qml      （原版，4 行）
#         contentType 4 Url      → Keyboard_<lang>_url_search.qml （原版，4 行）
#         还有 Keyboard_<lang>_url.qml（磁盘上有，一并统一）
#
#     只改了 FreeText 那个，于是：
#         Chrome 地址栏（url_search，原版，高 438）→ 正常
#         搜索框（FreeText，我们的，高 434）      → 缺一块
#     用户的原话："好像有两个键盘，点 chrome 地址栏的键盘不缺，
#                 但点搜索框的键盘缺" —— 就是这个。
#
#     修法：把我们的布局装到**全部 8 个变体**（zh-hans + en 各 4 个），
#     高度天然一致。别的 40 种语言不动（用户只用这两个）。
#
# 【问题三】★ maliit 自己的 Keyboard.qml：候选条与"幽灵矩形" ★★
#
#     (a) 候选条（word ribbon）高度：
#         143:  height: visible ? keypad.keyHeight * 0.5 : 0
#         428:  var vy = wordRibbon.y;
#         430:  var vheight = keyboardComp.height + wordRibbon.height;
#         434:  obj.height = fullScreenItem.height - obj.y;   ← 这行覆盖了 vheight
#
#         上报给合成器的可见高度**完全由 obj.y 决定**，而 obj.y 来自
#         wordRibbon.y。候选条高度是"有候选词 9 像素 / 无候选词 0"，
#         于是每次弹出键盘，上报高度都会先 438 再 429 跳一次。
#         KWin 每次都 resize + 重绘 ⇒ 用户看到"刚打开时底部一闪一闪"。
#
#         改：height 固定 44。顺带修一个可用性问题 ——
#         keypad.keyHeight 实测是 18，所以候选条原本只有 9 像素高，
#         手指根本点不中。
#
#         为什么固定高度不会挤压按键：候选条是 anchors.bottom:
#         keyboardComp.top 定位的，而 keyboardComp 是 height: parent.height
#         + anchors.bottom: parent.bottom（全高）。候选条是**叠在键盘上方**
#         的，不参与布局分配，只影响上报高度。
#
#     (b) 收起时的"幽灵矩形"：
#         键盘收起时 keyboardSurface.y 被设成 canvas.height（整块面板下移），
#         但候选条的 visible 只取决于 WordEngine.enabled —— **跟键盘收没收起
#         无关**，所以它仍会被上报。实测收起时报出 <0 956 1600 44>：
#         合成器以为底部还留着 44 像素键盘，收起瞬间闪一下。
#         改之前候选条高度是 0，幽灵高度也是 0，看不出来；固定成 44 后就显形了。
#
#         改：428 行 → var vy = MaliitGeometry.shown ? wordRibbon.y : keyboardComp.y;
#         收起时 vy 退回键盘本体，映射后 obj.y == 屏幕高度 ⇒ 上报高度 0。
#
# ══════════════════════════════════════════════════════════════════════

set -e

LANGROOT=/usr/lib/aarch64-linux-gnu/maliit/keyboard2/languages
QMLDIR=/usr/lib/aarch64-linux-gnu/maliit/keyboard2/qml
KBQML="$QMLDIR/Keyboard.qml"
SRC=$(dirname "$0")/Keyboard_zh-hans.qml

# 要统一的语言（只用这两个；别的 40 种语言不动）
OSK_LANGS=${OSK_LANGS:-"zh-hans en"}

# 候选条固定高度（像素）。44 足够手指点中，且与原键盘风格协调。
RIBBON_H=${OSK_RIBBON_H:-44}

# ★ Keyboard.qml 用"整份替换"而不是 sed 打补丁。
# 原因：要改的是**布局关系**（候选条从叠在键盘上改成真正占位），
# 涉及 anchors 和 height 的多处联动，sed 打不干净而且脆弱。
# 补丁内容见同目录的 Keyboard.qml 里的 "改动 N/4" 注释。
KBQML_SRC=$(dirname "$0")/Keyboard.qml

# 把改动涉及的目标文件列出来。
#
# ★★ 这里踩过一个很隐蔽的坑，改之前务必看懂 ★★
#
# 旧写法是：
#     OSK_VARIANTS=" _email _url _url_search"
#     for V in $OSK_VARIANTS; do echo "...Keyboard_$L$V.qml"; done
# 想靠 shell 分词把**开头的空串**当成"基础布局"那一项。
# 但分词会吃掉开头的空字段 —— 于是 Keyboard_<lang>.qml **永远不会**
# 出现在列表里，只列了 6 个变体（2 语言 × 3 变体）。
#
# 后果非常误导人：脚本报"全部已是目标状态，无需安装"，而 maliit 做普通
# 文本输入时加载的正是那个**没被替换**的基础文件，所以怎么调键高都不生效。
# 表现就是"键盘最后一行怎么都出不来"，而日志上看不出任何异常。
#
# 所以：基础布局必须**显式单独输出一行**，不能靠分词。
target_files() {
    for L in $OSK_LANGS; do
        echo "$LANGROOT/$L/Keyboard_$L.qml"
        for V in _email _url _url_search; do
            echo "$LANGROOT/$L/Keyboard_$L$V.qml"
        done
    done
}

clear_qmlcache() {
    for H in /home/*; do
        [ -d "$H/.cache/maliit-keyboard/qmlcache" ] || continue
        rm -rf "$H/.cache/maliit-keyboard/qmlcache"
        echo "  已清 $H/.cache/maliit-keyboard/qmlcache"
    done
}

# ── 还原 ────────────────────────────────────────────────────
if [ "$1" = "restore" ]; then
    echo "=== 还原布局变体 ==="
    for T in $(target_files); do
        BAK=$(ls -1t "$T".orig-* 2>/dev/null | head -1)
        if [ -z "$BAK" ]; then
            echo "  跳过（无备份）：$T"
        else
            cp -a "$BAK" "$T"
            echo "  已还原 $T  ← $BAK"
        fi
    done

    echo
    echo "=== 还原候选条 / 幽灵矩形 $KBQML ==="
    KBAK=$(ls -1t "$KBQML".orig-* 2>/dev/null | head -1)
    if [ -z "$KBAK" ]; then
        echo "  找不到备份（$KBQML.orig-*），无法还原"
    else
        cp -a "$KBAK" "$KBQML"
        echo "  已从 $KBAK 还原"
    fi

    echo
    clear_qmlcache
    echo "  ★ 需要重启屏幕键盘才生效（KWin 会自己重新拉起）"
    exit 0
fi

echo "=== 1. 前置检查 ==="
if [ ! -f "$SRC" ]; then
    echo "  ✗ 找不到源文件 $SRC"
    exit 1
fi
echo "  ✓ 源 $SRC"
MISSING=0
for T in $(target_files); do
    if [ ! -f "$T" ]; then
        echo "  ✗ 缺失 $T"
        MISSING=1
    fi
done
[ "$MISSING" = 1 ] && { echo "  有目标文件缺失，中止（maliit-keyboard 装了吗？）"; exit 1; }
echo "  ✓ 全部 $(target_files | wc -l) 个布局文件都在（含基础布局 + 各变体）"
if [ ! -f "$KBQML" ]; then
    echo "  ✗ 找不到 $KBQML —— 候选条修复无法应用"
    exit 1
fi
echo "  ✓ 候选条文件 $KBQML"
if [ ! -f "$KBQML_SRC" ]; then
    echo "  ✗ 找不到 $KBQML_SRC"
    exit 1
fi
echo "  ✓ 候选条补丁源 $KBQML_SRC"

echo
echo "=== 2. 检查每个文件当前状态 ==="
NEED=0
for T in $(target_files); do
    if cmp -s "$SRC" "$T"; then
        printf "  %-70s 已一致\n" "$T"
    else
        printf "  %-70s 需安装（当前 %s 行）\n" "$T" "$(wc -l < "$T")"
        NEED=1
    fi
done
RIBBON_SAME=0
# ★★ 用**内容比对**判断，不能用"标记在不在" ★★
#
# 旧写法是 `grep -qF '改动 4/4' "$KBQML"` —— 只要文件里有这个标记就认为
# 装过了。于是后来往 Keyboard.qml 里追加的改动（底部给任务栏让位、
# 负高度夹取、KBGEO 诊断日志）**一个都没装进去**，而脚本还报"已装过，跳过"。
# 现在改成逐字节比对，源文件一改就会重装。
if cmp -s "$KBQML_SRC" "$KBQML"; then
    RIBBON_SAME=1
else
    RIBBON_SAME=0
fi
[ "$RIBBON_SAME" = 1 ] && echo "  Keyboard.qml 补丁已装" || { echo "  Keyboard.qml 补丁需要安装"; NEED=1; }

if [ "$NEED" = 0 ]; then
    echo
    echo "  全部已是目标状态，无需安装"
    exit 0
fi

echo
echo "=== 3. 备份原版（各只备份一次）==="
for T in $(target_files); do
    if ls -1 "$T".orig-* >/dev/null 2>&1; then
        echo "  已有备份，跳过：$T"
    else
        B="$T.orig-$(date +%Y%m%d-%H%M%S)"
        cp -a "$T" "$B"
        echo "  已备份 $B"
    fi
done
if ls -1 "$KBQML".orig-* >/dev/null 2>&1; then
    echo "  候选条已有备份，跳过：$(ls -1t "$KBQML".orig-* | head -1)"
else
    KB="$KBQML.orig-$(date +%Y%m%d-%H%M%S)"
    cp -a "$KBQML" "$KB"
    echo "  候选条已备份到 $KB"
fi

echo
echo "=== 4. 安装布局到全部变体 ==="
for T in $(target_files); do
    if cmp -s "$SRC" "$T"; then
        echo "  已一致，跳过 $T"
        continue
    fi
    cp -a "$SRC" "$T"
    chmod 644 "$T"
    echo "  已装 $T（$(wc -l < "$T") 行）"
done

echo
echo "=== 5. ★ 替换 Keyboard.qml（候选条占位 + 固定高度 + 收起不残留）==="
if [ "$RIBBON_SAME" = 1 ]; then
    echo "  已装过，跳过"
else
    cp -a "$KBQML_SRC" "$KBQML"
    chmod 644 "$KBQML"
    if cmp -s "$KBQML_SRC" "$KBQML"; then
        echo "  ✓ 已替换（$(wc -l < "$KBQML") 行）"
        grep -nE 'anchors.top: parent.top|^ *height: 44$|anchors.top: wordRibbon.bottom|MaliitGeometry.shown \? wordRibbon.y|Device.bottom_margin \+ 52|obj.height < 0' "$KBQML" \
            | sed 's/^/      /'
        echo "      (以上为命中)"
    else
        echo "  ✗ 替换后校验失败，请人工核对 $KBQML"
        exit 1
    fi
fi

echo
echo "=== 6. 校验 QML 语法（用 qmllint，有就查）==="
if command -v qmllint >/dev/null 2>&1; then
    for T in $(target_files); do
        qmllint "$T" 2>&1 | head -10 | sed 's/^/  /' || true
    done
    qmllint "$KBQML" 2>&1 | head -10 | sed 's/^/  /' || true
    echo "  (以上为命中)"
else
    echo "  没有 qmllint，跳过（装 qt6-declarative-dev-tools 可得到）"
fi

echo
echo "=== 7. 让新布局生效 ==="
clear_qmlcache
echo "  ★ KWin 会自己重新拉起 maliit，无需手工启动（手工起会造成双实例拖影）"
echo
echo "装好了。还原：sh $0 restore"

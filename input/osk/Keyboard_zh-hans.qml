/*
 * PC 风格布局 —— 给 maliit-keyboard 用的全尺寸键盘
 *
 * 装上它之后，中文拼音照常可用（拼音引擎由字母键驱动，与布局无关），
 * 但多了 PC 键盘的排布：顶部数字行、完整标点、等宽键位、行内居中。
 *
 * ★★ 为什么是 maliit 而不是上游的 droid-pc-keyboard ★★
 * 上游 droid-pc-keyboard 依赖 plasma-keyboard（Debian trixie 源里没有，
 * 得从源码编）+ Qt VirtualKeyboard 6.10.2（本机是 6.8.2，补丁要 rebase）。
 * 而 maliit 是容器里**已经装好并且能用**的屏幕键盘（用户已验证能弹、能打中文），
 * 它的布局就是纯 QML，改一个文件就能换布局。
 *
 * ★★ 本布局做不到什么（重要，别期待落空）★★
 * maliit 的按键模型是"提交文本"，不是"发键码"：
 *     CharKey 的属性 valueToSubmit = 键上的文字
 *     event_handler.onKeyReleased(valueToSubmit, action)
 * 全 QML 里**没有任何 Qt.Key_***。可用的 action 只有这几个：
 *     backspace / language / shift / return / space / symbols
 * 所以**没有 Tab / Esc / Ctrl / Alt / 方向键**，也没有真正的修饰键组合
 * （Ctrl+C 之类做不到）。
 *
 * 想要真功能键的话有两条路：
 *   1. 上游原方案：Qt VKB + plasma-keyboard + pc-keyd.py（uinput 注入真键码）。
 *      代价见上：要自编 plasma-keyboard 并把补丁 rebase 到 Qt VKB 6.8.2。
 *   2. 混合方案：本布局负责文字与拼音，另用 pc-keyd.py 的 HTTP 接口
 *      （127.0.0.1:48222/combo?key=<QtKey>&mods=…）在 QML 里用
 *      XMLHttpRequest 注入真键码。pc-keyd.py 是现成的，且 Gold 已在 input 组，
 *      /dev/uinput 可写。
 *
 * 布局设计要点：
 *   · 行内**不用** leftSide/rightSide —— 那两个属性会把键变成双宽。
 *     省略后所有键等宽，再靠 horizontalCenter 居中，得到 PC 那种错位排布。
 *   · 去掉字母键上的 extended（数字），因为顶部已有数字行，避免重复。
 *   · 拼音仍然有效：字母键照常提交字母，libpinyin 词库照常出候选。
 */

/*
 * ★★★ 为什么要写死键高（keyH）★★★
 *
 * 第一版布局照抄原版，让每个键用 CharKey 自己的 height: panel.keyHeight。
 * 实测这会造成**高度振荡**，键盘一闪一闪：
 *
 *     panel.keyHeight (C++) → 布局 implicitHeight → 窗口高度
 *         → panel 高度 (C++) → panel.keyHeight   ← 闭环
 *
 * maliit 靠迭代收敛来解这个环。发行版原版是 **4 行**，总高 438 逻辑像素，
 * 有余量，能收敛。我们的布局是 **5 行**（多了数字行），总高顶到上限；
 * 候选条（word ribbon）再占 9 像素，就收敛不了 —— 在 429 和 438 之间
 * 来回跳。实测高度序列：
 *
 *     原版：438 438 390 48 438 48 438        ← 干净两态
 *     5 行：48 438 429 438 48 438 429 438 …  ← 60 次里变了 59 次
 *
 * 429 与 438 差 9 像素，正好是候选条的高度。
 *
 * 修法：**给键高一个固定值**，让布局的 implicitHeight 不再依赖
 * panel.keyHeight，环就断了。代价是键盘高度不再随屏幕自适应 ——
 * 对固定分辨率的设备（3200x2000）这是可接受的，换来的是不再抖。
 *
 * keyH 取值依据：原版 4 行总高 438 ⇒ 约 109/行（含底行与 row_margin）。
 * 5 行要保持同样的总高，约 438/5 ≈ 87，取 86 留一点余量。
 */

import QtQuick 2.4

import MaliitKeyboard 2.0

import keys 1.0

KeyPad {
    anchors.fill: parent

    content: c1
    symbols: "languages/Keyboard_symbols_zh-hans.qml"

    // ★ 固定键高 —— 打断 panel.keyHeight 的循环依赖，消除高度振荡。
    //   想调键盘整体高度就改这一个值。
    readonly property int keyH: 86

    Column {
        id: c1
        anchors.fill: parent
        spacing: 0

        // ── 第 0 行：数字行（PC 键盘的标志性特征）────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "1"; shifted: "!"; height: keyH; }
            CharKey { label: "2"; shifted: "@"; height: keyH; }
            CharKey { label: "3"; shifted: "#"; height: keyH; }
            CharKey { label: "4"; shifted: "$"; height: keyH; }
            CharKey { label: "5"; shifted: "%"; height: keyH; }
            CharKey { label: "6"; shifted: "^"; height: keyH; }
            CharKey { label: "7"; shifted: "&"; height: keyH; }
            CharKey { label: "8"; shifted: "*"; height: keyH; }
            CharKey { label: "9"; shifted: "("; height: keyH; }
            CharKey { label: "0"; shifted: ")"; height: keyH; }
            CharKey { label: "-"; shifted: "_"; height: keyH; }
            CharKey { label: "="; shifted: "+"; height: keyH; }
            BackspaceKey { height: keyH; }
        }

        // ── 第 1 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "q"; shifted: "Q"; height: keyH; }
            CharKey { label: "w"; shifted: "W"; height: keyH; }
            CharKey { label: "e"; shifted: "E"; height: keyH; extended: ["ē", "é", "ě", "è"]; extendedShifted: ["Ē", "É", "Ě", "È"] }
            CharKey { label: "r"; shifted: "R"; height: keyH; }
            CharKey { label: "t"; shifted: "T"; height: keyH; }
            CharKey { label: "y"; shifted: "Y"; height: keyH; }
            CharKey { label: "u"; shifted: "U"; height: keyH; extended: ["ū", "ú", "ǔ", "ù"]; extendedShifted: ["Ū", "Ú", "Ǔ", "Ù"] }
            CharKey { label: "i"; shifted: "I"; height: keyH; extended: ["ī", "í", "ǐ", "ì"]; extendedShifted: ["Ī", "Í", "Ǐ", "Ì"] }
            CharKey { label: "o"; shifted: "O"; height: keyH; extended: ["ō", "ó", "ǒ", "ò"]; extendedShifted: ["Ō", "Ó", "Ǒ", "Ò"] }
            CharKey { label: "p"; shifted: "P"; height: keyH; }
            CharKey { label: "["; shifted: "{"; height: keyH; }
            CharKey { label: "]"; shifted: "}"; height: keyH; }
        }

        // ── 第 2 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "a"; shifted: "A"; height: keyH; extended: ["ā", "á", "ǎ", "à"]; extendedShifted: ["Ā", "Á", "Ǎ", "À"] }
            CharKey { label: "s"; shifted: "S"; height: keyH; }
            CharKey { label: "d"; shifted: "D"; height: keyH; }
            CharKey { label: "f"; shifted: "F"; height: keyH; }
            CharKey { label: "g"; shifted: "G"; height: keyH; }
            CharKey { label: "h"; shifted: "H"; height: keyH; }
            CharKey { label: "j"; shifted: "J"; height: keyH; }
            CharKey { label: "k"; shifted: "K"; height: keyH; }
            CharKey { label: "l"; shifted: "L"; height: keyH; }
            CharKey { label: ";"; shifted: ":"; height: keyH; }
            CharKey { label: "'"; shifted: "\""; height: keyH; }
            CharKey { label: "\\"; shifted: "|"; height: keyH; }
        }

        // ── 第 3 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            ShiftKey { height: keyH; }
            CharKey { label: "z"; shifted: "Z"; height: keyH; }
            CharKey { label: "x"; shifted: "X"; height: keyH; }
            CharKey { label: "c"; shifted: "C"; height: keyH; }
            CharKey { label: "v"; shifted: "V"; height: keyH; extended: ["ü", "ǖ", "ǘ", "ǚ", "ǜ"]; extendedShifted: ["Ü", "Ǖ", "Ǘ", "Ǚ", "Ǜ"] }
            CharKey { label: "b"; shifted: "B"; height: keyH; }
            CharKey { label: "n"; shifted: "N"; height: keyH; }
            CharKey { label: "m"; shifted: "M"; height: keyH; }
            CharKey { label: ","; shifted: "<"; height: keyH; }
            CharKey { label: "."; shifted: ">"; height: keyH; }
            CharKey { label: "/"; shifted: "?"; height: keyH; }
            ShiftKey { height: keyH; }
        }

        // ── 第 4 行：符号 / 语言 / 空格 / 回车 ────────────────
        Item {
            anchors.left: parent.left
            anchors.right: parent.right

            // ★ 同样固定高度，不再用 panel.keyHeight。
            //   原版这里是 panel.keyHeight + Device.row_margin，参与循环。
            height: keyH

            SymbolShiftKey { id: symShiftKey; label: "符号";              anchors.left: parent.left; height: parent.height; }
            LanguageKey    { id: languageMenuButton;                     anchors.left: symShiftKey.right; height: parent.height; }
            CharKey        { id: commaKey;    label: "，"; shifted: ",";  anchors.left: languageMenuButton.right; height: parent.height; }
            SpaceKey       { id: spaceKey;                               anchors.left: commaKey.right; anchors.right: dotKey.left; noMagnifier: true; height: parent.height; }
            CharKey        { id: dotKey;      label: "。"; shifted: "."; anchors.right: enterKey.left; height: parent.height; }
            ReturnKey      { id: enterKey;                               anchors.right: parent.right; height: parent.height; }
        }
    } // column
}

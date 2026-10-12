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

import QtQuick 2.4

import MaliitKeyboard 2.0

import keys 1.0

KeyPad {
    anchors.fill: parent

    content: c1
    symbols: "languages/Keyboard_symbols_zh-hans.qml"

    Column {
        id: c1
        anchors.fill: parent
        spacing: 0

        // ── 第 0 行：数字行（PC 键盘的标志性特征）────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "1"; shifted: "!"; }
            CharKey { label: "2"; shifted: "@"; }
            CharKey { label: "3"; shifted: "#"; }
            CharKey { label: "4"; shifted: "$"; }
            CharKey { label: "5"; shifted: "%"; }
            CharKey { label: "6"; shifted: "^"; }
            CharKey { label: "7"; shifted: "&"; }
            CharKey { label: "8"; shifted: "*"; }
            CharKey { label: "9"; shifted: "("; }
            CharKey { label: "0"; shifted: ")"; }
            CharKey { label: "-"; shifted: "_"; }
            CharKey { label: "="; shifted: "+"; }
            BackspaceKey {}
        }

        // ── 第 1 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "q"; shifted: "Q"; }
            CharKey { label: "w"; shifted: "W"; }
            CharKey { label: "e"; shifted: "E"; extended: ["ē", "é", "ě", "è"]; extendedShifted: ["Ē", "É", "Ě", "È"] }
            CharKey { label: "r"; shifted: "R"; }
            CharKey { label: "t"; shifted: "T"; }
            CharKey { label: "y"; shifted: "Y"; }
            CharKey { label: "u"; shifted: "U"; extended: ["ū", "ú", "ǔ", "ù"]; extendedShifted: ["Ū", "Ú", "Ǔ", "Ù"] }
            CharKey { label: "i"; shifted: "I"; extended: ["ī", "í", "ǐ", "ì"]; extendedShifted: ["Ī", "Í", "Ǐ", "Ì"] }
            CharKey { label: "o"; shifted: "O"; extended: ["ō", "ó", "ǒ", "ò"]; extendedShifted: ["Ō", "Ó", "Ǒ", "Ò"] }
            CharKey { label: "p"; shifted: "P"; }
            CharKey { label: "["; shifted: "{"; }
            CharKey { label: "]"; shifted: "}"; }
        }

        // ── 第 2 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            CharKey { label: "a"; shifted: "A"; extended: ["ā", "á", "ǎ", "à"]; extendedShifted: ["Ā", "Á", "Ǎ", "À"] }
            CharKey { label: "s"; shifted: "S"; }
            CharKey { label: "d"; shifted: "D"; }
            CharKey { label: "f"; shifted: "F"; }
            CharKey { label: "g"; shifted: "G"; }
            CharKey { label: "h"; shifted: "H"; }
            CharKey { label: "j"; shifted: "J"; }
            CharKey { label: "k"; shifted: "K"; }
            CharKey { label: "l"; shifted: "L"; }
            CharKey { label: ";"; shifted: ":"; }
            CharKey { label: "'"; shifted: "\""; }
            CharKey { label: "\\"; shifted: "|"; }
        }

        // ── 第 3 行 ──────────────────────────────────────────
        Row {
            anchors.horizontalCenter: parent.horizontalCenter;
            spacing: 0

            ShiftKey {}
            CharKey { label: "z"; shifted: "Z"; }
            CharKey { label: "x"; shifted: "X"; }
            CharKey { label: "c"; shifted: "C"; }
            CharKey { label: "v"; shifted: "V"; extended: ["ü", "ǖ", "ǘ", "ǚ", "ǜ"]; extendedShifted: ["Ü", "Ǖ", "Ǘ", "Ǚ", "Ǜ"] }
            CharKey { label: "b"; shifted: "B"; }
            CharKey { label: "n"; shifted: "N"; }
            CharKey { label: "m"; shifted: "M"; }
            CharKey { label: ","; shifted: "<"; }
            CharKey { label: "."; shifted: ">"; }
            CharKey { label: "/"; shifted: "?"; }
            ShiftKey {}
        }

        // ── 第 4 行：符号 / 语言 / 空格 / 回车 ────────────────
        Item {
            anchors.left: parent.left
            anchors.right: parent.right

            height: panel.keyHeight + Device.row_margin;

            SymbolShiftKey { id: symShiftKey; label: "符号";              anchors.left: parent.left; height: parent.height; }
            LanguageKey    { id: languageMenuButton;                     anchors.left: symShiftKey.right; height: parent.height; }
            CharKey        { id: commaKey;    label: "，"; shifted: ",";  anchors.left: languageMenuButton.right; height: parent.height; }
            SpaceKey       { id: spaceKey;                               anchors.left: commaKey.right; anchors.right: dotKey.left; noMagnifier: true; height: parent.height; }
            CharKey        { id: dotKey;      label: "。"; shifted: "."; anchors.right: enterKey.left; height: parent.height; }
            ReturnKey      { id: enterKey;                               anchors.right: parent.right; height: parent.height; }
        }
    } // column
}

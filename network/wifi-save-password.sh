#!/bin/sh
# network/wifi-save-password.sh —— 让 NetworkManager **自己**记住 WiFi 密码
#
# ══════════════════════════════════════════════════════════════════════
# 为什么需要它（"WiFi 密码保存失效"的根因）
# ══════════════════════════════════════════════════════════════════════
# NM 的密钥有两种保管方式，由连接文件里的 `psk-flags` 决定：
#
#   psk-flags=1  密钥交给**密钥代理**（KDE 上是 KWallet）
#   psk-flags=0  密钥由 **NM 自己**存在连接文件的 `psk=` 行里
#
# 本仓库原来的设计是 flags=1（这样图形界面会提示输密码）。
# 但实测（2026-10-13）本容器的 **KWallet 是坏的**：
#   · `kwallet6` 装了，但 `~/.local/share/kwalletd/` 里**一个钱包文件都没有**
#   · 任何 `busctl --user call org.kde.kwalletd6 …` 都让 kwalletd6
#     **SIGABRT**（`Call failed: Process org.kde.kwalletd6 received signal 6`）
#   · 所以代理根本没地方存密钥 —— plasma-nm 把密码拿到手、连上了，
#     然后**丢掉**。重启桌面后连接就因为"缺密钥"连不上，用户必须重输。
#
# ⇒ 结论：在 KWallet 修好之前，flags=1 这条路**结构性**不成立。
#   唯一能真正"保存"的办法是让 NM 自己保管（flags=0 + 文件里有 psk=）。
#
# ★ 注意：**只改 flags 不改文件会彻底弄坏连接**（2026-10-12 踩过）：
#   NM 既不去问代理、文件里又找不到密钥 ⇒ 永远连不上，而且图形界面
#   也不再提示输密码（NM 认为已经有了）。所以本脚本**必须**同时
#   写 psk 字面值，两步缺一不可。
#
# ══════════════════════════════════════════════════════════════════════
# 用法
# ══════════════════════════════════════════════════════════════════════
#   wifi-save-password              交互式（列连接 → 选一个 → 输密码）
#   wifi-save-password <连接名>     指定连接
#   wifi-save-password --check      只看现状，不改
#
# 触摸屏上从桌面图标「保存 WiFi 密码」进（konsole 里跑）。

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CFG_DIR=/etc/NetworkManager/system-connections

# ── 输出小工具 ─────────────────────────────────────────────
if [ -t 1 ]; then
    B=$(printf '\033[1m');  N=$(printf '\033[0m')
    G=$(printf '\033[1;32m'); Y=$(printf '\033[1;33m'); R=$(printf '\033[1;31m')
else
    B=; N=; G=; Y=; R=
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '%s✗%s %s\n' "$R" "$N" "$*"; }
head_() { printf '\n%s── %s ──%s\n' "$B" "$*" "$N"; }

# ── 现状 ───────────────────────────────────────────────────
show_state() {
    head_ "当前所有 WiFi 连接的密钥状态"
    _any=0
    for f in "$CFG_DIR"/*.nmconnection; do
        [ -f "$f" ] || continue
        _any=1
        _n=$(basename "$f" .nmconnection)
        _flags=$(grep -o '^psk-flags=.' "$f" 2>/dev/null | cut -d= -f2)
        if grep -q '^psk=' "$f" 2>/dev/null; then
            ok "$_n：文件里有 psk，psk-flags=${_flags:-未设置} → 重启不丢"
        else
            warn "$_n：文件里没有 psk，psk-flags=${_flags:-未设置} → 重启会丢"
        fi
    done
    [ "$_any" = 1 ] || say "（一个 WiFi 连接都没有）"

    head_ "KWallet 现状（代理这条路能不能用）"
    if [ -d "$HOME/.local/share/kwalletd" ] && \
       [ -n "$(ls -A "$HOME/.local/share/kwalletd" 2>/dev/null)" ]; then
        ok "有钱包文件：$(ls "$HOME/.local/share/kwalletd" | tr '\n' ' ')"
    else
        bad "没有钱包文件 —— 代理没地方存密钥（psk-flags=1 必然丢密码）"
    fi
}

# ── 挑连接 ─────────────────────────────────────────────────
pick_conn() {
    _list=""
    for f in "$CFG_DIR"/*.nmconnection; do
        [ -f "$f" ] || continue
        _list="$_list $(basename "$f" .nmconnection)"
    done
    if [ -z "$_list" ]; then
        bad "没有 WiFi 连接。先用桌面图标「连接 WiFi」连一次。"
        return 1
    fi
    # 优先挑**当前已激活**的那个 —— 它的密码就在 NM 内存里，最可能是用户想保存的
    _active=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
              | awk -F: '$2=="802-11-wireless"{print $1; exit}')
    if [ -n "$_active" ]; then
        say "当前激活的 WiFi：$_active"
        printf '就保存它吗？[Y/n] '
        read -r _a
        case "$_a" in [nN]*) ;; *) echo "$_active"; return 0 ;; esac
    fi
    say "可选的连接："
    _i=0
    for _c in $_list; do
        _i=$((_i + 1))
        say "  $_i) $_c"
    done
    printf '选一个（编号）：'
    read -r _sel
    case "$_sel" in
        ''|*[!0-9]*) bad "输入无效"; return 1 ;;
    esac
    _i=0
    for _c in $_list; do
        _i=$((_i + 1))
        [ "$_i" = "$_sel" ] && { echo "$_c"; return 0; }
    done
    bad "编号超出范围"
    return 1
}

# ── 保存 ───────────────────────────────────────────────────
do_save() {
    _c=$1
    head_ "保存「$_c」的密码"

    # ★ 先试 NM 内存里的（如果它现在正连着，密钥就在内存里，不用问用户）
    _psk=$(nmcli --show-secrets -g 802-11-wireless-security.psk connection show "$_c" 2>/dev/null)
    if [ -n "$_psk" ]; then
        ok "从 NM 内存里取到了密码（长度 ${#_psk}），不用重输"
    else
        say "NM 内存里没有这个密码（说明它现在没连着，或者已经被丢掉了）。"
        printf '请输入 WiFi 密码（不会回显）：'
        # stty 在 konsole 里可用；失败也不致命
        stty -echo 2>/dev/null
        read -r _psk
        stty echo 2>/dev/null
        printf '\n'
        if [ -z "$_psk" ]; then
            bad "密码为空，放弃"
            return 1
        fi
    fi

    # ★★ 顺序很重要，但 nmcli 的两次 modify 是原子的（NM 会一起落盘），
    #    所以这里先写 psk 再改 flags 也是安全的。反过来也安全。
    #    真正致命的是**只做其中一步**（见文件头）。
    head_ "写入连接文件"
    if ! nmcli connection modify "$_c" 802-11-wireless-security.psk "$_psk" 2>&1 | sed 's/^/  /'; then
        bad "写 psk 失败"
        return 1
    fi
    if ! nmcli connection modify "$_c" 802-11-wireless-security.psk-flags 0 2>&1 | sed 's/^/  /'; then
        bad "写 psk-flags 失败"
        return 1
    fi
    ok "nmcli 已接受"

    # ── 自证：真的落盘了吗（不是"命令返回 0"）─────────────
    head_ "自证"
    _f="$CFG_DIR/$_c.nmconnection"
    if [ -f "$_f" ]; then
        _flags=$(grep -o '^psk-flags=.' "$_f" | cut -d= -f2)
        if grep -q '^psk=' "$_f"; then
            ok "文件里有 psk= 了"
        else
            bad "文件里**没有** psk= —— 没落盘"
            return 1
        fi
        if [ "${_flags:-1}" = 0 ]; then
            ok "psk-flags=0（NM 自己保管）"
        else
            bad "psk-flags=${_flags:-未设置}，应该是 0"
            return 1
        fi
        say "  （权限 $(stat -c '%a %U:%G' "$_f" 2>/dev/null)，必须是 600）"
    else
        bad "找不到 $_f"
        return 1
    fi

    # 真的还能连上吗 —— 断开重连一次才算自证
    printf '\n要现在断开重连验证一次吗？（会短暂断网）[y/N] '
    read -r _a
    case "$_a" in
        [yY]*) ;;
        *) say "跳过验证。密码已经保存，下次开机 NM 会自己用上。"; return 0 ;;
    esac
    head_ "断开重连验证"
    nmcli connection down "$_c" >/dev/null 2>&1
    sleep 2
    if nmcli connection up "$_c" 2>&1 | sed 's/^/  /'; then
        ok "重连成功 —— 密码确实被 NM 保存并使用了"
    else
        bad "重连失败。密码可能不对，或者 AP 不在范围内。"
        return 1
    fi
}

# ── 入口 ───────────────────────────────────────────────────
case "${1:-}" in
    --check|-c)
        show_state
        exit 0
        ;;
    "" )
        show_state
        _c=$(pick_conn) || exit 1
        do_save "$_c"
        ;;
    * )
        do_save "$1"
        ;;
esac

printf '\n%s按回车关闭%s\n' "$Y" "$N"
read -r _

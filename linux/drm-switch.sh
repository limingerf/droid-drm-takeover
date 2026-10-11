#!/bin/sh
# linux/drm-switch.sh — Linux 侧应用（零依赖：POSIX sh + kdialog/zenity + .desktop）
#
# ══ 设计约束（按用户选定的方案）══
#   · 零依赖：不引入 PySide6 / GTK / Tauri。只用 shell + 系统里已有的
#     kdialog（KDE）或 zenity（GNOME/其它），两者都没有时退化为终端交互。
#   · 菜单项：配 drm-switch.desktop，由 install.sh 真正装进
#     /usr/share/applications 或 ~/.local/share/applications。
#     （参考仓库的 drm-exit.desktop 只被推到 /root/，**从来没进过菜单**，
#       所以"点按钮回安卓"在它的自动路径里其实是不存在的。）
#   · 回安卓 = 写请求文件，由安卓侧守护接手 → 停容器 → /system/bin/reboot。
#     与参考仓库完全一致（用户选定：只做整机重启，不做原地软恢复）。
#
# ══ 用法 ══
#   drm-switch.sh              打开图形界面（无图形则进终端菜单）
#   drm-switch.sh --text       强制终端菜单
#   drm-switch.sh status       只打印状态（脚本友好）
#   drm-switch.sh exit         不弹确认框，直接请求返回安卓
#   drm-switch.sh doctor       环境体检
#   drm-switch.sh install      装菜单项（等价于 install.sh）

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

DRM_SIDE=container
export DRM_SIDE

# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/common.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/device.sh"
drm_device_load 2>/dev/null || true

drm_state_init

# ── 与安卓侧的共享目录 ────────────────────────────────────
# 容器 /root ←→ 安卓 /mnt/Droidspaces/<容器>/root（唯一可靠共享的目录）
#
# ★ 绝对不要往容器 /data/local/tmp 写：它与安卓的 /data/local/tmp
#   **不是同一个目录**（参考仓库实测 inode 106504 vs 110）。
#   第一版就写错在那里 ⇒ 容器内"成功"、安卓侧永远看不见 ⇒ 按钮黑屏但不重启。
DRM_EXIT_REQ="/root/.drm-exit-request"
DRM_EXIT_LOG="/root/drm-exit.log"

# ── 通知后端探测 ──────────────────────────────────────────
GUI=""
drm_gui_detect() {
    if [ -n "${DRM_FORCE_TEXT:-}" ]; then
        GUI=""
        return 1
    fi
    if command -v kdialog >/dev/null 2>&1; then
        GUI=kdialog
        return 0
    fi
    if command -v zenity >/dev/null 2>&1; then
        GUI=zenity
        return 0
    fi
    GUI=""
    return 1
}

# 确认框：返回 0 = 用户点了"确定"
drm_confirm() {
    _title=$1
    _text=$2
    case "$GUI" in
        kdialog) kdialog --title "$_title" --warningyesno "$_text" ;;
        zenity)  zenity --title "$_title" --question --text "$_text" ;;
        *)       printf '%s [y/N] ' "$_text" >&2; read -r _a; [ "$_a" = y ] || [ "$_a" = Y ] ;;
    esac
}

drm_msg() {
    _title=$1
    _text=$2
    case "$GUI" in
        kdialog) kdialog --title "$_title" --msgbox "$_text" ;;
        zenity)  zenity --title "$_title" --info --text "$_text" ;;
        *)       printf '\n%s\n%s\n' "$_title" "$_text" >&2 ;;
    esac
}

drm_errbox() {
    _title=$1
    _text=$2
    case "$GUI" in
        kdialog) kdialog --title "$_title" --error "$_text" ;;
        zenity)  zenity --title "$_title" --error --text "$_text" ;;
        *)       printf '\n[错误] %s\n%s\n' "$_title" "$_text" >&2 ;;
    esac
}

# 菜单：返回选中项的 key（空 = 取消）
drm_menu() {
    _title=$1
    shift
    case "$GUI" in
        kdialog)
            # kdialog --menu 需要 "tag" "label" 成对
            kdialog --title "$_title" --menu "$_title" "$@" 2>/dev/null
            ;;
        zenity)
            _cols=""
            for _kv in "$@"; do
                _cols="$_cols FALSE"
            done
            # zenity 用 --list --column；这里简化成逐项选择
            zenity --title "$_title" --list --column 操作 "$@" 2>/dev/null
            ;;
        *)
            printf '\n%s\n' "$_title" >&2
            _i=1
            for _kv in "$@"; do
                _lbl=$_kv
                printf '  %d) %s\n' "$_i" "$_lbl" >&2
                _i=$((_i + 1))
            done
            printf '选择 [1-%d，回车取消]: ' "$((_i - 1))" >&2
            read -r _n
            [ -n "$_n" ] || return 1
            _i=1
            for _kv in "$@"; do
                [ "$_i" = "$_n" ] && { printf '%s\n' "$_kv"; return 0; }
                _i=$((_i + 1))
            done
            return 1
            ;;
    esac
}

# ── 状态文本 ──────────────────────────────────────────────
drm_status_text() {
    _ph=$(drm_state_phase)
    _case=""
    case "$_ph" in
        linux-active)  _case="Linux 桌面运行中（屏幕由 KWin 持有）" ;;
        android-active) _case="安卓运行中（未接管）" ;;
        entering)      _case="正在进入 Linux…" ;;
        returning)     _case="正在返回安卓…" ;;
        error)         _case="上一轮出错，需要处理" ;;
        *)             _case="未知状态（$_ph）" ;;
    esac

    printf '%s\n\n' "$_case"
    printf '设备      : %s\n' "${DEV_MODEL:-未知}"
    printf '阶段      : %s\n' "$_ph"
    printf '开始于    : %s\n' "$(drm_state_get SINCE 2>/dev/null || echo -)"
    printf '阶段时间  : %s\n' "$(drm_state_get PHASE_AT 2>/dev/null || echo -)"
    printf 'kwin 持DRM: %s\n' "$(drm_state_get KWIN_HOLDS_DRM 2>/dev/null || echo -)"
    printf 'plasmashell: %s\n' "$(drm_state_get PLASMA_OK 2>/dev/null || echo -)"
    printf '网络出口  : %s\n' "$(drm_state_get NET_OK 2>/dev/null || echo -)"
    printf '上次错误  : %s\n' "$(drm_state_get LAST_ERROR 2>/dev/null || echo -)"
    printf '\n合成器    : %s\n' "$(drm_pids_by_comm kwin_wayland | tr '\n' ' ')"
    printf '桌面      : %s\n' "$(drm_pids_by_comm plasmashell | tr '\n' ' ')"
    printf '安卓守护  : %s\n' "$(if [ -f /root/.drm-watch-alive ]; then echo 在跑; else echo 未确认; fi)"
}

# ── 返回安卓 ──────────────────────────────────────────────
cmd_exit() {
    _ask=${1:-1}

    if [ "$_ask" = 1 ]; then
        drm_confirm "返回安卓" \
"确定要返回安卓吗？

设备将**重启**，大约需要 1 分钟。
这是参考实现验证过的唯一干净路径：
容器启动会破坏安卓的 ueventd netlink，
原地恢复会留下半死状态（USB/pogo 键盘不认、不定时重启）。

现在保存好你的工作。" || { drm_log "用户取消"; return 0; }
    fi

    drm_log "用户请求返回安卓"
    # 写请求文件（容器 /root ←→ 安卓共享目录）
    if ! touch "$DRM_EXIT_REQ" 2>/dev/null; then
        drm_errbox "无法通知安卓侧" \
"写不进 $DRM_EXIT_REQ。

可能原因：
· 安卓侧的返回守护没有运行
· 共享目录没挂上

请在安卓侧执行一次：
  su -c 'sh /data/local/drm-takeover/android/exit-watch.sh &'"
        return 1
    fi

    # 留一条日志给安卓侧（可选）
    {
        printf '[%s] 用户在 Linux 桌面请求返回安卓\n' "$(drm_ts)"
    } >>"$DRM_EXIT_LOG" 2>/dev/null

    drm_msg "正在返回安卓" \
"已通知安卓侧，设备即将重启。

如果 30 秒内没有任何反应，说明安卓侧的守护没在跑。
此时可以长按电源键强制重启（这个逃生阀我们从不拦截）。"

    # 杀掉桌面栈，让画面尽快切走（安卓侧守护会在 1s 内接手）
    ( sleep 1
      drm_kill_by_comm 9 plasmashell
      drm_kill_by_comm 9 kwin_wayland
    ) &
    return 0
}

# ── 主菜单 ────────────────────────────────────────────────
cmd_menu() {
    drm_gui_detect || drm_log "没有 kdialog/zenity，使用终端菜单"

    while :; do
        _sel=$(drm_menu "droid-drm-takeover" \
            "返回安卓（重启设备）" \
            "查看状态" \
            "环境体检" \
            "重启桌面（只重启 KWin，不碰安卓）" \
            "打开日志目录" \
            "退出") || return 0

        case "$_sel" in
            "返回安卓（重启设备）")
                cmd_exit 1
                return 0
                ;;
            "查看状态")
                drm_msg "当前状态" "$(drm_status_text)"
                ;;
            "环境体检")
                _out=$("$DRM_ROOT/core/switch.sh" doctor 2>&1)
                drm_msg "环境体检" "$_out"
                ;;
            "重启桌面（只重启 KWin，不碰安卓）")
                drm_confirm "重启桌面" "只重启容器侧的 KWin 与桌面，不碰安卓。继续？" || continue
                if [ -x "$DRM_ROOT/display/kwin-restart.sh" ]; then
                    sh "$DRM_ROOT/display/kwin-restart.sh" >/dev/null 2>&1 &
                    drm_msg "已触发" "桌面正在重启，几秒后应恢复。"
                else
                    drm_errbox "缺脚本" "找不到 display/kwin-restart.sh"
                fi
                ;;
            "打开日志目录")
                if command -v xdg-open >/dev/null 2>&1; then
                    xdg-open "$DRM_LOG_DIR" >/dev/null 2>&1 &
                else
                    drm_msg "日志目录" "$DRM_LOG_DIR"
                fi
                ;;
            "退出")
                return 0
                ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────
case "${1:-}" in
    --text)  DRM_FORCE_TEXT=1; shift; cmd_menu ;;
    status)  shift; drm_status_text; exit 0 ;;
    exit)    shift; cmd_exit 0 ;;
    doctor)  shift; exec "$DRM_ROOT/core/switch.sh" doctor "$@" ;;
    menu|--gui|'') cmd_menu ;;
    install) shift; exec sh "$SELF_DIR/install.sh" "$@" ;;
    -h|--help)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) drm_err "未知参数：$1"; exit 2 ;;
esac

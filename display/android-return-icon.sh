#!/bin/sh
# display/android-return-icon.sh —— 装桌面「返回安卓」快捷方式（安卓机器人图标）
#
# ══════════════════════════════════════════════════════════════════════
# 装了什么
# ══════════════════════════════════════════════════════════════════════
#   ① /usr/share/icons/hicolor/scalable/apps/android-robot.svg
#        经典安卓机器人图标（本仓库自己画的，主题里没有，见该文件注释）
#   ② /usr/local/bin/return-to-android
#        用户级启动器（display/return-to-android.sh）。**不需要 root** ——
#        它只往 1777 的会合目录写一个 exit.request，重启由安卓侧守护做。
#   ③ /usr/share/applications/android-return.desktop   （应用菜单里也有一份）
#   ④ ~/Desktop/返回安卓.desktop                        （桌面图标，用户要的就是这个）
#
# ══════════════════════════════════════════════════════════════════════
# 为什么桌面图标要 755 且属主是桌面用户
# ══════════════════════════════════════════════════════════════════════
# KDE 的 Folder View 把 ~/Desktop 下的 .desktop 当**快捷方式**；
# 没有可执行位、或者属主不是当前用户时，会显示成"未信任的快捷方式"
# （图标上带个问号，双击弹确认框）。参考仓库和本项目实测都踩过，
# 所以这里 chmod 755 + chown。
#
# ══════════════════════════════════════════════════════════════════════
# 用法
# ══════════════════════════════════════════════════════════════════════
#   sh display/android-return-icon.sh            装上（幂等）
#   sh display/android-return-icon.sh --check    只看现状
#   sh display/android-return-icon.sh --remove   撤掉（只删本脚本装的东西）

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
# shellcheck source=/dev/null
. "$SELF_DIR/../core/lib/boot.sh"

SVG_SRC="$SELF_DIR/android-robot.svg"
LAUNCHER_SRC="$SELF_DIR/return-to-android.sh"

SVG_DST=/usr/share/icons/hicolor/scalable/apps/android-robot.svg
LAUNCHER_DST=/usr/local/bin/return-to-android
DESKTOP_DST=/usr/share/applications/android-return.desktop
ICON_PATH=/usr/share/icons/hicolor/scalable/apps/android-robot.svg

# 桌面文件名用中文 —— 用户要的是中文界面。
# ★ 这里用 printf 写，不用 heredoc，避免不同 shell 对 heredoc 里
#   非 ASCII 的处理差异；编码就是脚本文件本身的 UTF-8。
DESKTOP_NAME='返回安卓'

desktop_body() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=$DESKTOP_NAME
Name[en]=Return to Android
Comment=停掉容器并整机重启，回到安卓
Comment[en]=Stop the container and reboot into Android
Exec=$LAUNCHER_DST
Icon=$ICON_PATH
Terminal=false
Categories=System;
StartupNotify=false
EOF
}

# ── 装 ─────────────────────────────────────────────────────
ai_install() {
    drm_desktop_user_resolve
    _uhome=${DESKTOP_HOME:-/home/${DEV_USER:-Gold}}
    _u=${DESKTOP_USER:-${DEV_USER:-Gold}}

    drm_phase "① 装图标"
    if [ ! -f "$SVG_SRC" ]; then
        drm_warn "找不到 $SVG_SRC"
        return 1
    fi
    mkdir -p "$(dirname "$SVG_DST")" || return 1
    cp -f "$SVG_SRC" "$SVG_DST" || { drm_warn "写 $SVG_DST 失败"; return 1; }
    chmod 644 "$SVG_DST"
    drm_log "  $SVG_DST"

    drm_phase "② 装启动器"
    if [ ! -f "$LAUNCHER_SRC" ]; then
        drm_warn "找不到 $LAUNCHER_SRC"
        return 1
    fi
    cp -f "$LAUNCHER_SRC" "$LAUNCHER_DST" || { drm_warn "写 $LAUNCHER_DST 失败"; return 1; }
    chmod 755 "$LAUNCHER_DST"
    drm_log "  $LAUNCHER_DST（用户级，无需 root）"

    drm_phase "③ 装 .desktop（应用菜单 + 桌面）"
    desktop_body >"$DESKTOP_DST" || { drm_warn "写 $DESKTOP_DST 失败"; return 1; }
    chmod 644 "$DESKTOP_DST"

    _ddir="$_uhome/Desktop"
    mkdir -p "$_ddir" || { drm_warn "建不出 $_ddir"; return 1; }
    desktop_body >"$_ddir/$DESKTOP_NAME.desktop" || { drm_warn "写桌面图标失败"; return 1; }
    # ★ 755 + chown：见文件头"为什么桌面图标要 755"
    chmod 755 "$_ddir/$DESKTOP_NAME.desktop"
    chown "$_u:$_u" "$_ddir/$DESKTOP_NAME.desktop" 2>/dev/null
    drm_log "  $DESKTOP_DST"
    drm_log "  $_ddir/$DESKTOP_NAME.desktop"

    # 桌面图标要被 KDE 认成"已信任"，还要在 .directory / 信任库里登记。
    # 实测：只要可执行位 + 属主对，Folder View 就直接显示成正常图标，
    # 不需要额外登记。这里只刷新一下应用菜单缓存。
    drm_phase "④ 刷新应用菜单缓存"
    drm_have kbuildsycoca6 && {
        runuser -u "$_u" -- env HOME="$_uhome" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            LANG=en_US.UTF-8 XDG_MENU_PREFIX=plasma- \
            kbuildsycoca6 --noincremental >/dev/null 2>&1
        drm_log "  已刷新"
    } || drm_log "  没有 kbuildsycoca6，跳过（桌面图标不受影响）"
}

# ── 自证 ───────────────────────────────────────────────────
ai_check() {
    drm_desktop_user_resolve
    _uhome=${DESKTOP_HOME:-/home/${DEV_USER:-Gold}}

    drm_phase "自证"
    for f in "$SVG_DST" "$LAUNCHER_DST" "$DESKTOP_DST" \
             "$_uhome/Desktop/$DESKTOP_NAME.desktop"; do
        if [ -e "$f" ]; then
            drm_log "  ✓ $f"
        else
            drm_warn "  ✗ $f 不存在"
        fi
    done

    # 启动器真的能用吗 —— 功能性判据，不是"文件在不在"
    if [ -x "$LAUNCHER_DST" ]; then
        _o=$("$LAUNCHER_DST" --check 2>&1)
        printf '%s\n' "$_o" | while IFS= read -r _l; do drm_log "    $_l"; done
        case "$_o" in
            *"在听"*) drm_log "  ✓ 安卓侧守护在听 —— 图标点了会真的重启" ;;
            *)        drm_warn "  ✗ 守护没在听 —— 图标点了不会重启（见上面提示）" ;;
        esac
    fi

    # 桌面图标权限（KDE 会因此显示"未信任"）
    _d="$_uhome/Desktop/$DESKTOP_NAME.desktop"
    if [ -e "$_d" ]; then
        _p=$(stat -c '%a %U:%G' "$_d" 2>/dev/null)
        drm_log "  桌面图标权限 = $_p（要 755 且属主是桌面用户）"
    fi
}

# ── 撤 ─────────────────────────────────────────────────────
ai_remove() {
    drm_desktop_user_resolve
    _uhome=${DESKTOP_HOME:-/home/${DEV_USER:-Gold}}
    drm_phase "撤销"
    rm -f "$DESKTOP_DST" "$LAUNCHER_DST" "$SVG_DST" \
          "$_uhome/Desktop/$DESKTOP_NAME.desktop"
    drm_log "已删掉本脚本装的东西（KWin/显示栈不受影响）"
}

# ── 入口 ───────────────────────────────────────────────────
case "${1:-install}" in
    install|--install) ai_install; ai_check ;;
    check|--check)     ai_check ;;
    remove|--remove)   ai_remove ;;
    *)
        echo "用法: sh $0 [install|--check|--remove]" >&2
        exit 2
        ;;
esac

#!/bin/sh
# linux/install.sh — 把 Linux 侧应用真正装进系统（含菜单项）。
#
# ══ 为什么需要它 ══
# 参考仓库的 ade/drm-exit.desktop 只被 deploy-ade.sh 推到容器 /root/，
# 仓库里**没有任何脚本**把它 install 到 /usr/share/applications 或
# ~/.local/share/applications。结果：全自动路径下 KDE 菜单里根本没有
# "重启回安卓"这一项，用户只能敲命令。这里补上这一步。
#
# ══ 用法 ══
#   sh install.sh              装到 /opt/droid-drm-takeover + 当前用户菜单
#   sh install.sh --system     装到 /usr/share/applications（所有用户，需 root）
#   sh install.sh --prefix DIR 自定义安装目录
#   sh install.sh --uninstall  卸载
#
# ══ 装什么 ══
#   $PREFIX/               仓库本体（core/ linux/ display/ tools/ bin/ ...）
#   /usr/local/bin/drm-switch   启动器 wrapper
#   <applications>/drm-switch.desktop   菜单项
#   <icons>/drm-switch.png      图标

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

PREFIX=${PREFIX:-/opt/droid-drm-takeover}
SYSTEM=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --system)    SYSTEM=1 ;;
        --prefix)    shift; PREFIX=$1 ;;
        --prefix=*)  PREFIX=${1#--prefix=} ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$SYSTEM" = 1 ]; then
    APP_DIR=/usr/share/applications
    ICON_DIR=/usr/share/icons/hicolor/256x256/apps
    BIN_DIR=/usr/local/bin
else
    APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    BIN_DIR="$HOME/.local/bin"
    # 非 --system 时若没有写权限，回退到用户目录
    [ -w "$PREFIX" ] 2>/dev/null || true
fi

say() { printf '%s\n' "$*"; }

if [ "$UNINSTALL" = 1 ]; then
    say "卸载："
    rm -f "$APP_DIR/drm-switch.desktop" && say "  删除 $APP_DIR/drm-switch.desktop"
    rm -f "$ICON_DIR/drm-switch.png"    && say "  删除 $ICON_DIR/drm-switch.png"
    rm -f "$BIN_DIR/drm-switch"         && say "  删除 $BIN_DIR/drm-switch"
    if [ -d "$PREFIX" ]; then
        rm -rf "$PREFIX" && say "  删除 $PREFIX"
    fi
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" 2>/dev/null
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1
    say "完成"
    exit 0
fi

# ── 1) 复制仓库本体 ───────────────────────────────────────
say "安装到 $PREFIX"
mkdir -p "$PREFIX" || { say "无法创建 $PREFIX（加 --prefix 换个位置，或用 sudo）"; exit 1; }

for d in core linux display tools configs docs; do
    [ -d "$DRM_ROOT/$d" ] || continue
    rm -rf "$PREFIX/$d"
    cp -R "$DRM_ROOT/$d" "$PREFIX/" || exit 1
    say "  $d/"
done
for f in Makefile README.md LICENSE; do
    [ -f "$DRM_ROOT/$f" ] && cp "$DRM_ROOT/$f" "$PREFIX/" 2>/dev/null
done
# bin/ 若已编译一并带上（没编译就让用户在容器里 make）
if [ -d "$DRM_ROOT/bin" ]; then
    rm -rf "$PREFIX/bin"
    cp -R "$DRM_ROOT/bin" "$PREFIX/" 2>/dev/null
    say "  bin/ ($(ls "$DRM_ROOT/bin" 2>/dev/null | wc -l) 个产物)"
else
    say "  ⚠️ 没有 bin/ —— 请在容器里先 make（否则 kwinwrap 等工具缺失）"
fi

# 可执行位：脚本一律 `sh <路径>` 调用，严格说不需要 x 位；
# 但 bin/ 下的产物是**被直接 exec** 的（kwinwrap / setbright / setprop），
# 少一个 x 位就会 "Permission denied"。
# 一次性给全树 .sh 加 x，比逐个目录列举可靠（原来漏了 core/lib、core/device、
# linux/session-up.sh、android/*.sh）。
find "$PREFIX" -name '*.sh' -type f -exec chmod 755 {} + 2>/dev/null
if [ -d "$PREFIX/bin" ]; then
    find "$PREFIX/bin" -type f -exec chmod 755 {} + 2>/dev/null
fi

# ── 2) 启动器 wrapper ─────────────────────────────────────
mkdir -p "$BIN_DIR" 2>/dev/null
cat >"$BIN_DIR/drm-switch" <<EOF
#!/bin/sh
# 由 droid-drm-takeover 的 install.sh 生成
exec sh "$PREFIX/linux/drm-switch.sh" "\$@"
EOF
chmod +x "$BIN_DIR/drm-switch"
say "  $BIN_DIR/drm-switch"

# ── 3) 菜单项 ─────────────────────────────────────────────
mkdir -p "$APP_DIR" 2>/dev/null
sed "s|^Exec=.*|Exec=$BIN_DIR/drm-switch|" \
    "$DRM_ROOT/linux/drm-switch.desktop" >"$APP_DIR/drm-switch.desktop"
say "  $APP_DIR/drm-switch.desktop"

# ── 4) 图标 ───────────────────────────────────────────────
# 没有自带图标文件时生成一个最小的：画一个"返回"箭头。
# 用纯文本 SVG（不需要任何图形库）。
mkdir -p "$ICON_DIR" 2>/dev/null
if [ -f "$DRM_ROOT/linux/drm-switch.svg" ]; then
    cp "$DRM_ROOT/linux/drm-switch.svg" "$ICON_DIR/drm-switch.svg" 2>/dev/null
fi
cat >"$ICON_DIR/drm-switch.svg" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="48" fill="#1b1f2a"/>
  <path d="M40 92h108a44 44 0 0 1 0 88H84" fill="none" stroke="#4da3ff"
        stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M78 56 40 92l38 36" fill="none" stroke="#4da3ff"
        stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="196" cy="196" r="16" fill="#3ddc84"/>
</svg>
SVG
say "  $ICON_DIR/drm-switch.svg"

# ── 5) 刷新缓存 ───────────────────────────────────────────
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" 2>/dev/null
# KDE 需要重建 sycoca 才能在菜单里看到新项
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1
command -v kbuildsycoca5 >/dev/null 2>&1 && kbuildsycoca5 --noincremental >/dev/null 2>&1

say ""
say "安装完成。"
say "  · 菜单里找「返回安卓」，或直接跑： drm-switch"
say "  · 若菜单里没有，注销再登录一次（KDE 的 sycoca 缓存）"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "  · 注意 $BIN_DIR 不在 PATH 里，请用完整路径 $BIN_DIR/drm-switch" ;;
esac

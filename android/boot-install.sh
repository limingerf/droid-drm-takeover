#!/system/bin/sh
# android/boot-install.sh — 把"接管守护"装成开机自启。
#
# ★ 这一步在参考仓库里**必须人工做一次**（它的 deploy-ade.sh 只把
#   drm-exit-boot.sh 推到 /data/local/tmp，装到自启位置要用户手敲命令）。
#   不装它 ⇒ 重启后守护没在跑 ⇒ 容器里那个"进入 Linux / 返回安卓"按钮
#   点了没反应。本脚本把它做成一条命令。
#
# ══ 为什么是 KernelSU 模块，而不是 /data/adb/service.d/ ══
# 实测（本机 KernelSU 4.2.0-72-g223897c7, uapi 5）：
#   /data/adb/service.d/99-drm-exit-watch.sh 装好、755、重启后**完全没有被执行**，
#   /data/adb/ksu/ 下也没有 service.d 目录，ksu 日志里连痕迹都没有。
# 而同机 /data/adb/modules/droidspaces/service.sh 是被正常执行的
#   （Droidspaces 的守护与容器自启就是靠它）。
# 所以主路径改成 KernelSU 模块；service.d 仍然装一份，
# 那是 Magisk 与部分 KernelSU 版本认的路径，装了不亏。
#
# 用法:
#   su -c 'sh .../android/boot-install.sh install'
#   su -c 'sh .../android/boot-install.sh uninstall'
#   su -c 'sh .../android/boot-install.sh status'

set -u

# ★ payload 根是 /data/local/drm-takeover（root:root），不是 /data/local/tmp
#   —— 这里会以 root 执行 payload 里的脚本，放 tmp 等于给 shell 用户留后门。
DRM_PAYLOAD=${DRM_PAYLOAD:-/data/local/drm-takeover}
MOD_ID=drm-takeover-exit-watch
MOD_DIR=/data/adb/modules/$MOD_ID
HOOK=/data/adb/service.d/99-drm-exit-watch.sh

# 等 payload 就绪的公共片段（init 早期 /data 可能还没挂上）
_wait_payload() {
    cat <<'EOF'
i=0
while [ $i -lt 60 ]; do
    [ -d "$DRM_PAYLOAD" ] && break
    sleep 1
    i=$((i+1))
done
[ -d "$DRM_PAYLOAD" ] || exit 0
EOF
}

_install_module() {
    mkdir -p "$MOD_DIR" || { echo "无法创建 $MOD_DIR" >&2; return 1; }

    cat >"$MOD_DIR/module.prop" <<EOF
id=$MOD_ID
name=droid-drm-takeover 接管守护
version=1.0
versionCode=1
author=limingerf
description=开机拉起"进入 Linux / 返回安卓"守护。容器里的按钮依赖它；不装则重启后按钮无反应。
EOF

    # ★ 不能用 `setsid nohup ... &` 之后立刻退出 —— 父进程退出会连坐。
    #   service.sh 由 KernelSU 在 late_start 执行，直接前台跑即可。
    # ★ 日志必须落盘：service.sh 的 stdout 被 KernelSU 吃掉，
    #   不落盘的话"模块没跑"和"模块跑了但守护自己退了"根本分不清
    #   （这个坑实际踩过：对着空日志猜了两轮）。
    cat >"$MOD_DIR/service.sh" <<EOF
#!/system/bin/sh
# 由 droid-drm-takeover 的 boot-install.sh 生成
DRM_PAYLOAD=$DRM_PAYLOAD
export DRM_PAYLOAD
export PATH=/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/sbin:/bin:\$PATH

mkdir -p "\$DRM_PAYLOAD/logs" 2>/dev/null
exec >>"\$DRM_PAYLOAD/logs/boot-autostart.log" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] service.sh 被触发（uid=\$(id -u)）"

$(_wait_payload)
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] payload 就绪，拉起守护"
exec sh "\$DRM_PAYLOAD/android/exit-watch.sh" run
EOF
    chmod 755 "$MOD_DIR/service.sh"
    chmod 644 "$MOD_DIR/module.prop"
    echo "已安装模块：$MOD_DIR"
}

_install_hook() {
    mkdir -p /data/adb/service.d 2>/dev/null || return 1
    cat >"$HOOK" <<EOF
#!/system/bin/sh
# 由 droid-drm-takeover 的 boot-install.sh 生成（Magisk / 部分 KernelSU 认这条路径）
DRM_PAYLOAD=$DRM_PAYLOAD
export DRM_PAYLOAD
export PATH=/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/sbin:/bin:\$PATH

$(_wait_payload)

exec sh "\$DRM_PAYLOAD/android/exit-watch.sh" run
EOF
    chmod 755 "$HOOK"
    echo "已安装 service.d hook：$HOOK"
}

case "${1:-status}" in
    install)
        if [ ! -d /data/adb ]; then
            echo "没有 /data/adb —— 设备没有 KernelSU/Magisk，跳过" >&2
            echo "（这种情况下请在 APK 里保持「接管守护」开启）" >&2
            exit 1
        fi
        _install_module || exit 1
        _install_hook || echo "（service.d 装不上，不影响：模块那条路径才是本机生效的）" >&2
        echo
        echo "下次开机自动拉起守护。"
        echo "（现在想立刻生效：sh $DRM_PAYLOAD/android/exit-watch.sh start）"
        ;;
    uninstall)
        rm -rf "$MOD_DIR" && echo "已删除模块 $MOD_DIR" || echo "模块本来就没有"
        rm -f "$HOOK" && echo "已删除 $HOOK" || echo "hook 本来就没有"
        ;;
    status)
        _ok=1
        if [ -f "$MOD_DIR/service.sh" ]; then
            echo "模块已安装：$MOD_DIR"
            ls -l "$MOD_DIR"
        else
            echo "模块未安装（本机 KernelSU 靠这条路径，装它才有用）"
            _ok=0
        fi
        if [ -f "$HOOK" ]; then
            echo "service.d hook 已安装：$HOOK"
        else
            echo "service.d hook 未安装"
        fi
        [ "$_ok" = 1 ] || exit 1
        ;;
    *)
        echo "用法: $0 {install|uninstall|status}" >&2
        exit 2
        ;;
esac

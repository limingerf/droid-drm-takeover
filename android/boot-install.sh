#!/system/bin/sh
# android/boot-install.sh — 把"返回安卓"守护装成开机自启。
#
# ★ 这一步在参考仓库里**必须人工做一次**（它的 deploy-ade.sh 只把
#   drm-exit-boot.sh 推到 /data/local/tmp，装到 service.d 要用户手敲命令）。
#   不装它 ⇒ 重启后守护没在跑 ⇒ 容器里那个"返回安卓"按钮点了没反应。
#   本脚本把它做成一条命令。
#
# 用法:
#   su -c 'sh .../android/boot-install.sh install'
#   su -c 'sh .../android/boot-install.sh uninstall'
#   su -c 'sh .../android/boot-install.sh status'
#
# 支持三种自启位置，按存在性自动选：
#   1. KernelSU  /data/adb/service.d/     （本机在用）
#   2. Magisk    /data/adb/service.d/     （同一路径，Magisk 也认）
#   3. 无 root 方案：什么都不装（守护由 APK 前台服务托管）

set -u

# ★ payload 根是 /data/local/drm-takeover（0711 root:root），不是
#   /data/local/tmp —— 这里会以 root 执行 payload 里的脚本。
DRM_PAYLOAD=${DRM_PAYLOAD:-/data/local/drm-takeover}
HOOK=/data/adb/service.d/99-drm-exit-watch.sh

case "${1:-status}" in
    install)
        if [ ! -d /data/adb ]; then
            echo "没有 /data/adb —— 设备没有 KernelSU/Magisk，跳过" >&2
            echo "（这种情况下请在 APK 里保持「返回守护」开启）" >&2
            exit 1
        fi
        mkdir -p /data/adb/service.d || { echo "无法创建 /data/adb/service.d" >&2; exit 1; }

        cat >"$HOOK" <<EOF
#!/system/bin/sh
# 由 droid-drm-takeover 的 boot-install.sh 生成
# 作用：开机把「返回安卓」守护拉起来（容器里的按钮依赖它）
DRM_PAYLOAD=$DRM_PAYLOAD
export PATH=/data/adb/ksu/bin:/data/adb/magisk:/system/bin:/sbin:/bin:\$PATH

# 等 /data 与 payload 目录就绪（init 早期 /data 可能还没挂上）
i=0
while [ \$i -lt 60 ]; do
    [ -d "\$DRM_PAYLOAD" ] && break
    sleep 1
    i=\$((i+1))
done
[ -d "\$DRM_PAYLOAD" ] || exit 0

# 不要用 setsid nohup ... & 后立刻退出——service.d 的父进程退出会连坐。
# 这里直接前台跑，由 init 的 service 机制托管。
exec sh "\$DRM_PAYLOAD/android/exit-watch.sh" run
EOF
        chmod 755 "$HOOK"
        echo "已安装：$HOOK"
        echo "下次开机自动拉起返回守护。"
        echo "（现在想立刻生效：sh $DRM_PAYLOAD/android/exit-watch.sh start）"
        ;;
    uninstall)
        rm -f "$HOOK" && echo "已删除 $HOOK" || echo "本来就没有"
        ;;
    status)
        if [ -f "$HOOK" ]; then
            echo "已安装：$HOOK"
            ls -l "$HOOK"
        else
            echo "未安装"
            exit 1
        fi
        ;;
    *)
        echo "用法: $0 {install|uninstall|status}" >&2
        exit 2
        ;;
esac

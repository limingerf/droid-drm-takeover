#!/bin/sh
# display/return-to-android.sh —— 桌面「返回安卓」图标调用的**用户级**入口。
#
# ══════════════════════════════════════════════════════════════════════
# 它和 display/drm-stop.sh 的关系
# ══════════════════════════════════════════════════════════════════════
# drm-stop.sh 是**容器侧 root** 的正式入口，会 source core/lib/boot.sh
# 做设备识别、心跳检查等等。但桌面图标是桌面用户（Gold）点的，不能提权。
#
# 好消息：真正要做的只有一件事 —— 往会合目录写一个 exit.request 文件。
# 安卓侧的常驻守护（root）看到后：删请求 → 停容器 → 杀残留 → sync →
# /system/bin/reboot。**重启是守护做的，本脚本不需要任何权限。**
#
# 实测（2026-10-13）会合目录 /var/lib/droid-drm-takeover 的权限是
#   drwxrwxrwt  root root      ← sticky + world-writable
# 所以桌面用户直接写得进去。这正是它设计成 1777 的原因。
#
# ★ 为什么不直接调 drm-stop.sh：
#   它 source boot.sh 会跑一堆 root 才做得了的事（读 android prop、
#   写 /run 状态…），以 Gold 跑会半路失败，反而给人"点了没反应"的印象。
#   这里只做那**一件**必要的事，逻辑简单到不会坏。
#
# ══════════════════════════════════════════════════════════════════════
# 安全设计
# ══════════════════════════════════════════════════════════════════════
# 1) **必须二次确认**。这个图标一点就整机重启，误触代价很大。
#    用 kdialog 弹窗；没有 kdialog 就退回终端 read。
# 2) 先看心跳新不新鲜。守护没在跑的话，写了请求也没人处理，
#    必须明确告诉用户"设备不会自己回去"，并给出安卓侧的手工命令。
# 3) 写请求用 `: >`（截断创建），不是 `echo >` —— 内容无所谓，
#    守护只看文件在不在。
#
# 用法：
#   sh display/return-to-android.sh          交互式（带确认弹窗）
#   sh display/return-to-android.sh --force  不确认，直接发（给脚本用）
#   sh display/return-to-android.sh --check  只看状态，不发请求

set -u

RENDEZVOUS=${DRM_RENDEZVOUS:-/var/lib/droid-drm-takeover}
REQUEST="$RENDEZVOUS/exit.request"
HEARTBEAT="$RENDEZVOUS/heartbeat"
# 心跳超过这么久就认为守护没在听（和 core/lib/request.sh 保持一致）
HEARTBEAT_MAX=${DRM_HEARTBEAT_MAX:-30}

# ── 输出：有 kdialog 就用弹窗，否则打终端 ──────────────────
ui_available() { command -v kdialog >/dev/null 2>&1; }

say() {
    if ui_available; then
        kdialog --title "返回安卓" --msgbox "$1" 2>/dev/null || true
    else
        printf '%s\n' "$1"
    fi
}

warn() {
    if ui_available; then
        kdialog --title "返回安卓" --error "$1" 2>/dev/null || true
    else
        printf '!! %s\n' "$1" >&2
    fi
}

# 返回 0 = 用户点了"返回安卓"
confirm() {
    if ui_available; then
        kdialog --title "返回安卓" \
                --yesno "确定要返回安卓吗？

容器会被停掉，然后**整机重启**。

重启是安卓侧守护做的，不是原地恢复 —— 原地恢复会留下触摸/
音频/热插拔都不正常的半死状态，所以这里走整机重启这条干净路。" \
                --yes-label "返回安卓" --no-label "取消" 2>/dev/null
        return $?
    fi
    printf '确定要返回安卓吗？（容器会停掉并整机重启）[y/N] '
    read -r _a
    case "$_a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# 守护还在听吗？返回 0 = 在听
watcher_alive() {
    [ -r "$HEARTBEAT" ] || return 1
    _hb=$(cat "$HEARTBEAT" 2>/dev/null | tr -dc '0-9')
    [ -n "$_hb" ] || return 1
    _now=$(date +%s)
    [ "$((_now - _hb))" -le "$HEARTBEAT_MAX" ]
}

# 把 exit.request 发出去
send_exit() {
    if [ ! -d "$RENDEZVOUS" ]; then
        warn "会合目录不存在：$RENDEZVOUS
容器可能没在跑（那就不需要「返回」了）。"
        return 1
    fi
    # ★ 先删旧的：残留的 exit.request 会被守护立刻消费掉，
    #   让人误以为"刚点的这次生效了"。清掉才能保证这次是真的。
    rm -f "$REQUEST" 2>/dev/null
    if ! : >"$REQUEST" 2>/dev/null; then
        warn "写不了 $REQUEST
（权限或只读文件系统）—— 请在安卓侧手工执行：
su -c 'sh /data/local/Droidspaces/.../core/switch.sh exit'"
        return 1
    fi
    chmod 666 "$REQUEST" 2>/dev/null
    return 0
}

# ── 入口 ───────────────────────────────────────────────────
MODE=${1:-ask}

case "$MODE" in
    --check)
        printf '会合目录 : %s\n' "$RENDEZVOUS"
        printf '  可写   : %s\n' "$([ -w "$RENDEZVOUS" ] && echo 是 || echo 否)"
        printf '  心跳   : %s\n' "$(cat "$HEARTBEAT" 2>/dev/null || echo 无)"
        printf '  守护   : %s\n' "$(watcher_alive && echo 在听 || echo '没在听（写了也不会重启）')"
        printf '  残留请求: %s\n' "$([ -e "$REQUEST" ] && echo 有 || echo 无)"
        exit 0
        ;;
    --force)
        ;;
    *)
        if ! confirm; then
            exit 0
        fi
        ;;
esac

if ! watcher_alive; then
    warn "安卓侧守护没在听（心跳不新鲜）—— 请求发出去也不会有人处理。

可能原因：守护没启动，或者已经卡住。
请在安卓侧手工执行：
  su -c 'sh <payload>/core/switch.sh exit'"
    # 仍然发一次：万一只是心跳文件写失败，请求还是会被处理
fi

if send_exit; then
    say "已请求返回安卓。

安卓侧守护会在几秒内停掉容器并整机重启，屏幕会黑一下。
如果 30 秒内没有任何动静，说明守护卡住了 —— 请长按电源键强制重启。"
    exit 0
fi
exit 1

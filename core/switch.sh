#!/bin/sh
# core/switch.sh — 统一切换控制器（状态机 + 子命令）。
#
# ══ 为什么需要它 ══
# 重构前有三个互不知情的入口：
#   · drm-takeover.sh   一次性试验，MODE=kwin 才起 kwin，不起桌面
#   · desk-takeover.sh  无条件起 kwin + Plasma + WiFi
#   · ade.sh（参考仓库） 安卓侧十阶段
# 三者各自维护自己的阶段与回滚，env 块还不一样（KWINWRAP_LEASE vs
# KWINWRAP_FILTER），同一台设备上行为不可复现、排障无法互相印证。
# 唯一的状态是 `takeover.ok` 一个空文件——布尔、无时间戳、无模式、
# 无 PID，而且 drm-takeover.sh 在结尾无条件 touch 它，把自己的保险丝判据弄失效。
#
# 现在：一个状态机、一套阶段、一份日志、一把锁。
#
# ══ 子命令 ══
#   enter     进入 Linux（★ 必须在安卓侧执行）
#   exit      返回安卓（★ 安卓侧执行；动作 = 停容器 + 整机重启）
#   rollback  接管中途放弃，原地把安卓拉回来（尽力而为）
#   status    打印当前状态（两侧都能跑）
#   doctor    环境体检（两侧都能跑）
#   watch     安卓侧常驻守护：轮询共享目录里的退出请求
#
# ══ 用法 ══
#   安卓侧:  su -c 'sh /data/local/drm-takeover/core/switch.sh enter'
#   容器侧:  sh /root/droid-drm-takeover/core/switch.sh status
#
# ══ 环境变量（全部可选）══
#   DRM_DEVICE=opd2511     强制指定设备适配层
#   FULL_STOP=1            连 framework 一起 stop（⚠️ 会永久毁掉音频，默认关）
#   DRM_NET=0              跳过网络接管
#   DRM_WIFI_SSID/PSK      直接给凭据（否则从安卓读）
#   DRM_WAYLAND_SOCKET     合成器 socket 名（默认 taketest）
#   DRM_ADB_SERIAL         容器侧指定 adb 序列号

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/common.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/device.sh"
drm_device_load
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/android.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/container.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/display.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/net.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/enter.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/request.sh"

drm_state_init
drm_state_set DEVICE "$DEV_CODENAME"
drm_state_set SIDE "$DRM_SIDE"

# 重启后旧状态要能自愈：BOOT_ID 变了说明上一轮已经随重启结束。
#
# ★★ 顺序要害（实测踩过）：**必须先把上一次记下的 BOOT_ID 读出来，再写新的**。
#    原来这里是
#        drm_state_set BOOT_ID "$(drm_boot_id)"   ← 先写
#        _bid=$(drm_state_get BOOT_ID)            ← 后读
#    于是 _bid 读到的**已经是新值**，下面的 `_bid != _cur_bid` 永远为假 ——
#    自愈从来不会触发。后果很毒：设备重启后 state 里留着上一轮的
#    `PHASE=linux-active`，而 cmd_enter 的幂等检查只看 PHASE，
#    于是它直接 return 0 并写 enter.result=ok，**整轮接管根本没跑**，
#    安卓 SF/composer 还好端端跑着。现象是"接管瞬间就成功、日志停在
#    设备适配层之后什么都没有"，极易误判成卡住。
_bid=$(drm_state_get BOOT_ID 2>/dev/null || true)
_cur_bid=$(drm_boot_id)
drm_state_set BOOT_ID "$_cur_bid"

if [ -n "$_cur_bid" ] && [ -n "$_bid" ] && [ "$_bid" != "$_cur_bid" ]; then
    drm_log "BOOT_ID 变化（$_bid → $_cur_bid）—— 判定为重启，状态复位为 android-active"
    drm_state_set PHASE android-active
    drm_state_set PHASE_AT "$(drm_ts)"
    drm_state_set LAST_ERROR ""
fi

# ═══════════════════════════════════════════════════════════
# doctor — 环境体检
# ═══════════════════════════════════════════════════════════

cmd_doctor() {
    _fail=0
    _ok()   { printf '  [ OK ] %s\n' "$*"; }
    _bad()  { printf '  [FAIL] %s\n' "$*"; _fail=$((_fail + 1)); }
    _warn() { printf '  [warn] %s\n' "$*"; }

    printf '══ 设备 ══\n'
    printf '  适配层   : %s (%s)\n' "$DRM_DEVICE" "$DEV_MODEL"
    printf '  平台     : %s\n' "$DEV_PLATFORM"
    printf '  当前侧   : %s\n' "$DRM_SIDE"
    printf '  面板     : %sx%s\n' "$DEV_PANEL_W" "$DEV_PANEL_H"

    printf '══ 显示 ══\n'
    [ -c "$DEV_DRM_CARD" ] && _ok "存在 $DEV_DRM_CARD" || _bad "缺 $DEV_DRM_CARD"
    if [ -e "$DEV_DRM_RENDER" ]; then _ok "存在 $DEV_DRM_RENDER"; else _warn "缺 $DEV_DRM_RENDER（Mesa/EGL 可能受限）"; fi
    [ -e /dev/kgsl-3d0 ] && _ok "存在 /dev/kgsl-3d0（渲染链）" || _warn "缺 /dev/kgsl-3d0"

    if drm_android_side; then
        printf '══ 安卓服务 ══\n'
        printf '  %-28s = %s\n' "$DEV_SF_SVC" "$(android_svc_state "$DEV_SF_SVC")"
        printf '  %-28s = %s\n' "$DEV_COMPOSER_SVC" "$(android_svc_state "$DEV_COMPOSER_SVC")"
        _h=$(android_card_holders 2>/dev/null)
        if [ -n "$_h" ]; then
            _warn "$DEV_DRM_CARD 当前持有者：$_h"
        else
            _ok "$DEV_DRM_CARD 无持有者"
        fi
    fi

    printf '══ 容器 ══\n'
    ds_init
    if ds_available; then
        _ok "Droidspaces：$DS_BIN"
        if ds_running; then _ok "容器 $DS_NAME 在跑"; else _warn "容器 $DS_NAME 没在跑"; fi
    else
        _bad "找不到 Droidspaces：$DS_BIN"
    fi
    if ds_shared_ready; then
        _ok "共享目录可写：$(ds_shared_dir)"
    else
        _warn "共享目录不可写：$(ds_shared_dir)（容器没起时属正常）"
    fi

    if ! drm_android_side; then
        printf '══ 桌面（容器侧）══\n'
        drm_desktop_user_resolve 2>/dev/null && _ok "桌面账号：$DESKTOP_USER (uid=$DESKTOP_UID)"
        for _t in kwinwrap setbright setprop crtcstate connprops; do
            if drm_tool "$_t" >/dev/null 2>&1; then _ok "工具 $_t"; else _bad "缺工具 $_t（先 make）"; fi
        done
        for _c in kwin_wayland plasmashell dbus-daemon runuser; do
            if command -v "$_c" >/dev/null 2>&1; then _ok "命令 $_c"; else _bad "缺命令 $_c"; fi
        done
        _kactiv=$(for c in /usr/lib/*/libexec/kactivitymanagerd /usr/libexec/kactivitymanagerd /usr/bin/kactivitymanagerd; do
                      [ -x "$c" ] && { printf '%s' "$c"; break; }; done)
        [ -n "$_kactiv" ] && _ok "kactivitymanagerd：$_kactiv" || _bad "缺 kactivitymanagerd（plasmashell 会 Aborting shell load）"
        _bl=$(drm_backlight_node 2>/dev/null) && _ok "背光节点：$_bl" || _warn "找不到背光节点"
        _sock=${DRM_WAYLAND_SOCKET:-taketest}
        if [ -S "$DESKTOP_RUNTIME_DIR/$_sock" ]; then _ok "合成器 socket 存在"; else _warn "合成器 socket 不存在（未接管？）"; fi
    fi

    printf '══ 状态 ══\n'
    drm_state_show | sed 's/^/  /'
    _lh=$(drm_lock_holder 2>/dev/null) && printf '  锁       : %s\n' "$_lh" || printf '  锁       : 空闲\n'

    printf '\n'
    if [ "$_fail" -gt 0 ]; then
        drm_err "doctor：$_fail 项不通过"
        return 1
    fi
    drm_log "doctor：全部通过"
    return 0
}

# ═══════════════════════════════════════════════════════════
# enter — 进入 Linux（安卓侧）
# ═══════════════════════════════════════════════════════════

cmd_enter() {
    # 时序实现在 core/lib/enter.sh 的 drm_do_enter()，与容器侧的
    # display/desk-takeover.sh 共用同一套阶段顺序（重构前是两个实现）。
    drm_lock_acquire enter || exit 1
    trap 'drm_lock_release' EXIT INT TERM

    if drm_do_enter; then
        drm_log "回安卓：在桌面里点「返回安卓」图标，或跑 exit 子命令"
        drm_lock_release
        trap - EXIT INT TERM
        return 0
    fi

    drm_lock_release
    trap - EXIT INT TERM
    return 1
}

# ═══════════════════════════════════════════════════════════
# rollback — 接管中途放弃，原地拉回安卓
# ═══════════════════════════════════════════════════════════
#
# ⚠️ 这只是"尽力而为"的原地恢复。已知它会留下半死状态：
#    容器启动破坏了安卓 ueventd 的 netlink（热插拔节点建不出来），
#    停容器**不等于**恢复，只有整机重启能回到干净状态。
#    所以正常路径的 exit 一律走 reboot；rollback 只在"还没起容器"
#    或"用户明确接受半死"时用。
cmd_rollback() {
    drm_log "══ rollback：尝试原地恢复安卓 ══"
    drm_state_set PHASE returning

    # 停容器（如果起了）
    ds_stop 2>/dev/null || true

    # 杀容器侧残留（如果共享目录还挂着）
    #
    # ★ 走容器里的 display/kill-desktop.sh，而不是往 ds_exec 里塞一行 pkill：
    #   · 容器是精简 rootfs，`pkill` 来自 procps，不保证装了（没装就静默失败，
    #     残留的 kwinwrap 会继续握着 DRM 节点）
    #   · pkill -f 按正则匹配整条命令行，会误伤
    #   那个脚本 source boot.sh 后调用 drm_kill_linux_stack，与会话拉起路径
    #   用的是同一套逻辑（纯 /proc 扫描）。
    if ds_shared_ready 2>/dev/null; then
        # ★ 必须是**容器内**的路径（/root/...），不是安卓侧的 <rootfs>/root/...
        _kd="$(ds_repo_in_container)/display/kill-desktop.sh"
        ds_exec "sh '$_kd'" >/dev/null 2>&1 || true
    fi

    # 起回安卓显示栈
    android_start_display
    android_exec "setprop ctl.start system_suspend" 2>/dev/null
    android_start_framework

    # 还原我们改过的东西
    android_watchdog_rearm 2>/dev/null || true
    android_kernel_debug_on 2>/dev/null || true

    # 等 SurfaceFlinger
    _i=0
    while [ "$_i" -lt 24 ]; do
        [ "$(android_svc_state "$DEV_SF_SVC")" = running ] && break
        sleep 5
        _i=$((_i + 1))
        android_start_display
    done

    android_stop_bootanim
    android_wake
    android_dismiss_keyguard
    android_set_brightness

    drm_state_set PHASE android-active
    drm_state_set PHASE_AT "$(drm_ts)"
    drm_log "rollback 完成：SF=$(android_svc_state "$DEV_SF_SVC") composer=$(android_svc_state "$DEV_COMPOSER_SVC")"
    drm_warn "若画面仍异常（USB/pogo 键盘不认、莫名重启），只有整机重启能彻底恢复"
    return 0
}

# ═══════════════════════════════════════════════════════════
# exit — 返回安卓（安卓侧执行；动作 = 停容器 + 整机重启）
# ═══════════════════════════════════════════════════════════
#
# ★ 为什么不"停容器 + 原地起安卓"：
#   参考仓库实测过，结果是半死状态——卡开机界面约 1 分钟，进系统后
#   不定时重启（watchdog 在杀 vendor HAL，被 SELinux 拒：
#   avc: denied { signal } for comm="watchdog"
#   tcontext=u:r:oplus_hal_displaypanelfeature），pogo 键盘也断开。
#   根因是容器启动破坏了安卓 ueventd 的 netlink，热插拔节点全建不出来。
#   这些只有重启能恢复。
#
# ★ 为什么必须 /system/bin/reboot：
#   · `svc power reboot` 走 framework，依赖 system_server；停容器后它
#     **静默返回 0 但什么都不做**（所以 `|| reboot` 这种 fallback 永远不触发）
#   · `setprop sys.powerctl reboot` 在厂商改过的 init 上也无反应
#   只有不依赖 framework 的 /system/bin/reboot 可靠。
cmd_exit() {
    drm_log "══ exit：返回安卓（停容器 → 整机重启）══"
    drm_state_set PHASE returning

    ds_stop 2>/dev/null || true

    # 杀掉可能在推音频的安卓侧进程，释放 socket
    for _p in $(pidof argsloop 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done
    rm -f "$(ds_shared_dir)/hal-direct.sock" 2>/dev/null

    sync
    drm_log "执行 /system/bin/reboot"
    /system/bin/reboot
    # 兜底（正常不会执行到）
    sleep 5
    setprop sys.powerctl reboot 2>/dev/null
    return 0
}

# ═══════════════════════════════════════════════════════════
# watch — 安卓侧常驻守护：轮询会合目录里的请求
# ═══════════════════════════════════════════════════════════
#
# ★ 为什么必须由安卓侧执行（而不是容器里直接调 adb）：
#   实测 Droidspaces v6.6.0 的容器里**没有 USB 节点**（/dev/bus/usb
#   不存在）、adbd 也没监听 TCP ⇒ 容器里的 `adb devices` 恒为空。
#   而接管必须停 surfaceflinger 与 composer HAL，那只有能访问 init
#   属性服务的安卓侧做得到。所以容器只写请求，这里执行。
#   完整协议见 core/lib/request.sh。
#
# ★ 顺序要害：退出请求文件必须在**停容器之前**删掉——容器一停，
#   共享目录（容器 /root 的 host 侧挂载）就没了，那时再删就删不掉，
#   下次开机它还在，会导致一开机就重启。
# "自己 + 自己的所有后代" 的 pid 集合，形如 " 123 456 789 "（便于 case 匹配）。
#
# ★ 为什么需要它：`$( )` 与管道会 fork，而 fork 出来的子 shell **命令行与父进程
#   一模一样**（都是 `sh .../switch.sh watch`）。原来的实现只跳过 `$$` 和
#   PPID=$$ 的直接子进程，**漏掉了孙进程** —— `$(drm_watch_pids | tr ...)`
#   里真正跑函数的那个子 shell，PPID 是 `$( )` 的子 shell，不是 `$$`，
#   于是被当成"另一个守护"。
#
#   实测后果（很隐蔽）：开机时 KernelSU 模块把守护拉起来，守护第一件事就是
#   查单例，结果扫到自己的孙进程，记一条
#     "watch 已在跑（pid=2733 2988 2993 3031），退出"
#   然后立刻自杀。守护没起来、日志里却写着"已在跑"，`status` 又报 not running。
#   从 adb shell 手动 start 时 fork 层数不同，反而常常能跑起来 —— 所以这个
#   bug 只在开机自启路径上暴露。
drm_self_tree() {
    _t=" $$ "
    _ch=1
    while [ "$_ch" = 1 ]; do
        _ch=0
        for _d in /proc/[0-9]*; do
            _q=${_d#/proc/}
            case "$_t" in *" $_q "*) continue ;; esac
            _pq=$(sed 's/.*) //' "$_d/stat" 2>/dev/null | awk '{print $2}')
            [ -n "$_pq" ] || continue
            case "$_t" in
                *" $_pq "*) _t="$_t$_q "; _ch=1 ;;
            esac
        done
    done
    printf '%s' "$_t"
}

# 所有 watch 守护进程的 pid。
#
# ★ 坑一：不能用 drm_pids_by_cmdline "switch.sh watch" —— 它是**子串**匹配，
#   会把 `switch.sh watch-status` / `watch-stop` 也匹配进来。
#   这里要求命令行**以** `switch.sh watch` 结尾，见下面的 case。
#
# ★ 坑二（实测踩过，很隐蔽）：必须排除**自己整棵后代树**，见 drm_self_tree()。
drm_watch_pids() {
    _tree=$(drm_self_tree)
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        case "$_tree" in *" $_p "*) continue ;; esac
        [ -r "$_d/cmdline" ] || continue
        _cl=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null) || continue
        [ -n "$_cl" ] || continue
        # ★ 必须要求命令行**以** `switch.sh watch` 结尾。
        #   原来写的是 case "$_cl" in *"switch.sh watch") ...
        #   —— 那是**子串**匹配，`switch.sh watch-status` / `switch.sh watch-stop`
        #   一样命中！而 exit-watch.sh 的 _alive() 就是靠调 watch-status 判活的，
        #   于是"查状态"这个动作本身被当成了"有另一个守护在跑"。
        #   实测后果：开机时模块把守护拉起来，守护第一件事查单例，
        #   恰好撞上别处正在跑的 watch-status，于是记一条
        #     "watch 已在跑（pid=2734 3027 3032），退出"
        #   然后自杀 —— 守护永远起不来，而日志说"已在跑"。
        _cl=${_cl% }
        case "$_cl" in
            *"switch.sh watch") ;;
            *) continue ;;
        esac
        printf '%s\n' "$_p"
    done
}

cmd_watch() {
    _stop="$DRM_RUN_DIR/.watch-stop"

    # ── 单例 ──
    # ★ 判据是扫 /proc，不是 pid 文件。
    #   实测踩过：pid 文件写的是一个值，而真正活着的守护可能是另一个
    #   （start 时先 rm 掉信号文件、再拉起新的，旧守护还没轮到轮询就把
    #    停止信号删了 ⇒ 两个守护并存 ⇒ 一个请求被处理两次）。
    #   进程表不会撒谎。
    # ── 单例：原子锁目录 ──
    #
    # ★★ 为什么不用"扫 /proc 数进程"当判据（这是本轮最大的坑）★★
    #   判据曾经是 `drm_watch_pids` 非空就退出。但那个函数靠 fork 记账来
    #   排除自己（见 drm_self_tree 的注释），而 `$( )` / 管道 / 函数调用
    #   到底 fork 几层、`$$` 在子 shell 里是不是主 shell 的 pid，
    #   在不同 shell、不同调用深度下并不一致 —— 记账一旦漏掉一层，
    #   就把自己的子进程当成"另一个守护"。
    #
    #   更致命的是**开机路径**：本机有三个启动器都会跑 `exit-watch.sh run`
    #     · KernelSU 模块 service.sh（主路径）
    #     · /data/adb/service.d/ hook（Magisk 兼容路径）
    #     · APK 的 WatchService 前台服务
    #   它们几乎同时起来，每个都扫到另外两个 ⇒ **三个全退出**，
    #   结果一个守护都不剩，而日志里每个都写着"已在跑"。
    #   手动从 adb shell 起只有一个启动器，所以永远复现不出来。
    #
    #   `mkdir` 是原子的，不依赖任何 fork 记账 ⇒ 谁抢到谁跑，确定性的。
    mkdir -p "$DRM_RUN_DIR" 2>/dev/null
    _lk="$DRM_RUN_DIR/watch.lock"
    if [ -d "$_lk" ]; then
        _op=$(cat "$_lk/pid" 2>/dev/null)
        if [ -n "$_op" ] && kill -0 "$_op" 2>/dev/null; then
            drm_log "watch 已在跑（pid=$_op，持锁 $_lk），退出"
            return 0
        fi
        # 陈旧锁（持锁进程已死）——接管它，否则一次异常退出就再也起不来了
        drm_warn "发现陈旧锁 $_lk（pid=${_op:-空} 已不在），接管"
        rm -rf "$_lk" 2>/dev/null
    fi
    if ! mkdir "$_lk" 2>/dev/null; then
        drm_log "抢锁失败（$_lk 被并发创建），退出"
        return 0
    fi
    printf '%s\n' "$$" >"$_lk/pid" 2>/dev/null
    # 退出路径必须放锁，否则一次异常退出就留下陈旧锁（虽然有接管逻辑兜底）
    _unlock() { rm -rf "$_lk" 2>/dev/null; }
    # 顺带把 /proc 扫到的"别的守护"记下来 —— 只做诊断，不再当判据
    _others=$(drm_watch_pids | tr '\n' ' ')
    [ -n "$_others" ] && drm_warn "另有 watch 进程在跑（不阻断）：$_others"
    rm -f "$_stop" 2>/dev/null

    _rd=$(drm_rendezvous_ensure 2>/dev/null) || _rd=""
    if [ -z "$_rd" ]; then
        drm_err "建不出会合目录 —— 容器侧将无法发出任何请求"
        _unlock
        return 1
    fi
    drm_identity_publish

    drm_log "watch 启动（pid=$$）：轮询 $_rd（enter.request / exit.request）"
    while :; do
        [ -f "$_stop" ] && { drm_log "watch 收到停止信号"; _unlock; return 0; }

        drm_heartbeat_touch

        # ── 返回安卓 ──
        if [ -f "$_rd/exit.request" ]; then
            drm_log "检测到返回安卓请求"
            rm -f "$_rd/exit.request" 2>/dev/null   # ★ 必须在停容器之前
            _unlock
            cmd_exit
            return 0
        fi

        # ── 进入 Linux ──
        #
        # ★ 身份信息要在接管**之前**再发一次：容器启动后 rootfs 里的
        #   路径才真正可写，而且设备可能换过。
        if [ -f "$_rd/enter.request" ]; then
            drm_log "检测到进入 Linux 请求"
            rm -f "$_rd/enter.request" "$_rd/enter.result" 2>/dev/null
            drm_identity_publish
            if cmd_enter; then
                printf 'ok\n' >"$_rd/enter.result" 2>/dev/null
            else
                printf 'fail 接管失败，详见 %s\n' "$DRM_JOURNAL" >"$_rd/enter.result" 2>/dev/null
            fi
            chmod 644 "$_rd/enter.result" 2>/dev/null
            # 接管成功后本进程所在的框架/显示栈已被改动，继续轮询即可；
            # 失败则原地回滚已由 cmd_enter → drm_do_enter 完成。
        fi

        sleep 1
    done
}

cmd_watch_stop() {
    touch "$DRM_RUN_DIR/.watch-stop" 2>/dev/null
    drm_log "已请求 watch 停止"
    # 等它自己退；超时就用 /proc 扫描兜底（同样不信 pid 文件）
    _i=0
    while [ "$_i" -lt 10 ]; do
        [ -z "$(drm_watch_pids)" ] && { drm_log "watch 已退出"; break; }
        sleep 1
        _i=$((_i + 1))
    done
    _p=$(drm_watch_pids | tr '\n' ' ')
    if [ -n "$_p" ]; then
        drm_warn "watch 没有响应停止信号，强制结束：$_p"
        # shellcheck disable=SC2086
        drm_kill_pids 9 $(drm_watch_pids)
        sleep 1
        [ -z "$(drm_watch_pids)" ] || drm_err "仍有 watch 存活"
    fi
    # ★ 锁一定要放掉：守护被 kill -9 时走不到 _unlock，残留锁会让下次
    #   watch 以为"已在跑"。cmd_watch 里有陈旧锁接管逻辑兜底，
    #   但这里主动清掉更干净。
    rm -rf "$DRM_RUN_DIR/watch.lock" 2>/dev/null
    return 0
}

cmd_watch_status() {
    # ★ 判据以锁为准（见 drm_watch_acquire 的注释：/proc 扫描会误判）
    _lk="$DRM_RUN_DIR/watch.lock"
    if [ -d "$_lk" ]; then
        _op=$(cat "$_lk/pid" 2>/dev/null)
        if [ -n "$_op" ] && kill -0 "$_op" 2>/dev/null; then
            printf 'watch: running (pid=%s)\n' "$_op"
            return 0
        fi
        printf 'watch: not running (陈旧锁 pid=%s)\n' "${_op:-空}"
        return 1
    fi
    _p=$(drm_watch_pids | tr '\n' ' ')
    if [ -n "$_p" ]; then
        printf 'watch: running (pid=%s，无锁)\n' "$_p"
        return 0
    fi
    printf 'watch: not running\n'
    return 1
}

# ═══════════════════════════════════════════════════════════
# status
# ═══════════════════════════════════════════════════════════

cmd_status() {
    printf '设备      : %s (%s) [%s 侧]\n' "$DRM_DEVICE" "$DEV_MODEL" "$DRM_SIDE"
    drm_state_show
    _lh=$(drm_lock_holder 2>/dev/null) && printf '锁        : %s\n' "$_lh" || printf '锁        : 空闲\n'
    cmd_watch_status
    if drm_android_side; then
        printf 'SF        : %s\n' "$(android_svc_state "$DEV_SF_SVC")"
        printf 'composer  : %s\n' "$(android_svc_state "$DEV_COMPOSER_SVC")"
        _h=$(android_card_holders 2>/dev/null)
        printf 'card0持有 : %s\n' "${_h:-无}"
    else
        printf 'kwin      : %s\n' "$(drm_pids_by_comm kwin_wayland | tr '\n' ' ')"
        printf 'plasmashell: %s\n' "$(drm_pids_by_comm plasmashell | tr '\n' ' ')"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════

usage() {
    cat <<EOF
$DRM_PROJECT — 统一切换控制器

用法: $0 <子命令> [参数]

  enter        进入 Linux（★ 必须在安卓侧以 root 执行）
  exit         返回安卓（安卓侧；动作 = 停容器 + 整机重启）
  rollback     接管中途放弃，原地拉回安卓（尽力而为）
  status       打印当前状态
  doctor       环境体检
  watch        安卓侧常驻守护：轮询共享目录的退出请求
  watch-stop   停止 watch
  watch-status 查看 watch 状态

环境变量:
  DRM_DEVICE=opd2511   强制设备适配层（默认自动识别）
  FULL_STOP=1          连 framework 一起 stop（⚠️ 会永久毁掉音频）
  DRM_NET=0            跳过网络接管
  DRM_WIFI_SSID/PSK    直接给 WiFi 凭据
  DRM_WAYLAND_SOCKET   合成器 socket 名（默认 taketest）

当前设备: $DRM_DEVICE ($DEV_MODEL)，本进程在 $DRM_SIDE 侧
EOF
}

# ── payload 可信性自检 ────────────────────────────────────
# 本脚本以 root 执行。如果它所在的树对非 root 可写（例如老版本的
# /data/local/tmp/...），那么任何能写那棵树的本地进程都能拿到 root。
# 特权动作之前先确认一次；只读子命令（status/doctor/help）不拦，
# 方便用户在任何情况下都能查状态、看体检结果。
case "${1:-}" in
    enter|exit|rollback|watch)
        if ! drm_assert_payload_trusted "$DRM_ROOT"; then
            drm_err "已中止（未执行任何特权动作）"
            exit 1
        fi
        ;;
esac

case "${1:-}" in
    enter)        shift; cmd_enter "$@" ;;
    exit)         shift; cmd_exit "$@" ;;
    rollback)     shift; cmd_rollback "$@" ;;
    status)       shift; cmd_status "$@" ;;
    doctor)       shift; cmd_doctor "$@" ;;
    watch)        shift; cmd_watch "$@" ;;
    watch-stop)   shift; cmd_watch_stop "$@" ;;
    watch-status) shift; cmd_watch_status "$@" ;;
    ''|-h|--help|help) usage ;;
    *) drm_err "未知子命令：$1"; usage; exit 2 ;;
esac

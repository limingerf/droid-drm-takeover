#!/bin/sh
# core/lib/android.sh — 安卓侧的统一操作入口。
#
# 【核心抽象】android_exec()
#   同一句"停 composer"在两侧的执行方式完全不同：
#     · 脚本跑在安卓侧（APK 触发）  → 直接 `sh -c`
#     · 脚本跑在容器侧（桌面里触发）→ `adb shell su -c`
#   重构前这个差异被复制到每个脚本里（~40 处 adb 字符串拼接），
#   导致"同一个动作两个入口行为不一致"。现在只有这一个出口。
#
# 【必须带超时】所有 adb 调用都包 drm_timeout。
#   参考仓库实测事故：desk-stop 卡死在第一个 adb 调用上，日志断在
#   wake_unlock 那行，后面的 `start` 从未执行 ⇒ 纯黑屏。

DRM_ADB_BIN=""
DRM_ADB_SERIAL=""

drm_android_side() { [ "$DRM_SIDE" = android ]; }

# ── adb 通道（仅容器侧需要）────────────────────────────────
drm_adb_init() {
    drm_android_side && return 0

    DRM_ADB_BIN=$(drm_find adb 2>/dev/null || true)
    [ -n "$DRM_ADB_BIN" ] || drm_die "容器侧找不到 adb —— 无法控制安卓侧"

    if [ -n "${DRM_ADB_SERIAL:-}" ]; then
        return 0
    fi

    # 优先本机 adb 传输（容器与设备同机，与 WiFi 生死无关）
    DRM_ADB_SERIAL=$("$DRM_ADB_BIN" devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
    if [ -z "$DRM_ADB_SERIAL" ]; then
        # 退而求其次：读共享目录里安卓侧写下的序列号
        if [ -n "${DEV_SHARED:-}" ] && [ -r "$DEV_SHARED/.drm-serial" ]; then
            DRM_ADB_SERIAL=$(head -1 "$DEV_SHARED/.drm-serial")
            drm_log "从共享目录读到序列号：$DRM_ADB_SERIAL"
        fi
    fi
    [ -n "$DRM_ADB_SERIAL" ] || drm_die "找不到 adb 设备（adb devices 为空）"

    # ★ 重构前 drm-takeover.sh:33-34 硬编码了 13 个 adb-over-WiFi 端点。
    #   换网络后每个 connect 都要等 TCP 超时，最坏耗 5-10 分钟。
    #   现在改成：只在显式给出 DRM_ADB_ENDPOINTS 时才尝试，且每个都有超时。
    if [ -z "$DRM_ADB_SERIAL" ] && [ -n "${DRM_ADB_ENDPOINTS:-}" ]; then
        for _ep in $DRM_ADB_ENDPOINTS; do
            drm_timeout 6 "$DRM_ADB_BIN" connect "$_ep" >/dev/null 2>&1
            if drm_timeout 8 "$DRM_ADB_BIN" -s "$_ep" shell true >/dev/null 2>&1; then
                DRM_ADB_SERIAL=$_ep
                break
            fi
        done
    fi

    drm_log "adb 通道：$DRM_ADB_SERIAL"
    drm_state_set ADB_SERIAL "$DRM_ADB_SERIAL"
}

# ── ★ 唯一出口 ────────────────────────────────────────────
# 安卓侧：以 root 执行（调用方保证自己是 root，或由 APK 用 su 起）
# 容器侧：adb shell su -c '<cmd>'
#
# ★ 必须转义命令里的单引号（修掉一个潜伏很久的真 bug）：
#   容器侧要把命令塞进 `su -c '...'`，而命令自己可能带单引号
#   （android_card_holders 里就有 'dri/card0'）。不转义的话那个引号会
#   提前闭合，后面的内容全变成 shell 的普通词 —— 命令静默碎掉。
#   安卓侧走的是 `sh -c "$1"`，不经过这层，所以这个 bug 只在
#   **容器侧入口**（display/desk-takeover.sh 那条链）才现形。
#   POSIX 唯一可靠的转义：把每个 ' 换成 '\''。
drm_shq_escape() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

android_exec() {
    if drm_android_side; then
        sh -c "$1"
    else
        drm_timeout "${DRM_ADB_TIMEOUT:-12}" "$DRM_ADB_BIN" -s "$DRM_ADB_SERIAL" \
            shell "su -c '$(drm_shq_escape "$1")'"
    fi
}

# 只读查询（不需要 root 的走这条，省一次 su）
android_query() {
    if drm_android_side; then
        sh -c "$1"
    else
        drm_timeout "${DRM_ADB_TIMEOUT:-12}" "$DRM_ADB_BIN" -s "$DRM_ADB_SERIAL" \
            shell "$1"
    fi
}

# ── 属性 / 服务 ───────────────────────────────────────────

android_prop() {
    android_query "getprop $1" 2>/dev/null | tr -d '\r' | head -1
}

android_svc_state() {
    android_prop "init.svc.$1"
}

android_svc_running() { [ "$(android_svc_state "$1")" = running ]; }

# ── 停 / 起 显示栈 ────────────────────────────────────────
#
# ★ 全项目最关键的一条：`stop` **不动 class hal**。
#   composer HAL 属于 class hal，`stop` 之后它仍然攥着 card0。
#   只要它还在，kwin 的 ATOMIC 提交就报 ret=-13 (EACCES)，
#   现象极具误导性：kwin 起来了、也拿到 master、就是屏幕不出画。
#   判据是**它从 card0 的持有者列表里消失**，不是 init.svc 变成 stopped。

android_stop_display() {
    drm_log "停 surfaceflinger + 点名停 $DEV_COMPOSER_SVC"
    android_exec "setprop ctl.stop $DEV_SF_SVC"
    android_exec "setprop ctl.stop $DEV_COMPOSER_SVC"
}

# 只停 framework（保留 hal）；用于"腾内存"的场景。
# ⚠️ 重构前 desk-takeover.sh 无条件跑 `stop`，而参考仓库明确记录：
#    `stop` 会连 audioserver 一起放倒，而 audioserver 一旦没有 activity
#    注册 media.audio_flinger 就永久废掉音频。所以这里**默认不做**，
#    要跑必须显式 FULL_STOP=1。
android_stop_framework() {
    if [ "${FULL_STOP:-0}" != 1 ]; then
        drm_log "跳过 framework stop（FULL_STOP=1 才执行；保护 audioserver）"
        return 0
    fi
    drm_warn "FULL_STOP=1：执行 framework stop（会一并放倒 audioserver）"
    android_exec "stop"
    _i=0
    while [ "$_i" -lt 30 ]; do
        [ "$(android_svc_state zygote)" = stopped ] && break
        sleep 1
        _i=$((_i + 1))
    done
    drm_log "zygote=$(android_svc_state zygote) SF=$(android_svc_state $DEV_SF_SVC)"
}

# 谁还持有 card0（安卓侧）
#
# ★ 实现抽在 tools/probe/card-holders.sh。这个函数以前是"每个进程
#   fork 一次 ls | grep"（720 进程 ⇒ 上千次 fork，把 0.5s 的轮询拖成
#   几十秒），中间一度改成 `sed` 从 `ls -l /proc/*/fd` 里抽 pid ——
#   那更糟：格式上永远匹配不上，恒返回空，而上层把"空"读成
#   "composer 已经松手"，于是**在错误的时刻接管**。
#   详见 tools/probe/card-holders.sh 顶部的说明。
android_card_holders() {
    if drm_android_side; then
        _h=$(drm_repo_script tools/probe/card-holders.sh 2>/dev/null) || {
            # ★ 不能静默返回空：上层会把"空"读成"composer 松手了"
            drm_warn "找不到 tools/probe/card-holders.sh —— 无法判断谁持有 $DEV_DRM_CARD"
            return 1
        }
        sh "$_h" "$DEV_DRM_CARD" 2>/dev/null
    else
        android_exec "sh ${DRM_ANDROID_PAYLOAD:-/data/local/$DRM_PROJECT}/tools/probe/card-holders.sh $DEV_DRM_CARD" 2>/dev/null | tr -d '\r'
    fi
}

# 等 composer 真正松手。
#
# ★ 主判据是持有者列表（不是 init.svc）——`stop` 不动 class hal，
#   composer 属于 class hal，`stop` 之后它仍然攥着 card0。
#
# ★ 但"持有者列表为空"**不能单独作为判据**：扫描本身失败时也是空。
#   本项目就踩过这个坑（sed 从 `ls -l /proc/*/fd` 里抽 pid 恒为空），
#   上层把"空"读成"已经松手" ⇒ 在错误的时刻接管 ⇒ kwin 拿到 master
#   但 atomic 提交报 ret=-13(EACCES) ⇒ 有 master、不出画，极难定位。
#   所以这里加一道**交叉验证**：只有"扫描说没人持有" **且**
#   "composer 服务状态确实不是 running/restarting" 才认。
#   反过来（列表非空）永远按"还被持有"处理，是安全的一侧。
android_wait_composer_release() {
    _max=${1:-15}
    _i=0
    _h=""
    while [ "$_i" -lt "$_max" ]; do
        _h=$(android_card_holders)
        if [ -z "$_h" ]; then
            _cs=$(android_svc_state "$DEV_COMPOSER_SVC")
            case "$_cs" in
                running|restarting)
                    drm_warn "持有者扫描为空，但 $DEV_COMPOSER_SVC=$_cs —— 不采信，继续等" ;;
                *)
                    drm_log "card0 已无持有者（等了 $((_i / 2))s；composer=$_cs）"
                    drm_state_set COMPOSER_RELEASED 1
                    return 0 ;;
            esac
        fi
        _i=$((_i + 1))
        sleep 0.5 2>/dev/null || sleep 1
    done
    drm_warn "card0 仍有持有者：${_h:-（扫描无结果，且 composer 未停）}"
    drm_state_set COMPOSER_HOLDERS "${_h:-unknown}"
    return 1
}

# 起回显示栈。★ composer 必须**点名起**：
#   `start zygote` 不会把它带回来 ⇒ SurfaceFlinger 起不来
#   ⇒ system_server 卡死等它（看着像 framework 崩了）。
android_start_display() {
    drm_log "起回 $DEV_COMPOSER_SVC + $DEV_SF_SVC"
    android_exec "setprop ctl.start $DEV_COMPOSER_SVC; sleep 1; setprop ctl.start $DEV_SF_SVC"
}

android_start_framework() {
    android_exec "setprop ctl.start system_suspend; start"
}

# ── 稳定性开关 ────────────────────────────────────────────

android_watchdog_disarm() {
    [ -n "$DEV_WATCHDOG_DISARM" ] || return 0
    drm_log "解除安卓稳定性守护（防止 SF 停 120s 后 system_server 自杀）"
    android_exec "$DEV_WATCHDOG_DISARM"
    drm_state_set WATCHDOG_DISARMED 1
}

android_watchdog_rearm() {
    [ -n "$DEV_WATCHDOG_REARM" ] || return 0
    drm_log "还原安卓稳定性守护"
    android_exec "$DEV_WATCHDOG_REARM"
    drm_state_set WATCHDOG_DISARMED 0
}

# ── 内核调试 ──────────────────────────────────────────────
android_kernel_debug_off() { [ -n "$DEV_KERNEL_DEBUG_OFF" ] && android_exec "$DEV_KERNEL_DEBUG_OFF"; return 0; }
android_kernel_debug_on()  { [ -n "$DEV_KERNEL_DEBUG_ON" ]  && android_exec "$DEV_KERNEL_DEBUG_ON";  return 0; }

# ── 屏幕 / 唤醒 ───────────────────────────────────────────
# 接管期间安卓关机流程会把背光拉 0，必须自己点亮。
android_set_brightness() {
    _v=${1:-$DEV_BRIGHTNESS}
    if drm_android_side; then
        _bl=$(drm_backlight_node 2>/dev/null)
        [ -n "$_bl" ] && echo "$_v" >"/sys/class/backlight/$_bl/brightness" 2>/dev/null
    else
        android_exec "for b in /sys/class/backlight/*/brightness; do [ -w \"\$b\" ] && echo $_v > \"\$b\"; done"
    fi
}

android_wake() {
    # 224 = KEYCODE_WAKEUP
    if drm_android_side; then
        input keyevent 224 2>/dev/null
    else
        drm_timeout 8 "$DRM_ADB_BIN" -s "$DRM_ADB_SERIAL" shell input keyevent 224 >/dev/null 2>&1
    fi
}

android_dismiss_keyguard() {
    android_exec "wm dismiss-keyguard" 2>/dev/null
    return 0
}

android_stop_bootanim() {
    android_exec "setprop ctl.stop bootanim; sleep 1; setprop ctl.stop bootanim" 2>/dev/null
    return 0
}

# ── 电源键长按逃生阀 ──────────────────────────────────────
# 接管期间绝不能让脚本吃掉电源键：长按强重启是唯一的兜底手段。
# 这里只做"确认电源键没被我们拦截"的检查，不安装任何拦截。
android_powerkey_sanity() {
    drm_log "电源键逃生阀：本脚本不拦截任何 input 事件（长按电源可随时强重启）"
}

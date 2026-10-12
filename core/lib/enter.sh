#!/bin/sh
# core/lib/enter.sh — "进入 Linux"的唯一时序实现。
#
# ══ 为什么抽成函数 ══
# 重构前有两个入口做同一件事，但实现不同：
#   · 安卓侧（参考仓库 ade.sh）  用 droidspaces run 驱动容器
#   · 容器侧（本仓库 desk-takeover.sh）用 adb 反向驱动安卓
# 两者的 env 块、阶段顺序、回滚策略都不一样，同一台设备上行为不可复现。
#
# 现在：**一套时序，两个前端**。
#   core/switch.sh enter          → 安卓侧前端（APK 走这条）
#   display/desk-takeover.sh      → 容器侧前端（桌面里走这条）
# 两者都调用 drm_do_enter()。差异只在 lib 内部由 DRM_SIDE 分支处理
# （android_exec / ds_start 都是 side-aware 的）。

# 需要 drm_do_enter 时，调用方应先 source：
#   common.sh device.sh android.sh container.sh display.sh net.sh enter.sh

# 本侧的 Linux 会话**真的**还活着吗？
#
# ★★ 为什么状态文件里的 PHASE=linux-active 不能当判据（实测踩过）：
#    设备重启后 state 文件还在（它在 /data/local/drm-takeover/run/，
#    重启不丢），里面留着上一轮的 linux-active。而接管是**跨侧**的：
#    Android 侧的 PHASE=linux-active 表示"容器里的 KWin 正握着屏"，
#    重启后容器里的会话早就没了，PHASE 却还是 linux-active。
#    原来 cmd_enter 开头只看 PHASE 就 `return 0`（幂等退出），于是
#    **整轮接管根本没跑**，还写了 enter.result=ok 骗过容器侧。
#    现象：接管"瞬间成功"，日志停在设备适配层之后什么都没有。
#
#    所以判据必须是**实据**：安卓侧看"SF/composer 确实被停掉了"，
#    容器侧看"kwin_wayland 确实还握着 card0"。
drm_linux_session_live() {
    if drm_android_side; then
        # 安卓侧：linux-active 的定义就是"安卓显示栈已让出"
        _cs=$(android_svc_state "$DEV_COMPOSER_SVC")
        case "$_cs" in
            stopped|'') return 0 ;;   # 服务已停 = 大概率还在 Linux
            *) return 1 ;;            # 还在 running = 安卓在跑，PHASE 是陈旧的
        esac
    fi
    # 容器侧：本侧就能验
    for _p in $(drm_pids_by_comm kwin_wayland); do
        ls -l "/proc/$_p/fd" 2>/dev/null | grep -q 'dri/card0' && return 0
    done
    return 1
}

drm_do_enter() {
    _ph=$(drm_state_phase)
    case "$_ph" in
        linux-active)
            if drm_linux_session_live; then
                drm_log "已经是 linux-active 且会话健在 —— 幂等退出（要重来先跑 exit）"
                return 0
            fi
            # 陈旧状态：重启后遗留，或上一轮会话已死。必须继续真接管，
            # 否则就是"假成功"（见上面 drm_linux_session_live 的注释）。
            drm_warn "状态是 linux-active 但会话并不存活（composer=$(android_svc_state "$DEV_COMPOSER_SVC")）"
            drm_warn "判定为重启后的陈旧状态 —— 继续执行真接管"
            ;;
        entering|returning)
            drm_die "状态机正忙（$_ph），拒绝并发" ;;
    esac

    drm_state_set PHASE entering
    drm_state_set SINCE "$(drm_ts)"
    drm_state_set LAST_ERROR ""
    drm_state_set MODE "${DRM_MODE:-desktop}"
    drm_state_set FULL_STOP "${FULL_STOP:-0}"

    # ── 0) 体检 ──────────────────────────────────────────
    drm_phase "precheck"
    android_powerkey_sanity
    if drm_android_side; then
        ds_init
        ds_available || drm_die "Droidspaces 不可用：$DS_BIN"
    fi

    # ── 1) 设备专属的"framework 还活着时"修复 ─────────────
    # 有些修复（音量归零、蓝牙复位）必须在安卓 framework 还活着时做，
    # 一旦 stop 就来不及了。参考仓库把这一整段叫 P0，顺序不可调。
    drm_phase "device-pre-stop"
    drm_device_hook dev_pre_stop_fixes

    # ── 2) 解除安卓稳定性守护 ────────────────────────────
    # ★ SF 停 ~120s 后 system_server 自己的 watchdog 线程会杀掉 system_server，
    #   init 级联 SIGKILL wpa_supplicant/netd/zygote ⇒ WiFi 掉线、UI 不可用，
    #   只能强重启。必须在动手之前解除武装。
    drm_phase "disarm-watchdog"
    android_watchdog_disarm

    # ── 3) 关内核 DRM 调试打印 ───────────────────────────
    # 开着的话每次 atomic 提交会打印数百行，帧率直接崩。
    drm_phase "kernel-debug-off"
    android_kernel_debug_off

    # ── 4) 停安卓 ────────────────────────────────────────
    drm_phase "stop-android"
    android_stop_framework      # 默认空操作，保护 audioserver
    android_stop_display

    # ── 5) 等 composer 真正松手 ──────────────────────────
    # ★ 判据是"从 card0 持有者列表消失"，不是 init.svc 变 stopped。
    #   `stop` 不动 class hal，composer 属于 class hal。
    #   它还在的话 kwin 的 ATOMIC 提交报 ret=-13 (EACCES)，
    #   现象是"kwin 起来了、也有 master、就是不出画"。
    drm_phase "wait-composer-release"
    if ! android_wait_composer_release 30; then
        drm_warn "composer 仍持有 $DEV_DRM_CARD —— atomic 提交可能 EACCES"
        drm_warn "继续尝试（kwinwrap 的预清理有时能抢下来）"
    fi

    # ── 6) 安卓侧：起容器 + 把仓库同步进去 ────────────────
    if drm_android_side; then
        drm_phase "container-up"
        ds_start

        drm_phase "stage-payload"
        ds_require_shared

        # ★ 清掉可能残留的请求文件。
        #   正常路径下 cmd_watch 会在停容器**之前**删掉退出请求；但如果上次
        #   是靠长按电源强重启结束的，文件会留在会合目录里 —— 于是这次刚进
        #   Linux，守护一启动就立刻把我们踢回安卓。
        #   进入请求同理：我们自己刚写的那一个已经由 cmd_watch 删掉了，
        #   但可能还有上一次残留的。
        #   （android/enter.sh 里原来也有一段清理，但它清的是 payload 目录
        #     而不是会合目录，属于无效清理。真正的请求文件在会合目录下。）
        _rd=$(drm_rendezvous_local 2>/dev/null) || _rd=""
        if [ -n "$_rd" ]; then
            for _f in exit.request enter.request; do
                if [ -f "$_rd/$_f" ]; then
                    drm_warn "发现残留请求，删除：$_rd/$_f"
                    rm -f "$_rd/$_f" 2>/dev/null
                fi
            done
        fi

        drm_stage_payload_to_container
    fi

    # ── 7) 拉起会话（DRM 交接现场）────────────────────────
    drm_phase "session-up"
    if ! drm_run_session_up; then
        drm_err "会话拉起失败"
        cmd_rollback 2>/dev/null || true
        return 1
    fi

    # ── 8) 验证 ──────────────────────────────────────────
    drm_phase "verify"
    _kwin_ok=$(drm_state_get KWIN_HOLDS_DRM 2>/dev/null || true)
    _plasma_ok=$(drm_state_get PLASMA_OK 2>/dev/null || true)
    _src="本侧 state"

    # ★★ 跨侧：会话拉起跑在**容器**里，写的是容器自己的 /run/.../state，
    #    安卓侧 drm_state_get 读的是 $DRM_ANDROID_PAYLOAD/run/state ——
    #    两个文件根本不是一个。不加这段，_kwin_ok 永远是空字符串，
    #    **每一轮接管都会被自己的验证判死并回滚**。
    #    详细分析见 common.sh 里 drm_session_report_write 的注释。
    if drm_android_side; then
        _rk=$(drm_session_report_get KWIN_HOLDS_DRM 2>/dev/null || true)
        if [ -n "$_rk" ]; then
            _kwin_ok=$_rk
            _plasma_ok=$(drm_session_report_get PLASMA_OK 2>/dev/null || true)
            _src="容器会话报告"
        else
            _src="容器会话报告（缺失！）"
        fi
    fi

    if [ "$_kwin_ok" != 1 ]; then
        drm_err "kwin 没有持有 $DEV_DRM_CARD（kwin_holds_drm=${_kwin_ok:-空}，来源：$_src）"
        cmd_rollback 2>/dev/null || true
        return 1
    fi

    drm_state_set PHASE linux-active
    drm_state_set PHASE_AT "$(drm_ts)"
    drm_log "════ 已进入 Linux（kwin 持屏，plasmashell=$_plasma_ok）════"
    return 0
}

# 把仓库本体同步到容器的 /root（容器唯一与安卓共享的目录）
drm_stage_payload_to_container() {
    _sh=$(ds_shared_dir)
    _src=$DRM_ROOT
    _dst="$_sh/droid-drm-takeover"

    # 设备身份与序列号：容器侧 lib 靠这两个文件自动识别设备、建立 adb 通道
    android_query "getprop ro.product.device" 2>/dev/null | tr -d '\r' >"$_sh/.drm-device" 2>/dev/null
    if [ -n "${DRM_ADB_SERIAL:-}" ]; then
        printf '%s\n' "$DRM_ADB_SERIAL" >"$_sh/.drm-serial" 2>/dev/null
    else
        android_query "getprop ro.serialno" 2>/dev/null | tr -d '\r' >"$_sh/.drm-serial" 2>/dev/null
    fi

    [ -d "$_src" ] || { drm_warn "找不到仓库根 $_src，跳过同步"; return 0; }

    rm -rf "$_dst" 2>/dev/null
    mkdir -p "$_dst" 2>/dev/null
    # ★ input/ 必须一起同步：drm-keys.py（音量键+电源键守护）在里面，
    #   漏掉它的后果是"容器里没有按键守护"，而且失败是静默的
    #   （session-up.sh 里的 install-keys.sh 找不到源文件只会告警）。
    for _d in core linux display input tools configs docs android; do
        [ -d "$_src/$_d" ] && cp -R "$_src/$_d" "$_dst/" 2>/dev/null
    done
    for _f in Makefile README.md; do
        [ -f "$_src/$_f" ] && cp "$_src/$_f" "$_dst/" 2>/dev/null
    done
    if [ -d "$_src/bin" ]; then
        cp -R "$_src/bin" "$_dst/" 2>/dev/null
        drm_log "已同步 bin/（$(ls "$_src/bin" 2>/dev/null | wc -l) 个产物）"
    else
        drm_warn "没有 bin/ —— 容器里没有 kwinwrap 等工具，会话会失败"
        drm_warn "先在仓库里跑 make（CI 会产出 aarch64 的 bin/）"
    fi
    # 可执行位
    chmod +x "$_dst"/core/*.sh "$_dst"/core/lib/*.sh 2>/dev/null
    chmod +x "$_dst"/linux/*.sh "$_dst"/display/*.sh "$_dst"/android/*.sh 2>/dev/null
    find "$_dst/bin" -type f -exec chmod +x {} \; 2>/dev/null
    drm_log "仓库已同步到容器 $_dst"
}

# 拉起会话：安卓侧通过 droidspaces run，容器侧直接本地执行
drm_run_session_up() {
    if drm_android_side; then
        # ★ 必须是**容器内**的路径。ds_shared_dir 给的是安卓侧的
        #   `<rootfs>/root`，塞进 ds_exec 会在容器里找不到文件。
        _sess="$(ds_repo_in_container)/linux/session-up.sh"
        if ! ds_exec "[ -f '$_sess' ]" >/dev/null 2>&1; then
            drm_err "容器里没有 $_sess —— 仓库没同步成功？"
            return 1
        fi
        drm_log "在容器内执行会话拉起（此后屏幕归属 Linux）"
        ds_exec "DRM_SIDE=container DRM_DEVICE=$DRM_DEVICE DRM_WAYLAND_SOCKET=${DRM_WAYLAND_SOCKET:-taketest} DRM_NET=${DRM_NET:-1} sh '$_sess'"
    else
        _sess="$DRM_ROOT/linux/session-up.sh"
        [ -f "$_sess" ] || { drm_err "找不到 $_sess"; return 1; }
        drm_log "本地执行会话拉起（此后屏幕归属 Linux）"
        DRM_SIDE=container DRM_DEVICE="$DRM_DEVICE" \
        DRM_WAYLAND_SOCKET="${DRM_WAYLAND_SOCKET:-taketest}" \
        DRM_NET="${DRM_NET:-1}" \
            sh "$_sess"
    fi
}

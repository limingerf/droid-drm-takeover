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

drm_do_enter() {
    _ph=$(drm_state_phase)
    case "$_ph" in
        linux-active)
            drm_log "已经是 linux-active —— 幂等退出（要重来先跑 exit）"
            return 0 ;;
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

        # ★ 清掉可能残留的"返回安卓"请求。
        #   正常路径下 cmd_watch 会在停容器**之前**删掉它；但如果上次是靠
        #   长按电源强重启结束的，文件会留在共享目录里 —— 于是这次刚进
        #   Linux，守护一启动就立刻把我们踢回安卓。
        #   （android/enter.sh 里原来也有一段清理，但它清的是 payload 目录
        #     而不是共享目录，属于无效清理。真正的请求文件在共享目录下。）
        _req="$(ds_shared_dir)/.drm-exit-request"
        if [ -f "$_req" ]; then
            drm_warn "发现上次残留的退出请求，删除：$_req"
            rm -f "$_req" 2>/dev/null
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
    _kwin_ok=$(drm_state_get KWIN_HOLDS_DRM 2>/dev/null || echo 0)
    _plasma_ok=$(drm_state_get PLASMA_OK 2>/dev/null || echo 0)
    if [ "$_kwin_ok" != 1 ]; then
        drm_err "kwin 没有持有 $DEV_DRM_CARD（kwin_holds_drm=$_kwin_ok）"
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
    for _d in core linux display tools configs docs android; do
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
        _sh=$(ds_shared_dir)
        _sess="$_sh/droid-drm-takeover/linux/session-up.sh"
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

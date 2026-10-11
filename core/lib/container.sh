#!/bin/sh
# core/lib/container.sh — Droidspaces 容器生命周期。
#
# 只做四件事：可用性判断、启动、停止、在容器内执行。
# 具体容器名/配置路径来自设备适配层（DEV_CONTAINER / DEV_DS_BIN / DEV_DS_CFG）。
#
# 【命名空间事实】（参考仓库实测，对新设备同样成立）
#   · PID ns 独立 —— 安卓侧看到的 kwin pid 与容器内看到的不一样，
#     所以"判断 kwin 是不是本轮起的"绝不能用 pid 比较，要用进程启动时间。
#   · net ns 共享（net_mode=host）—— 所以出网靠安卓 netd 的表，
#     停安卓后没人维护 ⇒ 需要 core/lib/net.sh 的兜底表。
#   · /dev 是 bind_mounts=/dev:/dev 两层叠加（底层 devtmpfs + 顶层安卓 tmpfs），
#     card0 就是这么进容器的。
#
# 【已知副作用，写在这里免得后人重复踩】
#   1. 容器启动会破坏安卓 ueventd 的 netlink ⇒ U 盘/pogo 键盘等热插拔节点
#      全建不出来。**停容器 ≠ 恢复**，只有整机 reboot 能回到干净状态。
#      这正是"返回安卓 = 重启设备"这个设计选择的根本原因。
#   2. 起停容器会断 WiFi（共享 netns，wpa_supplicant 被停、DHCP 重分配）。

DS_BIN=""
DS_CFG=""
DS_NAME=""

ds_init() {
    DS_NAME=${DEV_CONTAINER:-drm}
    DS_BIN=${DEV_DS_BIN:-/data/local/Droidspaces/bin/droidspaces}
    DS_CFG=${DEV_DS_CFG:-/data/local/Droidspaces/Containers/$DS_NAME/container.config}
}

ds_available() {
    [ -x "$DS_BIN" ]
}

ds_require() {
    ds_init
    ds_available || drm_die "找不到 Droidspaces：$DS_BIN（设备适配层 DEV_DS_BIN 是否正确？）"
}

# 容器是否在跑（`show` 里出现名字）
ds_running() {
    ds_init
    ds_available || return 1
    drm_timeout 10 "$DS_BIN" show 2>/dev/null | grep -q "$DS_NAME"
}

# 在容器内执行。★ 统一用 `run /bin/sh -c`，保证 -c 语义一致。
ds_exec() {
    ds_require
    drm_timeout "${DS_EXEC_TIMEOUT:-60}" "$DS_BIN" -C "$DS_CFG" run /bin/sh -c "$1"
}

# 判据是"能 exec"，不是 systemd 全就绪 —— 后者在容器里经常停在 degraded。
ds_wait_exec() {
    _max=${1:-60}
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        ds_exec true >/dev/null 2>&1 && { drm_log "容器可执行（等了 ${_i}s）"; return 0; }
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

ds_systemd_state() {
    ds_exec 'systemctl is-system-running 2>&1' 2>/dev/null | tr -d '\r' | head -1
}

ds_start() {
    ds_require
    if ds_running; then
        _s=$(ds_systemd_state)
        case "$_s" in
            running|degraded)
                drm_log "容器已在运行（systemd=$_s），复用"
                return 0 ;;
        esac
        drm_log "容器在跑但 systemd=$_s，等它就绪（最多 40s）"
        _i=0
        while [ "$_i" -lt 40 ]; do
            ds_exec true >/dev/null 2>&1 && return 0
            sleep 2
            _i=$((_i + 1))
        done
        drm_warn "容器状态异常（$_s），继续尝试"
        return 0
    fi

    drm_log "启动 Droidspaces 容器 $DS_NAME"
    drm_timeout 90 "$DS_BIN" -C "$DS_CFG" start >/dev/null 2>&1
    ds_wait_exec 60 || drm_die "容器起来了但无法 exec（$DS_CFG）"
    drm_state_set CONTAINER_UP 1
}

ds_stop() {
    ds_init
    ds_available || return 0
    ds_running || { drm_log "容器本来就没在跑"; return 0; }

    drm_log "停止 Droidspaces 容器 $DS_NAME"
    drm_timeout 60 "$DS_BIN" -C "$DS_CFG" stop >/dev/null 2>&1
    _i=0
    while [ "$_i" -lt 30 ]; do
        ds_running || { drm_log "容器已停（等了 ${_i}s）"; drm_state_set CONTAINER_UP 0; return 0; }
        sleep 1
        _i=$((_i + 1))
    done
    drm_warn "容器停止超时（30s），继续"
    return 0
}

# 容器 /root ←→ 安卓 /mnt/Droidspaces/<name>/root
# ★ 容器没起时这个目录根本没挂载，往里 push 会"成功"却什么也没写。
ds_shared_dir() {
    printf '%s\n' "${DEV_SHARED:-/mnt/Droidspaces/${DEV_CONTAINER:-drm}/root}"
}

ds_shared_ready() {
    _d=$(ds_shared_dir)
    [ -d "$_d" ] && [ -w "$_d" ]
}

ds_require_shared() {
    ds_shared_ready || drm_die "共享目录不可写：$(ds_shared_dir)（容器没起？）"
}

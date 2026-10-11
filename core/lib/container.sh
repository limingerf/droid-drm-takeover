#!/bin/sh
# core/lib/container.sh — Droidspaces 容器生命周期。
#
# 只做四件事：可用性判断、启动、停止、在容器内执行。
# 具体容器名/配置路径来自设备适配层（DEV_CONTAINER / DEV_DS_BIN / DEV_DS_CFG）。
#
# ══ Droidspaces v6 的 CLI（✔实测 v6.6.0，和旧版不兼容）══
#   启动/停止：  droidspaces --name=DEBIAN start|stop|restart
#   容器内执行： droidspaces --name=DEBIAN run '<整条命令>'
#   进入交互：   droidspaces --name=DEBIAN enter [user]
#   看状态：     droidspaces show           （表格，含 PID）
#                droidspaces --name=X info  （详情）
#   参数顺序随意、长短选项等价、`--k=v` 与 `--k v` 都行。
#   ★ **没有** `-C <config> run <cmd>` 这种用法 —— 旧版才那样。
#   ★ `run` 后面那条命令是**一整个字符串**，由容器里的 shell 解析，
#     所以传 "$1" 时不要再自己加引号。
#
# ══ 命名空间事实 ══
#   · PID ns 独立 —— 安卓侧看到的 kwin pid 与容器内看到的不一样，
#     所以"判断 kwin 是不是本轮起的"绝不能用 pid 比较，要用进程启动时间。
#   · net ns 共享（net_mode=host）—— 容器直接继承安卓网络，
#     所以本设备**不需要** net.sh 的 WiFi 接管（DEV_NET_MODE=host 时跳过）。
#   · /dev **不是** bind_mounts 全量挂载。enable_hw_access=1 给的是容器自己的
#     devtmpfs，Droidspaces 只挑几个节点挂进去（实测 renderD128 + kgsl）。
#     card0 和 /dev/input/* **必须我们自己 mknod**（见 display.sh）。
#     实测 mknod 出来的节点功能完整、权限不受限。
#
# ══ 已知副作用，写在这里免得后人重复踩 ══
#   1. 容器启动会破坏安卓 ueventd 的 netlink ⇒ U 盘/pogo 键盘等热插拔节点
#      全建不出来。**停容器 ≠ 恢复**，只有整机 reboot 能回到干净状态。
#      这正是"返回安卓 = 重启设备"这个设计选择的根本原因。
#   2. 起停容器会断 WiFi（共享 netns，wpa_supplicant 被停、DHCP 重分配）。

DS_BIN=""
DS_CFG=""
DS_NAME=""

ds_init() {
    DS_NAME=${DEV_CONTAINER:-DEBIAN}
    DS_BIN=${DEV_DS_BIN:-/data/local/Droidspaces/bin/droidspaces}
    DS_CFG=${DEV_DS_CFG:-/data/local/Droidspaces/Containers/$DS_NAME/container.config}
}

# ★ 必须先 ds_init：旧实现直接读 $DS_BIN，而它只有 ds_init 才赋值，
#   于是"没调 ds_init 就调 ds_available"永远返回假（验收测试就这么踩过）。
ds_available() {
    ds_init
    [ -x "$DS_BIN" ]
}

ds_require() {
    ds_init
    ds_available || drm_die "找不到 Droidspaces：$DS_BIN（设备适配层 DEV_DS_BIN 是否正确？）"
}

# 容器是否在跑。`show` 是表格（含表头），所以按词匹配容器名。
ds_running() {
    ds_init
    ds_available || return 1
    drm_timeout 10 "$DS_BIN" show 2>/dev/null | grep -q -w "$DS_NAME"
}

# 容器内的 PID（跑着才有）。拿不到返回空。
ds_pid() {
    ds_init
    ds_available || return 1
    _p=$(drm_timeout 10 "$DS_BIN" --name="$DS_NAME" pid 2>/dev/null | tr -d '\r' | head -1)
    case "$_p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$_p"
}

# 在容器内执行。★ v6 把整条命令当一个字符串，交给容器里的 shell 解析。
ds_exec() {
    ds_require
    drm_timeout "${DS_EXEC_TIMEOUT:-60}" "$DS_BIN" --name="$DS_NAME" run "$1"
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

    # v6：首次启动要带 --rootfs，后续启动从 config 读，只给名字即可。
    drm_log "启动 Droidspaces 容器 $DS_NAME"
    if [ -f "$DS_CFG" ]; then
        drm_timeout 120 "$DS_BIN" --config="$DS_CFG" start >/dev/null 2>&1
    else
        drm_timeout 120 "$DS_BIN" --name="$DS_NAME" start >/dev/null 2>&1
    fi
    ds_wait_exec 60 || drm_die "容器起来了但无法 exec（$DS_CFG）"
    drm_state_set CONTAINER_UP 1
}

ds_stop() {
    ds_init
    ds_available || return 0
    ds_running || { drm_log "容器本来就没在跑"; return 0; }

    drm_log "停止 Droidspaces 容器 $DS_NAME"
    drm_timeout 90 "$DS_BIN" --name="$DS_NAME" stop >/dev/null 2>&1
    _i=0
    while [ "$_i" -lt 30 ]; do
        ds_running || { drm_log "容器已停（等了 ${_i}s）"; drm_state_set CONTAINER_UP 0; return 0; }
        sleep 1
        _i=$((_i + 1))
    done
    drm_warn "容器停止超时（30s），继续"
    return 0
}

# 容器里看到的 /root ←→ 安卓侧直接读写的那个目录
# ★ v6 里 rootfs 就是个普通目录，没有 /mnt/Droidspaces 这种挂载点。
#   容器没起时这个目录**依然存在**（不像旧版那样没挂载），所以往里写是安全的。
ds_shared_dir() {
    printf '%s\n' "${DEV_SHARED:-/data/local/Droidspaces/Containers/${DEV_CONTAINER:-DEBIAN}/rootfs/root}"
}

# 共享目录在**容器内部**的路径。
#
# ★ 这是一个反复踩的坑：安卓侧 ds_shared_dir 给的是 `<rootfs>/root`，
#   而容器里同一个目录是 `/root`。把安卓侧那个路径直接塞进 ds_exec，
#   命令是在**容器里**跑的，于是永远找不到文件。
#   实测现象：session-up 预检报
#     "容器里没有 .../rootfs/root/droid-drm-takeover/linux/session-up.sh"
#   而那个文件明明就在（可执行、6175 字节）—— 于是整次接管白白回滚。
#   rootfs 的根就是容器的 `/`，所以 `<rootfs>/root` 恒等于 `/root`。
ds_shared_dir_in_container() {
    printf '/root\n'
}

# 仓库在容器内部的根目录（ds_exec / 容器内脚本用这个，不要用 ds_shared_dir）
ds_repo_in_container() {
    printf '/root/%s\n' "${DRM_PROJECT:-droid-drm-takeover}"
}

# rootfs 的根（容器里看到的 `/`）。
#
# ★ 用途：请求会合目录。它必须落在 rootfs 里、且**不能**在 /root 下 ——
#   因为容器侧对应的是 `/var/lib/droid-drm-takeover`，而桌面用户要能读写。
#   ds_shared_dir 给的是 `<rootfs>/root`（容器 /root，0700 root），
#   往它下面建目录会得到容器里的 `/root/var/lib/...`，与容器侧算出来的
#   `/var/lib/...` **不是同一个地方** —— 请求就永远送不到。
ds_rootfs_dir() {
    _s=$(ds_shared_dir)
    _r=$(dirname "$_s")
    [ -n "$_r" ] && [ "$_r" != "." ] && [ "$_r" != "/" ] || return 1
    printf '%s\n' "$_r"
}

ds_shared_ready() {
    _d=$(ds_shared_dir)
    [ -d "$_d" ] && [ -w "$_d" ]
}

ds_require_shared() {
    ds_shared_ready || drm_die "共享目录不可写：$(ds_shared_dir)"
}

#!/bin/sh
# core/lib/display.sh — DRM/KMS 接管与会话拉起（容器侧执行）。
#
# 这条链的顺序**不能调**（重构前用注释口头约定，现在写进代码）：
#   1. 备好 /dev/dri 节点 + 合成 udev 记录（否则 kwin 的 GPU 枚举拿不到卡）
#   2. 放倒安卓显示栈（SF + 点名停 composer，否则 master 不放）
#   3. 确认 card0 无持有者
#   4. kwinwrap 交接：拿 master → 清安卓遗留 atomic → DROP_MASTER → 降权 → exec kwin
#   5. 强制点亮（stop 时安卓走关机流程把屏灭了）
#   6. kactivitymanagerd（plasmashell 的硬依赖，赌 dbus 自动激活会黑屏）
#   7. plasmashell + xdg-desktop-portal
#
# 【渲染与上屏是两条独立的链】（最容易混淆的地方）
#   上屏 = /dev/dri/card0，由 KWin 的 DRM 后端负责
#   渲染 = /dev/kgsl-3d0，由 Mesa Gallium Freedreno 负责
#   MESA_LOADER_DRIVER_OVERRIDE=kgsl **只影响后者**。

# ── 工具路径 ──────────────────────────────────────────────
DRM_BIN_DIR=""

# ★ 旧实现第一候选是 `$(dirname "$0")/../bin` —— 错的：被 source 时 $0 是
#   **调用方**的路径，算出来的是调用方同级目录，不是本仓库的 bin/。
#   现在以 $DRM_ROOT 为基准（它由 common.sh 在 source 时定好）。
drm_bin_resolve() {
    [ -n "$DRM_BIN_DIR" ] && return 0
    for _c in \
        "${DRM_ROOT:-}/bin" \
        "/root/$DRM_PROJECT/bin" \
        "/opt/$DRM_PROJECT/bin" \
        "/usr/local/lib/$DRM_PROJECT/bin"
    do
        [ -n "$_c" ] && [ -d "$_c" ] && { DRM_BIN_DIR="$_c"; return 0; }
    done
    DRM_BIN_DIR=""
    return 1
}

drm_tool() {
    _t=$1
    drm_bin_resolve
    for _c in "$DRM_BIN_DIR/$_t" "/usr/local/bin/$_t" "/usr/bin/$_t"; do
        [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    done
    return 1
}

# ── 桌面账号 ──────────────────────────────────────────────
#
# ★ 重构前的两条链用了两个不同的写死账号（ade.sh 用 Gold，
#   desk-takeover.sh 用 xieyizhou），同一台设备上互相不认。
#   现在一律运行时解析，适配层只给 hint。
drm_desktop_user_resolve() {
    DESKTOP_USER=${DESKTOP_USER:-${DEV_DESKTOP_USER_HINT:-}}
    [ -n "$DESKTOP_USER" ] || DESKTOP_USER=${SUDO_USER:-}
    [ -n "$DESKTOP_USER" ] || DESKTOP_USER=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
    [ -n "$DESKTOP_USER" ] || DESKTOP_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null)
    [ -n "$DESKTOP_USER" ] || drm_die "解析不出桌面账号（getent/passwd 都没有 uid>=1000 的用户）"

    DESKTOP_UID=$(id -u "$DESKTOP_USER" 2>/dev/null)
    DESKTOP_GID=$(id -g "$DESKTOP_USER" 2>/dev/null)
    DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" 2>/dev/null | cut -d: -f6)
    [ -n "$DESKTOP_HOME" ] || DESKTOP_HOME="/home/$DESKTOP_USER"
    DESKTOP_RUNTIME_DIR=${DESKTOP_RUNTIME_DIR:-/run/user/$DESKTOP_UID}

    drm_log "桌面账号：$DESKTOP_USER (uid=$DESKTOP_UID gid=$DESKTOP_GID home=$DESKTOP_HOME)"
    drm_state_set DESKTOP_USER "$DESKTOP_USER"
    drm_state_set DESKTOP_UID "$DESKTOP_UID"
}

# ── 背光 ──────────────────────────────────────────────────
drm_backlight_node() {
    if [ -n "${DEV_BACKLIGHT:-}" ] && [ -d "/sys/class/backlight/$DEV_BACKLIGHT" ]; then
        printf '%s\n' "$DEV_BACKLIGHT"
        return 0
    fi
    # 运行时发现（适配层没填或填错时的兜底）
    for _b in /sys/class/backlight/*; do
        [ -d "$_b" ] || continue
        basename "$_b"
        return 0
    done
    return 1
}

# ── DRM 设备节点 ──────────────────────────────────────────
#
# ★ 有些厂商（如 piano）把 /dev/dri/card0 从文件系统里删了，但驱动仍在
#   内核里活着。主设备号从 sysfs 读出来后 mknod 重建即可，不需要改驱动。
#   ⚠️ 注意：容器里的 /dev 是"devtmpfs 底层 + 安卓 tmpfs 顶层"叠加，
#      所以"节点不存在"和"节点在但被隐藏"是两回事，一律以 sysfs 为准。

drm_devno_from_sysfs() {
    _dev=$1
    for _p in "/sys/class/drm/$_dev/dev" "/sys/class/drm/card0/$_dev/dev"; do
        if [ -r "$_p" ]; then
            tr ':' ' ' <"$_p"
            return 0
        fi
    done
    return 1
}

drm_mknod_if_missing() {
    _node=$1; _maj=$2; _min=$3
    [ -c "$_node" ] && return 0
    mknod "$_node" c "$_maj" "$_min" 2>/dev/null || {
        drm_warn "mknod $_node c $_maj $_min 失败（权限或 SELinux？）"
        return 1
    }
    drm_log "重建节点 $_node ($_maj:$_min)"
}

# 给 mknod 出来的节点定属主/权限。
#
# ★ 为什么不直接 chmod 666：容器里有 root 和 Gold 两个账号，666 意味着
#   任何用户都能读键盘/触摸（输入设备泄的是按键流）。Droidspaces 自己挂
#   renderD128 时用的是 `root:droidspaces-gpu 660`，我们照抄这个约定：
#   组对了就 660，组不存在（别的 rootfs/别的运行时）才退回 666。
drm_node_own() {
    _node=$1; _grp=${2:-}
    [ -e "$_node" ] || return 0
    if [ -n "$_grp" ] && chgrp "$_grp" "$_node" 2>/dev/null; then
        chmod 660 "$_node" 2>/dev/null
    else
        chmod 666 "$_node" 2>/dev/null
    fi
    return 0
}

drm_ensure_drm_nodes() {
    mkdir -p /dev/dri /dev/input 2>/dev/null

    # card0：优先用适配层的值，再退到 sysfs 实读
    if [ ! -c "${DEV_DRM_CARD}" ]; then
        _dn=$(drm_devno_from_sysfs card0 2>/dev/null)
        if [ -n "$_dn" ]; then
            # shellcheck disable=SC2086
            set -- $_dn
            drm_mknod_if_missing "$DEV_DRM_CARD" "$1" "$2"
        else
            drm_mknod_if_missing "$DEV_DRM_CARD" "$DEV_DRM_MAJOR" "$DEV_DRM_MINOR"
        fi
    fi
    drm_node_own "$DEV_DRM_CARD" "${DEV_DRM_GROUP:-}"

    # renderD128：容器里常缺（它不进 kwin 的上屏路径，但 Mesa/EGL 要用）
    if [ ! -c "${DEV_DRM_RENDER}" ]; then
        _dn=$(drm_devno_from_sysfs renderD128 2>/dev/null)
        if [ -n "$_dn" ]; then
            # shellcheck disable=SC2086
            set -- $_dn
            drm_mknod_if_missing "$DEV_DRM_RENDER" "$1" "$2"
        else
            drm_mknod_if_missing "$DEV_DRM_RENDER" "$DEV_DRM_MAJOR" "$DEV_DRM_RENDER_MINOR"
        fi
    fi
    drm_node_own "$DEV_DRM_RENDER" "${DEV_DRM_GROUP:-}"

    # GPU 渲染节点（kgsl 路线）
    drm_node_own /dev/kgsl-3d0 "${DEV_DRM_GROUP:-}"

    # 其它内核 input 设施：容器里通常没有，缺了会静默降级
    drm_mknod_if_missing /dev/uhid    10 239
    drm_mknod_if_missing /dev/uinput  10 223
    drm_mknod_if_missing /dev/rfkill  10 242
    for _n in /dev/uhid /dev/uinput /dev/rfkill; do
        drm_node_own "$_n" "${DEV_TOUCH_GROUP:-}"
    done
}

# ── 触摸节点 ──────────────────────────────────────────────
#
# ★ 重构前这里遍历 /sys/class/input/input* 找 name==NVTCapacitiveTouchScreen，
#   设备名写死。现在从适配层取 DEV_TOUCH_NAME；适配层留空时，
#   退化为"挑第一个 ID_INPUT_TOUCHSCREEN=1 的节点"。
# ★ eventN 编号每次 boot 都会变，绝不能写死（touchdraw.c 原来默认 event11）。

drm_touch_find_event() {
    _name=${DEV_TOUCH_NAME:-}
    for _d in /sys/class/input/input*; do
        [ -d "$_d" ] || continue
        _n=$(cat "$_d/name" 2>/dev/null)
        if [ -n "$_name" ]; then
            [ "$_n" = "$_name" ] || continue
        else
            # 没有指定名字：要求有 ABS_MT 能力
            [ -f "$_d/capabilities/abs" ] || continue
            grep -q 'abs' "$_d/capabilities/abs" 2>/dev/null || continue
        fi
        for _e in "$_d"/event*; do
            [ -e "$_e" ] || continue
            basename "$_e"
            return 0
        done
    done
    return 1
}

drm_touch_devno() {
    _ev=$1
    _d="/sys/class/input/$_ev/dev"
    [ -r "$_d" ] || return 1
    tr ':' ' ' <"$_d"
}

drm_ensure_touch_node() {
    TOUCH_EVENT=${TOUCH_EVENT:-}
    [ -n "$TOUCH_EVENT" ] || TOUCH_EVENT=$(drm_touch_find_event 2>/dev/null)

    if [ -z "$TOUCH_EVENT" ]; then
        drm_warn "找不到触摸设备（DEV_TOUCH_NAME=${DEV_TOUCH_NAME:-未指定}）——触摸将不可用"
        TOUCH_NODE=""
        return 1
    fi

    TOUCH_NODE=/dev/input/$TOUCH_EVENT
    _dn=$(drm_touch_devno "$TOUCH_EVENT" 2>/dev/null)
    if [ -n "$_dn" ]; then
        # shellcheck disable=SC2086
        set -- $_dn
        TOUCH_MAJOR=$1
        TOUCH_MINOR=$2
        drm_mknod_if_missing "$TOUCH_NODE" "$TOUCH_MAJOR" "$TOUCH_MINOR"
    else
        TOUCH_MAJOR=""
        TOUCH_MINOR=""
    fi
    drm_node_own "$TOUCH_NODE" "${DEV_TOUCH_GROUP:-}"
    drm_log "触摸节点：$TOUCH_NODE (${TOUCH_MAJOR:-?}:${TOUCH_MINOR:-?})"
    drm_state_set TOUCH_EVENT "$TOUCH_EVENT"
    return 0
}

# ── 合成 udev 记录 ────────────────────────────────────────
#
# 【为什么要合成】容器里没有 systemd-udevd 管理这些节点（它们是我们 mknod
#   出来的），libinput/kwin 靠 udev 数据库判断"这是什么设备"。没有记录
#   它们就完全看不见这块屏和这个触摸屏。
#
# ★ 修掉重构前的一个真 bug：card0 / renderD128 / touch 三条记录当时
#   共用 `[ ! -f c226:0 ]` 一个条件——只要 card0 的记录已存在，
#   renderD128 和触摸的记录就永远不再写。现在三条各自独立判断。

# ★★ 2026-10 血泪根因：记录必须是 systemd **标准 udev db 格式**，否则 logind
#   的 TakeDevice 直接失败，而 KWin 只会说一句
#   "failed to open drm device at /dev/dri/card0"——**它自己根本不调 open()**，
#   所以从 KWin 侧怎么查都查不出来。
#
#   链路（systemd 257 logind-session-device.c）：
#     DrmBackend::addGpu → Session::openRestricted → logind TakeDevice
#       → session_device_new → session_device_verify
#         → sd_device_new_from_devnum('c', 226:0)
#         → manager_process_seat_device()  ← 读 udev db
#         → hashmap_get(manager->devices, syspath)
#         查不到就 return -ENODEV（现象：KWin 报 "No such device"）
#
#   我们原来的记录是 `Q:100` 打头、标签用 `H:`、**没有 I: 行**，格式不对，
#   sd_device 读出来是"未初始化"，于是永远 ENODEV。
#   标准格式：I:(usec_initialized) → E:属性 → G:标签 → Q:当前标签 → V:属性版本。
#   `I:` 行是**必须**的：它就是 USEC_INITIALIZED。
#
#   另外 ID_SEAT 必须和会话的 seat 一致，否则 session_device_verify 返回 -EPERM。
_drm_udev_usec() {
    # USEC_INITIALIZED 只要是个非 0 的 usec 值即可
    _s=$(date +%s 2>/dev/null) || _s=1
    printf '%s000000' "$_s"
}

# 从 sysfs 反查真实 DEVPATH（重构前写死 /devices/platform/soc/drm/card0，
# 换设备后是错的；logind 按 syspath 建索引，写错就查不到）
_drm_udev_devpath() {
    _maj=$1; _min=$2; _fallback=$3
    _p=$(readlink -f "/sys/dev/char/${_maj}:${_min}" 2>/dev/null)
    case "$_p" in
        /sys/devices/*) printf '%s' "${_p#/sys}" ;;
        *) printf '%s' "$_fallback" ;;
    esac
}

_drm_write_udev_record() {
    _file=$1; shift
    mkdir -p /run/udev/data 2>/dev/null
    printf '%s' "$1" >"$_file" 2>/dev/null || { drm_warn "写 udev 记录失败：$_file"; return 1; }
    chmod a+r "$_file" 2>/dev/null
    return 0
}

drm_write_udev_records() {
    mkdir -p /run/udev/data 2>/dev/null

    _usec=$(_drm_udev_usec)
    _seat=${DRM_SEAT:-seat0}

    # kwin 的 Hardware 白名单只收 i915/amdgpu/nouveau/vmwgfx；
    # msm_drm 会被判定为"不支持的驱动"直接拒绝。伪装成 vmwgfx。
    # （vmwgfx 在 kwin 里没有额外 quirk，是最安全的选择。）
    _drv=${DEV_DRM_DRIVER_ALIAS:-vmwgfx}
    _card_maj=${DEV_DRM_MAJOR:-226}
    _card_min=${DEV_DRM_MINOR:-0}
    _rend_min=${DEV_DRM_RENDER_MINOR:-128}

    _dp=${DEV_DRM_DEVPATH:-}
    [ -n "$_dp" ] || _dp="/devices/platform/soc/drm/card0"

    # ① card0 —— logind 只认 `card*` 节点（renderD128 会被 detect_device_type
    #    判成 DEVICE_TYPE_UNKNOWN 而 return -ENODEV，这是设计如此，不是 bug）
    #
    # ★ 不再用"已存在就跳过"的守卫：记录内容依赖 DEV_*（尤其 DEVPATH /
    #   ID_SEAT），跳过会留下过期内容；而且下面要打 udev 事件，必须保证
    #   磁盘上的内容就是本次算出来的。
    _dpc=$(_drm_udev_devpath "$_card_maj" "$_card_min" "${_dp%card0}card0")
    _drm_write_udev_record "/run/udev/data/c${_card_maj}:${_card_min}" \
"I:${_usec}
E:DEVPATH=${_dpc}
E:MAJOR=${_card_maj}
E:MINOR=${_card_min}
E:SUBSYSTEM=drm
E:DEVTYPE=drm_minor
E:DEVNAME=dri/card0
E:DRIVER=${_drv}
E:ID_SEAT=${_seat}
E:ID_PATH=platform-drm-card0
G:seat
G:uaccess
Q:1
V:1
"

    # ② renderD128（KWin 用它做渲染，不走 logind）
    _dpr=$(_drm_udev_devpath "$_card_maj" "$_rend_min" "${_dp%renderD*}renderD128")
    _drm_write_udev_record "/run/udev/data/c${_card_maj}:${_rend_min}" \
"I:${_usec}
E:DEVPATH=${_dpr}
E:MAJOR=${_card_maj}
E:MINOR=${_rend_min}
E:SUBSYSTEM=drm
E:DEVTYPE=drm_minor
E:DEVNAME=dri/renderD128
E:DRIVER=${_drv}
E:ID_SEAT=${_seat}
E:ID_PATH=platform-drm-renderD128
G:seat
G:uaccess
Q:1
V:1
"

    # ③ 触摸屏 —— 按**本次发现的** event 名与主次号写
    if [ -n "${TOUCH_MAJOR:-}" ] && [ -n "${TOUCH_MINOR:-}" ]; then
        _f="/run/udev/data/c${TOUCH_MAJOR}:${TOUCH_MINOR}"
        _grp=${DEV_TOUCH_GROUP:-}
        [ -n "$_grp" ] || _grp="${TOUCH_MAJOR}/${TOUCH_MINOR}"
        _cal=""
        [ -n "${DEV_TOUCH_CALIB:-}" ] && _cal="E:LIBINPUT_CALIBRATION_MATRIX=${DEV_TOUCH_CALIB}
"
        _dtp=$(_drm_udev_devpath "$TOUCH_MAJOR" "$TOUCH_MINOR" "/devices/virtual/input/${TOUCH_EVENT}")
        _drm_write_udev_record "$_f" \
"I:${_usec}
E:DEVPATH=${_dtp}
E:MAJOR=${TOUCH_MAJOR}
E:MINOR=${TOUCH_MINOR}
E:SUBSYSTEM=input
E:DEVNAME=input/${TOUCH_EVENT}
E:ID_INPUT=1
E:ID_INPUT_TOUCH=1
E:ID_INPUT_TOUCHSCREEN=1
E:ID_SEAT=${_seat}
E:LIBINPUT_DEVICE_GROUP=${_grp}:${DEV_TOUCH_NAME:-touch}
${_cal}G:seat
G:uaccess
Q:1
V:1
"
    fi

    chmod -R a+rX /run/udev 2>/dev/null

    # ★★ 关键一步，缺了整个接管必失败：**光写 udev 数据库不够**。
    #
    #   logind 是 udev 的**监控客户端**，它的 manager->devices 哈希表由
    #   **udev 事件**填充（manager_process_seat_device）。只写
    #   /run/udev/data 而不发事件，logind 的表里就没有这个设备：
    #       session_device_verify()
    #         → hashmap_get(m->devices, syspath) == NULL
    #         → 回退自己 process 一次，仍为 NULL
    #         → return -ENODEV
    #   现象是 KWin 报 `Failed to open /dev/dri/card0 device (No such device)`，
    #   而 `udevadm info` 一切正常 —— 极易误判成"记录格式不对"。
    #   实测：补上这一条 trigger，同一个错误立刻从 ENODEV 变成 EBUSY
    #   （EBUSY 说明 logind 已经走到 ioctl(DRM_IOCTL_SET_MASTER)，只是安卓
    #    composer 还占着 master —— 这正是接管必须先停 composer 的原因）。
    drm_udev_trigger_add
    drm_log "udev 合成记录就绪（card0 / renderD128 / ${TOUCH_EVENT:-无触摸}）"
}

# 给 DRM/input 打 udev "add" 事件，逼 logind 等 udev 客户端重新登记设备。
drm_udev_trigger_add() {
    if ! command -v udevadm >/dev/null 2>&1; then
        drm_warn "容器里没有 udevadm —— logind 不会登记 card0，TakeDevice 会 ENODEV"
        return 1
    fi
    udevadm trigger --action=add --subsystem-match=drm >/dev/null 2>&1
    udevadm trigger --action=add --subsystem-match=input >/dev/null 2>&1
    udevadm settle --timeout=5 >/dev/null 2>&1
    sleep 1
    return 0
}

# ── 停容器里开机自启的桌面会话单元 ───────────────────────
#
# ★ 为什么不能只杀进程（本机实测踩到）：容器里的 desktop-session.service
#   带 `Restart=on-failure` + `RestartSec=2s`。只 kill 掉 plasmashell/kwin，
#   systemd 2 秒内就把整个会话原样拉回来 —— 结果是两套合成器抢同一个面板，
#   现象是"kwin 起来了、master 拿到了、画面闪烁或立刻黑掉"。
#   必须先把 systemd 单元停掉，进程级清理只是兜底。
# ★ 只 stop 不 mask：返回安卓 = 重启设备，重启后容器照常自启，
#   Anland 那套远程桌面还得能用。mask 掉就把用户原来的用法弄坏了。
drm_stop_container_session() {
    _svc=${DEV_SESSION_SVC:-}
    [ -n "$_svc" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0

    if ! systemctl is-active --quiet "$_svc" 2>/dev/null; then
        drm_log "容器桌面会话单元 $_svc 未在运行（跳过）"
        return 0
    fi

    drm_log "停容器桌面会话单元 $_svc（防 systemd 把旧合成器拉回来）"
    drm_timeout 20 systemctl stop "$_svc" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
        drm_warn "$_svc 停不掉（Restart 策略？）—— 交给进程级清理兜底"
    else
        drm_log "$_svc 已停"
    fi
    return 0
}

# ── 杀掉容器侧 Linux 桌面栈 ───────────────────────────────
#
# ★ 顺序要紧：先杀 kwin_wayland_wrapper（KDE 的监督者会补进程），
#   否则永远杀不干净。
#
# ★ 不用 pkill / pgrep / fuser（全部换成 /proc 扫描，见 common.sh）：
#   · fuser 在安卓 toybox 里不存在 —— 原来那条"最后兜底"在设备上是死的
#   · pgrep -f / pkill -f 按整条命令行做正则匹配，会误伤"命令行里恰好
#     提到这个字符串"的无关进程（重构前把 $WIFI_CONF 当模式，连调用方
#     自己的 shell 一起杀了）
drm_kill_linux_stack() {
    drm_log "杀容器侧 Linux 桌面栈"

    # 先停 systemd 单元，否则下面杀多少它补多少
    drm_stop_container_session

    # 第一轮：按命令行特征杀（KDE 监督者必须先死，否则会补进程）
    for _pat in kwin_wayland_wrapper kwinwrap xdg-desktop-portal \
                dmesg-harvester.sh keepbright.sh; do
        _pids=$(drm_pids_by_cmdline "$_pat" | drm_pids_uniq)
        [ -n "$_pids" ] || continue
        drm_log "  kill -9 [$_pat] → $(printf '%s' "$_pids" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        drm_kill_pids 9 $_pids
    done
    # 按精确进程名杀。
    # ★ startplasma-wayland / plasma_session 是会话领头进程，漏了它们
    #   KWin 会被重新拉起（本机实测：desktop-session.service 停掉后
    #   startplasma-wayland 仍在，会重新 exec 一套 kwin）。
    for _name in kwin_wayland plasmashell kactivitymanagerd plasma-keyboard \
                 startplasma-wayland plasma_session kded6 ksmserver \
                 plasma-fallback-session-restore; do
        _pids=$(drm_pids_by_comm "$_name" | drm_pids_uniq)
        [ -n "$_pids" ] || continue
        # shellcheck disable=SC2086
        drm_kill_pids 9 $_pids
    done
    sleep 1

    # 第二轮：三轮"扫描 + 验证重试"，收掉监督者刚补起来的
    _i=0
    while [ "$_i" -lt 3 ]; do
        _alive=$(
            {
                drm_pids_by_comm kwin_wayland
                drm_pids_by_comm plasmashell
                drm_pids_by_cmdline kwinwrap
            } | drm_pids_uniq
        )
        [ -z "$_alive" ] && break
        drm_warn "第 $((_i + 1)) 轮仍有残留：$(printf '%s' "$_alive" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        drm_kill_pids 9 $_alive
        sleep 1
        _i=$((_i + 1))
    done

    # 第三轮兜底：谁还占着 DRM 节点就杀谁
    # （原来是 `fuser -k`，安卓上没有这个命令 ⇒ 兜底从未生效）
    _holders=$(drm_card_fd_holders)
    if [ -n "$_holders" ]; then
        drm_warn "仍有进程占着 $DEV_DRM_CARD：$(printf '%s' "$_holders" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        drm_kill_pids 9 $_holders
        sleep 2
    fi

    # 最后收掉 logind 会话 holder：它只是个 `sleep`，不占 DRM，
    # 上面三轮都抓不到它；不收掉会残留一个 Gold 会话，
    # 下次接管时 drm_logind_session_start 会把它当"活着的"复用。
    drm_logind_session_stop
}

# 谁还持有 DRM 节点（本侧扫描）。
#
# ★ 实现抽在 tools/probe/card-holders.sh —— 见那个文件顶部，那里记着
#   为什么不能用 `sed` 从 `ls -l /proc/*/fd` 里抽 pid（那样恒为空，
#   而"空"会被上层读成"composer 松手了"）。
drm_card_fd_holders() {
    _node=${1:-$DEV_DRM_CARD}
    _h=$(drm_repo_script tools/probe/card-holders.sh 2>/dev/null) || {
        # ★ 不能静默返回空：上层会把"空"读成"没人持有"（= composer 松手了）
        drm_warn "找不到 tools/probe/card-holders.sh —— 无法判断谁持有 $_node"
        return 1
    }
    sh "$_h" "$_node" 2>/dev/null | grep -v -x "$$" 2>/dev/null
}

# ── kwinwrap 交接 ─────────────────────────────────────────
#
# kwinwrap 以 root 完成：拿 master → 预清理安卓遗留 atomic 状态
# （释放它占用的 plane/CRTC、connector DPMS 拉回 On）→ DROP_MASTER →
# initgroups + setuid/setgid 降权 → exec kwin_wayland。
#
# ★ split 几何（双 DSI 分段）：优先让 kwinwrap 运行时发现。
#   重构前 kwinwrap.c 里写死了 piano 的 SPLIT_CRTC=200 / SPLIT_CONN=67 /
#   SPLIT_W=1600 / SPLIT_H=2136 —— 换设备后这些 ID 全错，
#   而且发现失败时会**静默**用错几何（现象是花屏）。
#   现在：先跑 `kwinwrap --probe-split` 拿运行时值，拿不到就显式告警。
drm_kwinwrap_split_env() {
    _kw=$(drm_tool kwinwrap 2>/dev/null) || { drm_warn "找不到 kwinwrap"; return 0; }

    _raw=$("$_kw" --probe-split 2>/dev/null) || true
    case "$_raw" in
        *KWINWRAP_SPLIT_*) ;;
        *)
            drm_warn "kwinwrap --probe-split 无输出：改由 kwinwrap 内部运行时发现"
            drm_warn "（发现失败时它会大声告警，而不是静默使用 piano 的常量）"
            return 0
            ;;
    esac

    # ★ 设备适配层可用 DEV_KWINWRAP_SPLIT_PLANES 覆盖平面列表**与顺序**。
    #
    #   为什么必须能覆盖：运行时发现只能按 id 升序给出 Primary 平面
    #   （本机得到 92,123,127,131），但"哪个 VIG 管驱动哪一段"是硬件固定的。
    #   Android 侧实测（容器里 kmsdump 读，不需要 master）的顺序是
    #       131(src0) 127(src800) 123(src1600) 92(src2400)
    #   —— 与 id 升序**不同**。顺序错了画面会错位/错配。
    #   所以把核对过的顺序固化在 core/device/<机型>.sh 里。
    if [ -n "${DEV_KWINWRAP_SPLIT_PLANES:-}" ]; then
        _raw=$(printf '%s\n' "$_raw" | grep -v '^KWINWRAP_SPLIT_PLANES=')
        _raw="$_raw
KWINWRAP_SPLIT_PLANES=$DEV_KWINWRAP_SPLIT_PLANES"
        drm_log "split 平面顺序由设备适配层固定：$DEV_KWINWRAP_SPLIT_PLANES"
    fi

    # ★ 目的坐标方案也由设备层定：1 = 链路内地址 (0,800,0,800)，
    #   与 Android 实测一致；0 = 全局单调 (0,800,1600,2400)。
    #   取舍理由见 tools/runtime/kwinwrap.c 里 SPLIT_DST_INTERLEAVE 的注释。
    if [ -n "${DEV_KWINWRAP_SPLIT_DST_INTERLEAVE:-}" ]; then
        _raw="$_raw
KWINWRAP_SPLIT_DST_INTERLEAVE=$DEV_KWINWRAP_SPLIT_DST_INTERLEAVE"
        drm_log "split 目的坐标方案：$DEV_KWINWRAP_SPLIT_DST_INTERLEAVE（1=链路内地址）"
    fi

    drm_log "kwinwrap split 几何（运行时发现）："
    printf '%s\n' "$_raw" | while IFS= read -r _l; do
        [ -n "$_l" ] && drm_log "  $_l"
    done

    # ★ 返回值直接拼进 `env VAR=VAL ... $_split_env cmd`，
    #   所以**必须**是裸的 VAR=VAL，不能带 export 前缀
    #   —— 带了的话 env 会去找一个叫 export 的可执行文件。
    #   （重构前这行就是错的：sed 's/^/export /;s/ /; export /g'）
    printf '%s' "$(printf '%s' "$_raw" | tr '\n' ' ')"
}

# ── logind 会话：KWin 能打开 DRM 的**唯一**前提 ─────────────
#
# ★★★ 2026-10 血泪根因（这条卡了整整一轮，而且现象极具误导性）：
#
#   KWin 6.x 打开 DRM 设备**只有一条路**：
#       DrmBackend::addGpu() → Session::openRestricted(fileName)
#   （不是 libc 的 open()！所以拿 LD_PRELOAD 拦 open/openat/stat 会
#     **一个调用都看不到**，而 KWin 只打印一句
#     `kwin_wayland_drm: failed to open drm device at "/dev/dri/card0"`
#     ——"没看到 open"这个负结论会把排查方向彻底带偏。）
#
#   Session::create() 按 **Logind → ConsoleKit → Noop** 顺序取
#   **第一个构造成功的**，而三个实现里：
#     · LogindSession::create()   要求 logind 里能找到"本进程的会话"，
#                                 且 Activate + TakeControl 都成功；
#     · ConsoleKitSession::create() 同理（容器里根本没装 ConsoleKit）；
#     · NoopSession::openRestricted() **硬编码 return -1**
#       （Plasma/6.2 与 6.3 都是；不是配置问题，是设计如此）。
#
#   容器里的会话默认**绑不上 seat**（logind 靠 TTY 绑，容器 /dev/tty* 是假
#   节点，CanTTY=no），于是 logind 的 Activate 返回 -ENOTSUP ⇒ Logind 与
#   ConsoleKit 都返回 nullptr ⇒ **落到 NoopSession ⇒ 永远打不开卡**。
#
#   已实测的解法（pam_systemd 认这几个环境变量）：
#     XDG_SEAT=seat0            → 会话绑到 seat0，Activate 才能成功；
#     XDG_SESSION_CLASS=user    → logind 的 TakeDevice 只对 user/greeter 类
#                                 会话放行，否则报
#                                 "Session class doesn't support taking device control."
#     **绝对不要设 XDG_VTNR**   → 实测设了之后 su 直接建不出会话。
#
#   ★ 重构前用的 `XDG_SESSION_ID=bogus` 是**反效果**：它让 logind 的
#     GetSession 查不到，反而把 KWin 直接推进 NoopSession。
#
#   ★ 会话必须属于桌面用户：logind 的 TakeControl 对"非本会话 uid"要走
#     polkit，而容器里没有 polkit ⇒ 必须 uid 匹配。所以用 `su -`（它的
#     PAM 栈里有 pam_systemd；`runuser -u` 的**没有**，实测建不出会话）
#     以 DESKTOP_USER 建会话，再把会话 id 显式传给以 root 跑的
#     kwinwrap → kwin_wayland。
#
#   ★ 另一个必要条件是 logind 侧的 TakeDevice 要能
#     `ioctl(DRM_IOCTL_SET_MASTER)` 成功 —— 安卓的 composer 还活着时它会
#     返回 EBUSY（现象：KWin 报 "Device or resource busy"）。所以**必须
#     先停掉安卓显示栈**再起 kwin（enter.sh 的顺序就是这个）。
# ── polkit 规则：让桌面用户能 Activate 自己的 logind 会话 ─────
#
# ★★★ 根因（systemd logind + polkit，和"会话"是两件独立的事）：
#   KWin 的 LogindSession::create() **无条件**调 logind 的 Activate，
#   该动作是 org.freedesktop.login1.chvt，polkit 默认策略是
#       allow_any = no / allow_inactive = no / allow_active = yes
#   polkit 判断"active"靠的是**调用进程所属的 logind 会话**
#   （logind 按 PID → cgroup 反查 session-*.scope）。
#   我们的 kwin_wayland 是**安卓侧 watcher 的后代**，不是会话领导 su 的
#   后代 ⇒ polkit 判成 any ⇒ "Interactive authentication required"，
#   而容器里没有认证代理 ⇒ Activate 必失败 ⇒ create() 返回 nullptr ⇒
#   KWin 落到 NoopSession ⇒ openRestricted() 硬编码 return -1 ⇒
#   现象只有一句 `failed to open drm device`。
#
#   ★ 这一条最坑的地方：**同一条命令手工能跑通**——因为手工时是
#     `su - Gold -c kwin_wayland`，KWin 就在会话里，polkit 判成 active
#     直接放行。接管流程里 KWin 从安卓侧 watcher 拉起来，就不在会话里了。
#     所以"手工验证通过"在这里是**假阳性**。
drm_install_polkit_rules() {
    _dir=/etc/polkit-1/rules.d
    [ -d "$_dir" ] || {
        drm_warn "容器里没有 polkit rules.d —— KWin 的 Activate 会被拒，接管必失败"
        return 1
    }
    [ -n "${DESKTOP_USER:-}" ] || { drm_warn "DESKTOP_USER 为空，跳过 polkit 规则"; return 1; }

    _f="$_dir/49-droid-drm-takeover.rules"
    _want="polkit.addRule(function(action, subject) {
    if ((action.id == \"org.freedesktop.login1.chvt\" ||
         action.id == \"org.freedesktop.login1.manage\") &&
        subject.user == \"$DESKTOP_USER\") {
        return polkit.Result.YES;
    }
});
"
    if [ -r "$_f" ] && [ "$(cat "$_f" 2>/dev/null)" = "$_want" ]; then
        drm_log "polkit 规则已是最新（$_f）"
        return 0
    fi

    printf '%s' "$_want" >"$_f" 2>/dev/null || { drm_warn "写 polkit 规则失败：$_f"; return 1; }
    chmod 644 "$_f" 2>/dev/null

    # polkitd 在 rules.d 上挂了 inotify，通常几秒内自动重载；
    # 但接管对时序敏感，直接重启一次拿确定性（此刻桌面栈已被停，无副作用）。
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart polkit >/dev/null 2>&1
        sleep 1
    fi
    drm_log "已安装 polkit 规则（放行 chvt/manage 给 $DESKTOP_USER）：$_f"
    return 0
}

DRM_SESSION_ID=""

drm_logind_session_start() {
    _sidfile="$DRM_RUN_DIR/drm-session-id"
    _pidfile="$DRM_RUN_DIR/drm-session.pid"
    _seat=${DRM_SEAT:-seat0}
    mkdir -p "$DRM_RUN_DIR" 2>/dev/null

    # 复用仍然活着的 holder，避免重复起
    _old=$(cat "$_pidfile" 2>/dev/null)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null && [ -s "$_sidfile" ]; then
        _reuse=$(cat "$_sidfile" 2>/dev/null)
        if [ -n "$_reuse" ]; then
            DRM_SESSION_ID=$_reuse
            export DRM_SESSION_ID
            drm_log "复用已有 logind 会话（id=$_reuse pid=$_old）"
            return 0
        fi
    fi

    rm -f "$_sidfile" 2>/dev/null
    # ★ 这个文件是**以桌面用户身份**写的（su 之后），而 $DRM_RUN_DIR 是
    #   root:root 755 —— 不预建 + 放开写权限的话 Gold 根本写不进去，
    #   于是"会话建不出来"，而且失败得很安静（只是文件一直空着）。
    : >"$_sidfile" 2>/dev/null
    chmod 666 "$_sidfile" 2>/dev/null
    # ★ 环境变量必须在 su 之前设好：pam_systemd 在 su 内部读它们
    env XDG_SEAT="$_seat" XDG_SESSION_CLASS=user XDG_SESSION_TYPE=wayland \
        su - "$DESKTOP_USER" -c \
        "printf '%s' \"\${XDG_SESSION_ID:-}\" >'$_sidfile'; exec sleep 86400" \
        >/dev/null 2>&1 &
    _holder=$!
    printf '%s' "$_holder" >"$_pidfile" 2>/dev/null

    _i=0
    while [ "$_i" -lt 100 ]; do
        [ -s "$_sidfile" ] && break
        sleep 0.1
        _i=$((_i + 1))
    done

    DRM_SESSION_ID=$(cat "$_sidfile" 2>/dev/null)
    if [ -z "$DRM_SESSION_ID" ]; then
        drm_err "建不出 logind 会话（XDG_SEAT=$_seat / XDG_SESSION_CLASS=user）"
        drm_err "  → KWin 会退到 NoopSession，而它的 openRestricted() 硬编码返回 -1，"
        drm_err "    症状是 kwin.log 里 'failed to open drm device' 但全程没有 open() 系统调用"
        kill "$_holder" 2>/dev/null
        rm -f "$_pidfile" 2>/dev/null
        return 1
    fi

    _chk=$(loginctl show-session "$DRM_SESSION_ID" \
        -p Seat -p Class -p Type -p Active 2>/dev/null | tr '\n' ' ')
    drm_log "logind 会话就绪：id=$DRM_SESSION_ID  $_chk"
    case "$_chk" in
        *"Seat=$_seat"*) ;;
        *) drm_warn "会话没有绑到 $_seat（$_chk）—— logind 的 Activate 会失败" ;;
    esac
    case "$_chk" in
        *"Class=user"*) ;;
        *) drm_warn "会话 class 不是 user（$_chk）—— logind 的 TakeDevice 会拒绝" ;;
    esac

    export DRM_SESSION_ID
    return 0
}

drm_logind_session_stop() {
    _pidfile="$DRM_RUN_DIR/drm-session.pid"
    _old=$(cat "$_pidfile" 2>/dev/null)
    [ -n "$_old" ] && kill "$_old" 2>/dev/null
    rm -f "$_pidfile" "$DRM_RUN_DIR/drm-session-id" 2>/dev/null
    DRM_SESSION_ID=""
    return 0
}

drm_start_kwin() {
    _kw=$(drm_tool kwinwrap 2>/dev/null) || drm_die "找不到 kwinwrap（先 make）"
    _sock=${DRM_WAYLAND_SOCKET:-taketest}
    _out=${DRM_LOG_DIR}/kwinatomic.log

    mkdir -p "$DESKTOP_RUNTIME_DIR" 2>/dev/null
    rm -f "$DESKTOP_RUNTIME_DIR/$_sock" "$DESKTOP_RUNTIME_DIR/$_sock.lock" 2>/dev/null
    chown "$DESKTOP_UID:$DESKTOP_GID" "$DESKTOP_RUNTIME_DIR" 2>/dev/null
    chmod 700 "$DESKTOP_RUNTIME_DIR" 2>/dev/null

    # 会话总线（plasmashell 与 portal 都要）
    if [ ! -S "$DESKTOP_RUNTIME_DIR/bus" ]; then
        runuser -u "$DESKTOP_USER" -- env XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            dbus-daemon --session --address="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            --fork --nopidfile 2>/dev/null
        sleep 1
    fi

    # ★ 两件事缺一不可，否则 KWin 一定退到 NoopSession 而打不开卡：
    #   ① polkit 放行 chvt/manage —— 否则 Activate 被拒（见上面的长注释）
    #   ② 一个绑 seat0 的 user 类 logind 会话 —— 否则 TakeDevice 被拒
    drm_install_polkit_rules || drm_warn "polkit 规则没装上，KWin 的 Activate 很可能失败"
    if ! drm_logind_session_start; then
        drm_err "拿不到 logind 会话，KWin 无法打开 $DEV_DRM_CARD"
        return 1
    fi

    # ── 抹掉 KWin 持久化的"合成器已禁用" ─────────────────────────
    #
    # ★★ 实测踩到的坑（症状：面板纯黑，但 DRM 侧一切正常）：
    #   KWin 的 OpenGL 场景一旦初始化失败（日志里那句
    #       kwin_scene_opengl: couldn't find dev node for drm device
    #       kwin_core: Failed to open drm node: ""
    #   ），它会把
    #       [Compositing]
    #       Enabled=false
    #   **写进 $HOME/.config/kwinrc 持久化**。之后哪怕 DRM、EGL、权限
    #   全都恢复正常，KWin 也永远不再合成 —— 输出缓冲全零。
    #
    #   实测证据：CRTC 200 mode_valid=1、两个 Primary 平面都绑上、
    #   fb=316（3200x2000 AR30），但 fbdump 出来的帧**只有一种颜色**（全黑）；
    #   同时 kwinrc 里就是 Enabled=false。
    #
    #   所以每轮接管前必须把这个残留清掉（整行删掉，KWin 会回到默认=开）。
    _kwinrc="$DESKTOP_HOME/.config/kwinrc"
    if [ -f "$_kwinrc" ] && grep -qE '^[[:space:]]*Enabled[[:space:]]*=[[:space:]]*false' "$_kwinrc"; then
        drm_log "清掉 kwinrc 里残留的 [Compositing] Enabled=false（否则合成器永不启动）"
        _ktmp=$(mktemp)
        awk '
            /^\[/ { sect = $0 }
            sect == "[Compositing]" && /^[[:space:]]*Enabled[[:space:]]*=/ { next }
            { print }
        ' "$_kwinrc" > "$_ktmp" && cat "$_ktmp" > "$_kwinrc"
        rm -f "$_ktmp"
        chown "$DESKTOP_UID:$DESKTOP_GID" "$_kwinrc" 2>/dev/null
        drm_log "  kwinrc 现在的 [Compositing] 段：$(sed -n '/^\[Compositing\]/,/^\[/p' "$_kwinrc" | tr '\n' ' ')"
    fi

    # ── kwin 的语言环境 ───────────────────────────────────
    #
    # 接管轮的 kwin/plasma 由 kwinwrap 拉起，**不过 PAM**，所以 pam_env 灌给常态
    # 桌面的 /etc/default/locale、/etc/environment 在这里是缺的。缺了最直观的
    # 现象是界面全变英文（kwin/plasma 报 "Detected locale C ... 不是 UTF-8"）。
    # 只挑语言/光标/主题三类，**绝不整份照搬** —— 那会把 MESA_* 带进去，见下。
    # ── ★★★ kwin 的渲染环境：只留 MESA_LOADER_DRIVER_OVERRIDE=kgsl ────
    #
    # 输出和渲染是两条独立的链，别混：
    #   上屏（KMS 提交）= /dev/dri/card0，KWin 的 DRM 后端
    #   渲染（画像素）  = /dev/kgsl-3d0，Mesa Gallium Freedreno
    # MESA_LOADER_DRIVER_OVERRIDE 只影响后者，**既不负责拿 DRM master，
    # 也不替代 KWIN_DRM_DEVICES 的 KMS 输出路径**。
    #
    # ★ 实测（本机，两条对照）：
    #   保留 MESA_LOADER_DRIVER_OVERRIDE=kgsl → Mesa 加载 kgsl_dri.so
    #     （Gallium 驱动就是 freedreno），KWin 报 freedreno/Adreno 硬件渲染，
    #     日志里**没有** ZINK 报错。
    #   把它 unset 掉 → Mesa 找不到匹配的 DRI 驱动，退回 ZINK，
    #     报 `ZINK: vkEnumeratePhysicalDevices failed (VK_ERROR_INITIALIZATION_FAILED)`
    #     `ZINK: failed to choose pdev` ⇒ 渲染链直接废掉。
    #   所以这里**必须显式设上**，不能靠容器环境碰巧继承。
    #
    # ★ 但 GALLIUM_DRIVER / FD_FORCE_KGSL 要摘掉：它们是同一件事的**旧写法**，
    #   和 loader override 同时存在会打架（参考实现记录过
    #   `kgsl_bo_new_dmabuf: Failed to allocate dma-buf` × 544 帧，
    #   现象从花屏变成纯黑且无法回滚）。
    #
    # ★ 判断 GPU 到底有没有用上，看 KWin 的 OpenGL renderer
    #   （freedreno/Adreno = 硬件，llvmpipe = 软件），**不要看日志措辞**：
    #   `kwin_core: Failed to open drm node: ""` 和
    #   `kwin_scene_opengl: couldn't find dev node for drm device`
    #   都是**节点发现噪音**，不代表软件渲染，别去追（参考实现已明确记录）。
    _loc_env=""
    for _lf in /etc/default/locale /etc/environment; do
        [ -r "$_lf" ] || continue
        while IFS= read -r _line; do
            case "$_line" in ''|\#*) continue ;; esac
            case "$_line" in *=*) ;; *) continue ;; esac
            case "$_line" in
                LANG=*|LC_*=*|XCURSOR_SIZE=*|QT_QPA_PLATFORMTHEME=*)
                    _loc_env="$_loc_env $_line" ;;
            esac
        done <"$_lf"
    done

    # ★ 分屏开关：DEV_KWINWRAP_NO_SPLIT=1 时让 KWin 的原始提交透传，
    #   不再拆成两个半屏。依据见 core/device/opd2511.sh 里的长注释。
    _nosplit_env=""
    [ -n "${DEV_KWINWRAP_NO_SPLIT:-}" ] && _nosplit_env="KWINWRAP_NO_SPLIT=1"

    _split_env=$(drm_kwinwrap_split_env 2>/dev/null | head -1)

    # 设备适配层可以往 kwin 进程里注入环境变量（空格分隔的 K=V），
    # 专门留给对照实验用，例如：
    #   DEV_KWIN_ENV="KWIN_COMPOSE=Q"            强制软件合成
    #   DEV_KWIN_ENV="MESA_LOADER_DRIVER_OVERRIDE=freedreno"  换 GL 驱动
    # 注意别把 KWIN_DRM_DEVICES / HOME / XDG_* 覆盖掉。
    _kwin_env="${DEV_KWIN_ENV:-}"
    [ -n "$_kwin_env" ] && drm_log "注入 kwin 环境变量：$_kwin_env"

    drm_log "kwinwrap 交接 → kwin_wayland --drm --socket=$_sock（会话 $DRM_SESSION_ID）"
    [ -n "$_nosplit_env" ] && drm_log "分屏改写已禁用（DEV_KWINWRAP_NO_SPLIT=1）：KWin 原始提交透传"
    # shellcheck disable=SC2086
    env KWINWRAP_HIJACK=1 KWINWRAP_SECCOMP=1 KWINWRAP_FILTER=1 \
        KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
        KWINWRAP_BRIGHTNESS="$DEV_BRIGHTNESS" \
        $_nosplit_env \
        $_split_env \
        "$_kw" --out "$_out" -- \
        env -u DISPLAY -u WAYLAND_DISPLAY -u ANLAND -u ANLAND_SOCKET \
            -u ANLAND_DRM_DEVICE \
            -u GALLIUM_DRIVER -u FD_FORCE_KGSL \
            -u MESA_DEBUG -u LIBGL_ALWAYS_SOFTWARE -u TU_DEBUG \
            MESA_LOADER_DRIVER_OVERRIDE=kgsl \
            QT_LOGGING_RULES="kwin_scene_opengl.debug=true;kwin_drm.debug=true" \
            $_loc_env \
            HOME="$DESKTOP_HOME" \
            KWIN_DRM_DEVICES="$DEV_DRM_CARD" \
            FD_MESA_DEBUG=noubwc \
            KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
            XDG_SESSION_ID="$DRM_SESSION_ID" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            $_kwin_env \
            kwin_wayland --drm --socket="$_sock" $DEV_KWIN_EXTRA_ARGS \
        >>"${DRM_LOG_DIR}/kwin.log" 2>&1 &
    KPID=$!
    drm_state_set KWIN_PID "$KPID"

    sleep 6
    if ! kill -0 "$KPID" 2>/dev/null; then
        drm_err "kwin 早退（见 ${DRM_LOG_DIR}/kwin.log）"
        tail -n 20 "${DRM_LOG_DIR}/kwin.log" >&2 2>/dev/null
        return 1
    fi
    drm_log "kwin 已启动（pid=$KPID）"
    return 0
}

drm_wayland_selfcheck() {
    _sock=${DRM_WAYLAND_SOCKET:-taketest}
    if ! command -v wayland-info >/dev/null 2>&1; then
        drm_warn "没有 wayland-info，跳过 socket 自检"
        return 0
    fi
    # ★ `drm_timeout` 是 **shell 函数**，不是可执行文件，**不能**写在 `env`/`runuser`
    #   后面 —— 那样 env 会去找一个叫 drm_timeout 的程序，报
    #   `env: 'drm_timeout': No such file or directory` 并返回非 0，
    #   于是自检 100% 必失败、**每次接管都无条件回滚**，哪怕 KWin 已经成功接管
    #   显示。必须把它套在**整条命令的最外层**。
    drm_timeout 8 runuser -u "$DESKTOP_USER" -- env -u DISPLAY \
        WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
        XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" QT_QPA_PLATFORM=wayland \
        wayland-info >"${DRM_LOG_DIR}/wayland-info.log" 2>&1
    if [ $? -ne 0 ]; then
        drm_err "wayland-info 连不上合成器（socket=$_sock）"
        return 1
    fi
    drm_log "wayland socket 自检通过"
    return 0
}

# 强制点亮：stop 时安卓走关机流程会把 connector DPMS 拉 Off 并灭背光，
# kwin 的新 commit 不一定把它拉回来 ⇒ 现象是"有模式、有提交、屏是黑的"。
#
# ★★ 重要限制（实测 2026-10-12）：本函数在 kwinwrap 交接**之后**才跑，
#    而那时 **KWin 已经是 DRM master**（kwinwrap DROP_MASTER 后它按
#    "首开者"规则成为 master）。非 master 写 connector 属性一律 EACCES：
#        setprop: set DPMS=0  -> -1 (Permission denied)
#        setbright 2048       -> -1 (Permission denied)
#    所以**别指望这个函数救黑屏** —— 它只是尽力而为的补充。
#    真正把 DPMS 拉回 On 的地方是 tools/runtime/kwinwrap.c 里对
#    KWin 提交的 DPMS 注入（见那边的 conn_dpms_prop 注释），
#    因为那才是唯一"拿着 master fd 写属性"的时间窗。
#
#    ⚠️ 原来这里把两个工具的**输出和返回值全丢进 /dev/null**，
#    失败完全不可见。曾经因此把"权限不足、什么都没写"误读成"已强制点亮"。
#    现在失败会记进日志。
drm_force_display_on() {
    # ── ① sysfs 背光：这条**不需要 DRM master**，是接管态下唯一有效的路 ──
    #
    #   bl_power=4（FB_BLANK_POWERDOWN）是安卓关机流程留下的**硬关背光电源**，
    #   与 DPMS 是两条独立的路。实测：只写 brightness 无效
    #   （brightness=2048 而 actual_brightness 仍 0），必须先 bl_power=0。
    _bl=$(drm_backlight_node 2>/dev/null || true)
    if [ -n "$_bl" ]; then
        _bp=/sys/class/backlight/$_bl/bl_power
        if [ -w "$_bp" ]; then
            echo 0 >"$_bp" 2>/dev/null && drm_log "背光上电：bl_power=0（$_bl）"
        fi
        _bn=/sys/class/backlight/$_bl/brightness
        if [ -w "$_bn" ]; then
            echo "$DEV_BRIGHTNESS" >"$_bn" 2>/dev/null && \
                drm_log "背光设值：brightness=$DEV_BRIGHTNESS（$_bl）"
        fi
    else
        drm_warn "找不到背光节点 —— 无法上电（drm_backlight_node 返回空）"
    fi

    # ── ② DRM connector 属性：接管态下必然 EACCES，但非接管态有用 ──
    _sp=$(drm_tool setprop 2>/dev/null) || _sp=""
    if [ -n "$_sp" ]; then
        _o=$("$_sp" 0 DPMS 2>&1) || drm_warn "setprop DPMS 失败（KWin 已是 master？）：$_o"
    else
        drm_warn "找不到 setprop 工具 —— 无法写 connector DPMS"
    fi

    _sb=$(drm_tool setbright 2>/dev/null) || _sb=""
    if [ -n "$_sb" ]; then
        _o=$("$_sb" "$DEV_BRIGHTNESS" 2>&1) || drm_warn "setbright 失败（KWin 已是 master？）：$_o"
    else
        drm_warn "找不到 setbright 工具 —— 无法写面板亮度"
    fi

    # 这两个只读工具的输出是排障依据，留着
    _cp=$(drm_tool crtcstate 2>/dev/null) && "$_cp" >"${DRM_LOG_DIR}/crtcstate.log" 2>&1
    _cn=$(drm_tool connprops 2>/dev/null) && "$_cn" >"${DRM_LOG_DIR}/connprops.log" 2>&1
    return 0
}

# ── 会话 ──────────────────────────────────────────────────
#
# ★ 血泪根因（重构前 README 记录）：plasmashell 硬依赖 kactivitymanagerd，
#   别赌 dbus 自动激活——接管会话里激活超时会让 shell 直接
#   `Aborting shell load`，现象是"kwin 活着、触摸在收、面板有模式，
#   但整屏纯黑"。必须显式拉起 kactivitymanagerd 并等它上总线。
# ★ 另一个坑：kactivitymanagerd 必须带 QT_QPA_PLATFORM=wayland，
#   否则 Qt 找不到平台插件又自杀。

drm_start_desktop() {
    _sock=${DRM_WAYLAND_SOCKET:-taketest}
    _env_file=""
    for _f in /etc/default/locale /etc/environment; do
        [ -r "$_f" ] && _env_file="$_env_file $_f"
    done
    # 从发行版配置现读 locale（重构前写死 zh_CN.UTF-8，换 rootfs 后界面变英文）
    _lang=$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | head -1)
    [ -n "$_lang" ] || _lang=$(sed -n 's/^LANG=//p' /etc/environment 2>/dev/null | head -1)
    [ -n "$_lang" ] || _lang=C.UTF-8

    _kactiv=$(for c in /usr/lib/aarch64-linux-gnu/libexec/kactivitymanagerd \
                     /usr/lib/*/libexec/kactivitymanagerd \
                     /usr/libexec/kactivitymanagerd /usr/bin/kactivitymanagerd; do
                  [ -x "$c" ] && { printf '%s\n' "$c"; break; }
              done)

    if [ -n "$_kactiv" ]; then
        drm_log "拉起 kactivitymanagerd（plasmashell 的硬依赖）"
        setsid nohup runuser -u "$DESKTOP_USER" -- \
            env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS \
                WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                QT_QPA_PLATFORM=wayland LANG="$_lang" \
            "$_kactiv" >>"${DRM_LOG_DIR}/kactivitymanagerd.log" 2>&1 &

        _i=0
        while [ "$_i" -lt 10 ]; do
            if runuser -u "$DESKTOP_USER" -- \
                env XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                    gdbus call --session --dest org.freedesktop.DBus \
                    --object-path /org/freedesktop/DBus \
                    --method org.freedesktop.DBus.ListNames 2>/dev/null \
                | grep -q org.kde.ActivityManager; then
                drm_log "org.kde.ActivityManager 已上总线"
                break
            fi
            sleep 1
            _i=$((_i + 1))
        done
        [ "$_i" -ge 10 ] && drm_warn "kactivitymanagerd 未在 10s 内上总线（plasmashell 可能 Aborting shell load）"
    fi

    drm_log "拉起 plasmashell"
    # ★ Plasma 自己也要 GL：KWin 走软件合成（KWIN_COMPOSE=Q）时它仍会去要
    #   OpenGL 2，失败就弹"Plasma 启动失败"对话框然后退出。
    #   QT_QUICK_BACKEND=software 让 Qt Quick 用自带软件渲染器，
    #   这样整条桌面链路都不依赖 kgsl GL（实测 kgsl 的 GL 输出是竖条噪声）。
    #   设备层可用 DEV_PLASMA_ENV 追加/覆盖。
    [ -n "${DEV_PLASMA_ENV:-}" ] && drm_log "注入 plasma 环境变量：$DEV_PLASMA_ENV"
    setsid nohup runuser -u "$DESKTOP_USER" -- \
        env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u SDL_IM_MODULE \
            -u GLFW_IM_MODULE -u XMODIFIERS \
            WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            QT_QPA_PLATFORM=wayland LANG="$_lang" \
            QT_QUICK_BACKEND="${DEV_QT_QUICK_BACKEND:-software}" \
            ${DEV_PLASMA_ENV:-} \
        plasmashell --replace >>"${DRM_LOG_DIR}/plasmashell.log" 2>&1 &

    # ★ 重构前这里完全没有验证，无论 plasmashell 起没起来都打印 DESKTOP-UP，
    #   结果连续三轮黑屏靠猜。现在给明确判据。
    _i=0
    while [ "$_i" -lt 15 ]; do
        _plpid=$(drm_pids_by_comm plasmashell | head -1)
        if [ -n "$_plpid" ]; then
            drm_log "PLASMA-UP（plasmashell pid=$_plpid）"
            drm_state_set PLASMA_OK 1
            break
        fi
        sleep 1
        _i=$((_i + 1))
    done
    if [ "$_i" -ge 15 ]; then
        drm_err "PLASMA-FAIL：plasmashell 15s 内没起来"
        tail -n 15 "${DRM_LOG_DIR}/plasmashell.log" >&2 2>/dev/null
        drm_state_set PLASMA_OK 0
    fi

    # portal：任务栏"打开应用"依赖它，且必须带 XDG_CURRENT_DESKTOP=KDE
    # 才有 KDE 后端（否则点图标没反应）
    if command -v xdg-desktop-portal >/dev/null 2>&1; then
        setsid nohup runuser -u "$DESKTOP_USER" -- \
            env -u DISPLAY WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
                QT_QPA_PLATFORM=wayland LANG="$_lang" \
            xdg-desktop-portal >>"${DRM_LOG_DIR}/portal.log" 2>&1 &
    fi

    return 0
}

# ── 等"本轮的" kwin 拿到 DRM ──────────────────────────────
#
# ★ 不能用 pid 比较：容器与安卓是两个 pid 命名空间。
#   判据三条：① 持有 dri/card0 ② 进程启动时间 >= 本轮开始时刻
#   ③ 整条链（wrapper → kwinwrap → kwin_wayland）都是本轮的
#   —— 只验 kwin 会被 KDE 监督者补起的旧世代骗到。
drm_wait_kwin_holds_drm() {
    _max=${1:-15}
    _launch_ts=$2
    [ -n "$_launch_ts" ] || _launch_ts=$(date +%s)
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        _h=""
        for _p in $(drm_pids_by_comm kwin_wayland); do
            ls -l "/proc/$_p/fd" 2>/dev/null | grep -q 'dri/card0' || continue
            _st=$(stat -c %Y "/proc/$_p" 2>/dev/null || echo 0)
            [ "$_st" -ge "$_launch_ts" ] || continue
            _pp=$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null)
            _gp=$(awk '{print $4}' "/proc/$_pp/stat" 2>/dev/null)
            _stp=$(stat -c %Y "/proc/$_pp" 2>/dev/null || echo 0)
            _stg=$(stat -c %Y "/proc/$_gp" 2>/dev/null || echo 0)
            [ "$_stp" -ge "$_launch_ts" ] || continue
            [ "$_stg" -ge "$_launch_ts" ] || continue
            _h=$_p
            break
        done
        if [ -n "$_h" ]; then
            drm_log "kwin 已持有 $DEV_DRM_CARD（pid=$_h，等了 ${_i}s）"
            drm_state_set KWIN_HOLDS_DRM 1
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    drm_err "等 ${_max}s 仍没有本轮的 kwin 持有 $DEV_DRM_CARD"
    drm_state_set KWIN_HOLDS_DRM 0
    return 1
}

# ── 输入设备就位 ──────────────────────────────────────────
#
# ★ 必须**循环重打** udev change：kwin 刚起时在初始化输入，单次会被丢。
# ★ 必须包含触摸屏：只等键盘+触控板的话，kwin 一拾取它们就退出循环，
#   触摸屏永远进不来。
drm_input_settle() {
    _i=0
    while [ "$_i" -lt 20 ]; do
        _ok=1
        _seen=0
        for _p in $(drm_pids_by_comm kwin_wayland); do
            _seen=1
            _fds=$(ls -l "/proc/$_p/fd" 2>/dev/null)
            case "$_fds" in *event*) ;; *) _ok=0 ;; esac
        done
        # ★ 一个 kwin 都没有时，上面的 for 循环体根本不执行、_ok 会一直是 1，
        #   于是"输入就位"变成无条件成功。必须显式区分"没进程"。
        [ "$_seen" = 1 ] || _ok=0
        [ "$_ok" = 1 ] && [ "$_i" -gt 2 ] && break
        udevadm trigger --action=change --subsystem-match=input 2>/dev/null
        sleep 1
        _i=$((_i + 1))
    done
    drm_log "输入设备重打 udev 完成（$_i 轮）"
    return 0
}

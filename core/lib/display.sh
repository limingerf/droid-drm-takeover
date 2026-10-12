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
    # ★ 附加组列表必须在**容器内**算好再传给 kwinwrap。
    #   原因：kwinwrap 跑在 Android **宿主**侧，它读到的 /etc/group 是宿主的，
    #   里面没有容器桌面账号 ⇒ 靠 kwinwrap 自己解析 /etc/group 拿不到
    #   996(input) 这些组。实测后果：KWin 的 `Groups:` 为空，
    #   /dev/input/event*（root:input 660）打不开，**电源键不响应**。
    #   这里用 id -G 拿到全部组，kwinwrap 直接 setgroups() 用。
    DESKTOP_GROUPS=$(id -G "$DESKTOP_USER" 2>/dev/null | tr ' ' ',')
    [ -n "$DESKTOP_GROUPS" ] || DESKTOP_GROUPS="$DESKTOP_GID"
    DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" 2>/dev/null | cut -d: -f6)
    [ -n "$DESKTOP_HOME" ] || DESKTOP_HOME="/home/$DESKTOP_USER"
    DESKTOP_RUNTIME_DIR=${DESKTOP_RUNTIME_DIR:-/run/user/$DESKTOP_UID}

    drm_log "桌面账号：$DESKTOP_USER (uid=$DESKTOP_UID gid=$DESKTOP_GID home=$DESKTOP_HOME)"
    drm_log "桌面附加组：$DESKTOP_GROUPS"
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

    drm_ensure_input_nodes
}

# ── 建出内核**全部**输入设备节点 ─────────────────────────────
#
# ★★ 2026-10-12 实测根因：**电源键不响应** ★★
#
#   原来这里只给触摸屏建节点（见下面的 drm_touch_*）。容器里
#   /dev/input 实际只有：
#       crw-rw---- root input 13,69  event5     ← 就这一个
#   而内核 /sys/class/input 里 event0..event9 全都在：
#       event0 gpio-keys        event3 pmic_pwrkey   ← 电源键
#       event2 hall_irq         event5 NVTCapacitiveTouchScreen
#   节点不存在 ⇒ KWin/libinput 根本打不开 ⇒ **按电源键毫无反应**
#   （实测：KWin 只打开了 event5，journal.log 里也只有"触摸节点：event5"）。
#
#   所以这里把 /sys/class/input/event* 全部 mknod 出来。
#   主次号从 /sys/class/input/eventN/dev 实读（"13:69" 形式），
#   不写死 —— eventN 的编号每次 boot 都会变。
#
#   为什么放这儿而不是只建触摸的：电源键、hall 开关这些都是标准
#   input 设备，libinput/logind 需要节点存在才能枚举。
#   建多了无害（内核没有的设备 sysfs 里也不会出现）。
drm_ensure_input_nodes() {
    mkdir -p /dev/input 2>/dev/null
    _made=0
    for _d in /sys/class/input/event*; do
        [ -e "$_d" ] || continue
        _ev=$(basename "$_d")
        _node=/dev/input/$_ev
        [ -c "$_node" ] && continue
        _dev=$(cat "$_d/dev" 2>/dev/null)
        [ -n "$_dev" ] || continue
        _maj=${_dev%%:*}
        _min=${_dev##*:}
        [ -n "$_maj" ] && [ -n "$_min" ] || continue
        drm_mknod_if_missing "$_node" "$_maj" "$_min"
        [ -c "$_node" ] && _made=$((_made + 1))
    done
    # 权限与触摸节点一致（root:<input 组> 660），桌面账号靠附加组访问
    for _d in /dev/input/event*; do
        [ -c "$_d" ] || continue
        drm_node_own "$_d" "${DEV_TOUCH_GROUP:-}"
    done
    drm_log "输入节点：新建 $_made 个，/dev/input 现有 $(ls /dev/input/event* 2>/dev/null | wc -l) 个"
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

    # ★ 目的坐标方案也由设备层定：
    #   0 = **唯一正确**：整屏全局单调 (0,800,1600,2400)。驱动
    #       _sde_crtc_check_plane_layout() 靠 crtc_x >= 1600 判
    #       SDE_LAYOUT_RIGHT（右半屏那对 LM2/LM3），并自己减掉 1600 得到
    #       链路内地址。给链路内坐标会让 4 条平面全判 LEFT ⇒ 全挤进
    #       LM0/LM1 ⇒ 右半屏（DSI1）永远拿不到图层 ⇒ 右半屏全黑。
    #   1 = ✘禁用：链路内地址 (0,800,0,800)，只留作 A/B 对照复现症状。
    #   详见 tools/runtime/kwinwrap.c 文件头"目的坐标"那段。
    if [ -n "${DEV_KWINWRAP_SPLIT_DST_INTERLEAVE:-}" ]; then
        _raw="$_raw
KWINWRAP_SPLIT_DST_INTERLEAVE=$DEV_KWINWRAP_SPLIT_DST_INTERLEAVE"
        drm_log "split 目的坐标方案：$DEV_KWINWRAP_SPLIT_DST_INTERLEAVE（0=整屏全局坐标，唯一正确值）"
    fi

    # ★ zpos 分组（决定 SDE 的 stage 归属：stage = zpos + SDE_STAGE_0）。
    #   硬约束是"每个 (stage, layout) 最多 2 条平面"。本机 4 条平面用 5
    #   （每条各占一个 stage ⇒ 不做 source-split 配对），改动面最小。
    #   详见 tools/runtime/kwinwrap.c 里 SPLIT_ZPOS_MODE 的注释。
    if [ -n "${DEV_KWINWRAP_SPLIT_ZPOS:-}" ]; then
        _raw="$_raw
KWINWRAP_SPLIT_ZPOS=$DEV_KWINWRAP_SPLIT_ZPOS"
        drm_log "split zpos 分组模式：$DEV_KWINWRAP_SPLIT_ZPOS（本机 4 平面用 5）"
    fi

    # ★ 逐帧调试痕迹（BUILT/FBSCAN/DROP-CAND/CONN-ADD…）。
    #   默认关：这些每帧都打，会把 kwinatomic.log 撑到几十 MB。
    #   设备适配层用 DEV_KWINWRAP_TRACE=1 临时打开，查完就撤。
    if [ -n "${DEV_KWINWRAP_TRACE:-}" ]; then
        _raw="$_raw
KWINWRAP_TRACE=$DEV_KWINWRAP_TRACE"
        drm_log "kwinwrap 逐帧调试痕迹：KWINWRAP_TRACE=$DEV_KWINWRAP_TRACE"
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

# ── 触摸屏校准矩阵（必须走 udev 规则，只写 udev db 是无效的）──────
#
# ★★ 2026-10-12 血泪根因（现象：改 DEV_TOUCH_CALIB 毫无反应，触摸位置一直不对）
#
#   display.sh 原先只把 LIBINPUT_CALIBRATION_MATRIX 写进自己合成的
#   /run/udev/data/c13:69 记录里，**但紧接着就触发了 udev**：
#       drm_write_udev_records 里  udevadm trigger --action=add    --subsystem-match=input
#       drm_input_settle 里        udevadm trigger --action=change --subsystem-match=input
#   容器的 systemd-udevd 收到事件后**重新生成这条记录并覆盖我们的**。实测
#   覆盖后的内容是：
#       I:1791793460000000
#       E:ID_INPUT=1 / E:ID_INPUT_TOUCHSCREEN=1 / E:ID_INPUT_KEY=1
#       E:XKBMODEL=pc105 / E:XKBLAYOUT=us / E:BACKSPACE=guess
#       E:LIBINPUT_DEVICE_GROUP=1c/0/0:input/ts
#   —— 是 udevd 的 input_id / keyboard 内建生成的键盘风味记录，
#   **里面没有 LIBINPUT_CALIBRATION_MATRIX** ⇒ 矩阵从来没送到 libinput。
#   （注意它自己也置了 ID_INPUT_TOUCHSCREEN=1，所以触摸"能用但位置错"，
#     很容易误判成"矩阵值算错了"，其实是矩阵压根没生效。）
#
#   正确做法：写成 udev 规则，让 udevd 在生成记录时自己带上这个属性。
#   libinput 读的就是 udev 属性 LIBINPUT_CALIBRATION_MATRIX。
drm_install_touch_udev_rule() {
    _dir=/etc/udev/rules.d
    _f="$_dir/79-droid-drm-takeover-touch.rules"

    if [ -z "${DEV_TOUCH_CALIB:-}" ]; then
        # ★ 必须把旧规则删掉：否则上一次留下的矩阵会一直生效，
        #   "把 DEV_TOUCH_CALIB 清空" 这个动作就变成了静默无效。
        if [ -e "$_f" ]; then
            rm -f "$_f" 2>/dev/null && drm_log "已移除触摸校准规则（DEV_TOUCH_CALIB 为空）：$_f"
            command -v udevadm >/dev/null 2>&1 && {
                udevadm control --reload-rules >/dev/null 2>&1
                udevadm trigger --action=change --subsystem-match=input >/dev/null 2>&1
                udevadm settle --timeout=5 >/dev/null 2>&1
            }
        else
            drm_log "未配置 DEV_TOUCH_CALIB，且无遗留规则，跳过触摸校准"
        fi
        return 0
    fi

    [ -d "$_dir" ] || {
        drm_warn "容器里没有 $_dir —— 触摸校准矩阵无法生效"
        return 1
    }

    # 按设备名匹配（DEV_TOUCH_NAME 实测 NVTCapacitiveTouchScreen）。
    # 名字留空时退化为"所有触摸屏"——对只有一块触摸屏的本机等价。
    # ATTRS{name} 会向上遍历父设备找 name，input5 上就有。
    if [ -n "${DEV_TOUCH_NAME:-}" ]; then
        _match="ATTRS{name}==\"$DEV_TOUCH_NAME\""
    else
        _match="ENV{ID_INPUT_TOUCHSCREEN}==\"1\""
    fi

    _f="$_dir/79-droid-drm-takeover-touch.rules"
    _want="# 由 droid-drm-takeover 生成 —— 触摸校准矩阵
# 设备名: ${DEV_TOUCH_NAME:-<任意触摸屏>}
# 矩阵  : $DEV_TOUCH_CALIB
SUBSYSTEM==\"input\", $_match, ENV{LIBINPUT_CALIBRATION_MATRIX}=\"$DEV_TOUCH_CALIB\"
"

    if [ -r "$_f" ] && [ "$(cat "$_f" 2>/dev/null)" = "$_want" ]; then
        drm_log "触摸校准规则已是最新（$_f）"
    else
        printf '%s' "$_want" >"$_f" 2>/dev/null || {
            drm_warn "写 udev 规则失败：$_f"
            return 1
        }
        chmod 644 "$_f" 2>/dev/null
        drm_log "已安装触摸校准规则（$DEV_TOUCH_CALIB）：$_f"
    fi

    # 重载规则并立刻重打一次 input，让属性马上进 udev db。
    # （drm_input_settle 后面还会再重打若干轮，规则已在，不会被冲掉。）
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1
        udevadm trigger --action=change --subsystem-match=input >/dev/null 2>&1
        udevadm settle --timeout=5 >/dev/null 2>&1
    fi
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
    # ★ 触摸校准矩阵必须走 udev 规则（只写 udev db 会被 udevd 覆盖，见函数注释）
    drm_install_touch_udev_rule || drm_warn "触摸校准规则没装上，触摸位置会不对"
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

    # ── ★ 摘掉 10 位像素格式（防御性措施，不是条纹的修复）──────────
    #
    # ⚠️ 先说清楚：**面板密集彩色条纹的真正修复是
    #    DEV_QT_QUICK_BACKEND=software**（见 core/device/opd2511.sh）。
    #    早先一度把根因判成"位深"，那是**误判** —— 变量隔离实验证明：
    #    KWin 的 freedreno 硬件 GL + 8 位 AR24 缓冲，只要 plasmashell 也走
    #    硬件 GL，fbdump 出来的照样是满屏垂直条纹。位深不是决定因素。
    #
    # 那为什么还留着这个 shim？因为它解决的是一个**真实但次要**的问题：
    #   KWin 的 filterAndSortFormats()
    #   （src/backends/drm/drm_egl_layer_surface.cpp:77）在 AR24 与 AR30
    #   同为 32bpp、前面几条判据全平手时，最后一条按 bitsPerColor 选大的
    #   ⇒ **必然**选 10 位。而本设备的 10 位缓冲内容确实是坏的
    #   （fbdump 读同一个 fb 确认：每 4096 字节只有几十字节非零）。
    #   colorPowerTradeoff 是 PreferEfficiency 还是 PreferAccuracy 都一样，
    #   **没有任何 KWin 配置项能改掉这个偏好**：
    #     KWIN_DRM_PREFER_COLOR_DEPTH 只写连接器 max bpc，不改缓冲格式（已实测无效）。
    #   8 位则是确定健康的（软件合成路径用 AR24，出的桌面完全正确）。
    #   既然 8 位无论如何都够用，就没理由让 KWin 去走那条已知会坏的 10 位路径。
    #
    # 做法：LD_PRELOAD 一个 shim，把 10 位格式从平面的 IN_FORMATS 里摘掉
    #   ⇒ KWin 拿不到 AR30，只能选 AR24。
    #
    # ★ 注意 shim 拦的是 drmModeGetPropertyBlob，不是 drmModeGetPlane：
    #   DrmPlane::updateProperties()（drm_plane.cpp:118-135）在
    #   addFB2ModifiersSupported() 为真时**只读 IN_FORMATS blob**，
    #   p->formats 被完全忽略。本设备实测 DRM_CAP_ADDFB2_MODIFIERS=1，
    #   所以改 p->formats 是空操作。详见 tools/runtime/drmfmt.c 顶部注释。
    #
    # 逃生开关（都在 shim 里读）：DRMFMT_KEEP_10BIT=1 保留 10 位做对照；
    #   DRMFMT_LOG=<path> 落盘每次改写的摘要。
    #
    # ★★ .so 的位置极其要紧：**不能**用 payload 自己的 bin/ ★★
    #   kwinwrap 是 fork 之后 setgid/setuid 到桌面账号（uid 1000）再 exec
    #   kwin_wayland 的，而容器里 /root 是 drwx------（700）。
    #   把 LD_PRELOAD 指到 /root/... 下 ⇒ 桌面账号读不到 ⇒ ld.so 报
    #     `object '...' from LD_PRELOAD cannot be preloaded: ignored`
    #   然后**静默**退化成 10 位（实测踩到：格式仍是 ARGB2101010）。
    #   所以优先用安装到 /usr/local/lib 的那份（全用户可读）。
    #
    # ★ DEV_DRMFMT_DISABLE=1 完全关掉注入（保留 10 位缓冲）。
    #   实测需要这个开关：本机面板是 10 位 DSC 面板，若 DSC 链路按 10 位
    #   配置而缓冲是 8 位，面板解出来就是噪声 —— 所以必须能单独验证
    #   "10 位缓冲 + DSC" 这条路。DEV_DRMFMT_SO 指到不存在的路径**不行**，
    #   那会掉进下面的兜底分支又把它装回来（踩过）。
    _fmt_preload=""
    _fmt_so=""
    if [ "${DEV_DRMFMT_DISABLE:-0}" = "1" ]; then
        drm_log "DEV_DRMFMT_DISABLE=1 —— 不注入 drmfmt.so（保留 KWin 默认位深）"
    else
        for _c in "$DEV_DRMFMT_SO" /usr/local/lib/$DRM_PROJECT/drmfmt.so; do
            [ -n "$_c" ] || continue
            [ -f "$_c" ] || continue
            _fmt_so=$_c
            break
        done
    fi
    # 兜底：payload 自带的那份。只在桌面账号**确实**读得到时才用
    #（比如有人把 payload 装到 /root 之外，或改了 /root 权限）。
    # ★ 关掉注入时**必须也跳过这个兜底**，否则会从 bin/ 里又把它装回来
    #   （实测踩过：DEV_DRMFMT_SO 指到不存在的路径，结果兜底分支生效）。
    if [ -z "$_fmt_so" ] && [ "${DEV_DRMFMT_DISABLE:-0}" != "1" ]; then
        _kw_bin_dir=$(dirname "$_kw" 2>/dev/null)
        if [ -n "$_kw_bin_dir" ] && [ -f "$_kw_bin_dir/drmfmt.so" ]; then
            _fmt_so="$_kw_bin_dir/drmfmt.so"
            drm_warn "drmfmt.so 只找到 payload 里那份（$_fmt_so）"
            case "$_fmt_so" in
                /root/*)
                    drm_warn "它在 /root 下，而 kwin 以桌面账号运行 —— 大概率读不到，"
                    drm_warn "ld.so 会静默忽略 LD_PRELOAD。请跑一次 deploy-all.sh 装到 /usr/local/lib。"
                    ;;
            esac
        fi
    fi

    if [ -n "$_fmt_so" ]; then
        _fmt_preload="LD_PRELOAD=$_fmt_so"
        # shim 现在干的是**限制 KWin 能看到的刷新率**（见 tools/runtime/drmfmt.c
        # 头部注释）。它通过 DRM_MODE_KEEP_HZ 读白名单，所以那个变量必须
        # 跟着 LD_PRELOAD 一起进 kwin 进程 —— 否则 shim 装上了却不作为。
        _fmt_hz=""
        if [ -n "${DEV_DRM_MODE_KEEP_HZ:-}" ]; then
            _fmt_hz="DRM_MODE_KEEP_HZ=$DEV_DRM_MODE_KEEP_HZ"
            drm_log "限制 KWin 候选刷新率：只留 ${DEV_DRM_MODE_KEEP_HZ}Hz"
        else
            drm_log "注入 LD_PRELOAD=$_fmt_so（未设 DEV_DRM_MODE_KEEP_HZ，shim 不干预模式）"
        fi
    else
        # 不致命：只是回到「面板可能有噪声」的旧行为，别让接管整体失败。
        drm_warn "找不到 drmfmt.so，无法限制 KWin 候选刷新率，面板可能仍是彩色条纹"
    fi

    # 设备适配层可以往 kwin 进程里注入环境变量（空格分隔的 K=V），
    # 专门留给对照实验用，例如：
    #   DEV_KWIN_ENV="KWIN_COMPOSE=Q"            强制软件合成
    #   DEV_KWIN_ENV="MESA_LOADER_DRIVER_OVERRIDE=freedreno"  换 GL 驱动
    # 注意别把 KWIN_DRM_DEVICES / HOME / XDG_* 覆盖掉。
    # ★ 设备层排在 _fmt_preload 之后：万一有人显式设了 LD_PRELOAD，以设备层为准。
    _kwin_env="${DEV_KWIN_ENV:-}"
    [ -n "$_kwin_env" ] && drm_log "注入 kwin 环境变量：$_kwin_env"

    drm_log "kwinwrap 交接 → kwin_wayland --drm --socket=$_sock（会话 $DRM_SESSION_ID）"
    [ -n "$_nosplit_env" ] && drm_log "分屏改写已禁用（DEV_KWINWRAP_NO_SPLIT=1）：KWin 原始提交透传"
    # ── ★★★ QT_IM_MODULES=qtvirtualkeyboard：让**合成器**提供 Qt 虚拟键盘 ────
    #
    # 起因：用户要「电源键锁屏」，但锁屏界面弹不出键盘，密码输不进去。
    # kscreenlocker_greet 自己打印了原因：
    #     qt.qpa.wayland: qtvirtualkeyboard currently is not supported at
    #     client-side, use QT_IM_MODULES=qtvirtualkeyboard at compositor-side.
    # ⇒ 锁屏跑在受限会话里，**够不着 maliit**（maliit 是 Wayland input-method
    #   协议，锁屏时被隔离）；它唯一能用的键盘是 Qt 虚拟键盘，而那个必须在
    #   **合成器侧**启用。注意是 **MODULES 复数**，不是 MODULE。
    #
    # ★ 为什么和 maliit 不冲突（设计如此，不是猜的）：
    #   两条链的层次完全不同 ——
    #     maliit     = Wayland input-method 协议，由 KWin fork，服务**非 Qt** 应用
    #                  （Chrome 就是这一类，它只认 Wayland 输入法）
    #     Qt 虚拟键盘 = Qt 进程内的 platforminputcontext 插件，服务 **Qt** 应用
    #   所以这一行不会顶掉 maliit，而是给 Qt 应用多一条键盘路径。锁屏正是 Qt 应用。
    #
    # ★ 前提（缺一不可，均已实测存在）：
    #   .../qt6/plugins/platforminputcontexts/libqtvirtualkeyboardplugin.so
    #   .../qt6/qml/QtQuick/VirtualKeyboard
    #
    # ⚠️⚠️ 血泪教训：这段注释**必须**放在 `env` 命令**外面**。
    #   我第一次把注释插进了 `env ... \` 的续行中间，`#` 会**终止续行**，
    #   整条 env 命令被截断，症状是
    #       display.sh: 1175: LANG=zh_CN.UTF-8: not found
    #       kwinwrap 交接失败
    #   ⇒ KWin 起不来、屏幕全黑。**续行中间绝不能有注释行。**
    #
    # ⚠️ 回退办法：删掉 env 里的 QT_IM_MODULES 那一行即可（锁屏将没有键盘，
    #    但桌面键盘恢复正常）。
    #
    # shellcheck disable=SC2086
    env KWINWRAP_HIJACK=1 KWINWRAP_SECCOMP=1 KWINWRAP_FILTER=1 \
        KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
        KWINWRAP_USER="$DESKTOP_USER" \
        KWINWRAP_GROUPS="$DESKTOP_GROUPS" \
        KWINWRAP_BRIGHTNESS="$DEV_BRIGHTNESS" \
        $_nosplit_env \
        $_split_env \
        "$_kw" --out "$_out" -- \
        env -u DISPLAY -u WAYLAND_DISPLAY -u ANLAND -u ANLAND_SOCKET \
            -u ANLAND_DRM_DEVICE \
            -u GALLIUM_DRIVER -u FD_FORCE_KGSL \
            -u MESA_DEBUG -u LIBGL_ALWAYS_SOFTWARE -u TU_DEBUG -u FD_MESA_DEBUG \
            MESA_LOADER_DRIVER_OVERRIDE=msm \
            QT_IM_MODULES=qtvirtualkeyboard \
            QT_LOGGING_RULES="kwin_scene_opengl.debug=true;kwin_drm.debug=true" \
            $_loc_env \
            HOME="$DESKTOP_HOME" \
            KWIN_DRM_DEVICES="$DEV_DRM_CARD" \
            KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
            XDG_SESSION_ID="$DRM_SESSION_ID" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            $_fmt_preload \
            $_fmt_hz \
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

# ── 容器环境净化 ──────────────────────────────────────────
#
# ★★ 2026-10-12 实测根因：/etc/environment 里的 Anland 时代污染 ★★
#
# 那份文件里同时存在**三个互相冲突的渲染驱动选择**：
#     MESA_LOADER_DRIVER_OVERRIDE=msm     ← 选 msm
#     GALLIUM_DRIVER=kgsl                 ← ★ 又让 Gallium 层走 kgsl
#     FD_FORCE_KGSL=1                     ← ★ 再强制 kgsl
# 外加一批指向**已经死掉的** Anland 显示桥的变量：
#     ANLAND=1
#     ANLAND_SOCKET=/run/display.sock
#     ANLAND_DRM_DEVICE=/dev/dri/renderD128
#     ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
#     WAYLAND_DISPLAY=wayland-0           ← ★ KWin 的 socket 是 taketest，
#                                            没有 wayland- 前缀；这条会把客户端
#                                            指到一个不存在的 socket
#
# 危害（都是实测）：
#   · plasmashell 采样 0.76 s CPU / 10 s（8%）⇒ 净化后 0.09 s / 10 s（1%），
#     负载 2.97 → 2.55。`GALLIUM_DRIVER=kgsl` 把 Mesa 指到了那条连 dma-buf
#     都分配不出来的路径上（kgsl_bo_new_dmabuf 失败 ⇒ 黑屏），一直在慢路径跑。
#   · maliit 虚拟键盘拿到 kgsl ⇒ QSGContext 报
#         depth buffer support missing, expect rendering errors
#         stencil buffer support missing, expect rendering errors
#     表现为键盘刚弹出时任务栏附近有拖影，几秒后自己消失。
#
# ★★ 为什么必须改文件本身，而不是像 _unset_env 那样逐个 env -u ★★
# `env -u` 只对我们脚本**亲自 exec 的进程**有效。而 maliit 是 **KWin 拉起的**
# （kwinrc 的 [Wayland] InputMethod=），plasmashell 的子进程、kded6 的模块、
# 托盘小程序……都不在我们的启动链上，照样读到脏环境。
# 改文件 = 一次修好所有进程，包括我们控制不到的那些。
#
# 幂等：已经干净就什么都不做。
drm_fix_container_env() {
    _envf=/etc/environment

    # 已经干净（没有 kgsl / anland 污染）就直接返回
    if [ -r "$_envf" ] \
       && ! grep -qsE '^(GALLIUM_DRIVER|FD_FORCE_KGSL|ANLAND|ANLAND_SOCKET|ANLAND_DRM_DEVICE|ANLAND_SKIP_IMPLICIT_SYNC_WAIT)=' "$_envf"; then
        drm_log "容器 /etc/environment 已干净，跳过"
        return 0
    fi

    drm_log "净化容器 /etc/environment（摘掉 Anland 时代的 kgsl/anland 污染）"

    # 先备份，便于回溯
    _bak="${_envf}.bak-anland-$(date +%s)"
    cp -a "$_envf" "$_bak" 2>/dev/null && drm_log "  已备份到 $_bak"

    # 从原文件里**抢救**白名单内的变量（上游只放行这几个）
    _keep_lang=$(sed -n 's/^LANG=//p'  "$_envf" 2>/dev/null | head -1)
    _keep_lc=$(  sed -n 's/^LC_ALL=//p' "$_envf" 2>/dev/null | head -1)
    _keep_cur=$( sed -n 's/^XCURSOR_SIZE=//p' "$_envf" 2>/dev/null | head -1)

    {
        printf '# 由 droid-drm-takeover 重写（drm_fix_container_env）。\n'
        printf '# 历史版本被 anland 模式污染：GALLIUM_DRIVER=kgsl / FD_FORCE_KGSL=1\n'
        printf '# 与 MESA_LOADER_DRIVER_OVERRIDE=msm 三者互相冲突，且 ANLAND_*\n'
        printf '# 指向已死的显示桥。详见 core/lib/display.sh 的 drm_fix_container_env。\n'
        printf '# 只保留上游白名单内的变量：LANG / LC_* / XCURSOR_SIZE / QT_QPA_PLATFORMTHEME。\n'
        printf 'LANG=%s\n' "${_keep_lang:-en_US.UTF-8}"
        [ -n "$_keep_lc" ] && printf 'LC_ALL=%s\n' "$_keep_lc"
        printf 'XCURSOR_SIZE=%s\n' "${_keep_cur:-48}"
        printf 'QT_QPA_PLATFORM=wayland\n'
        printf 'QT_QPA_PLATFORMTHEME=kde\n'
    } > "$_envf"

    chmod 644 "$_envf" 2>/dev/null
    chown root:root "$_envf" 2>/dev/null

    # 验证：污染必须消失
    if grep -qsE '^(GALLIUM_DRIVER|FD_FORCE_KGSL|ANLAND)' "$_envf"; then
        drm_warn "  /etc/environment 净化后仍有残留，请人工检查"
    else
        drm_log "  已净化（kgsl/anland 污染全部摘除）"
    fi
    drm_state_set ENV_CLEAN 1
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

    # ★★ 第一步就净化容器环境 ★★
    # 必须在**读取 locale 之前**做，否则读到的是被污染那份里的值；
    # 也必须在**启动 KWin 之前**做，因为 KWin 会 fork 出 maliit/kded6 等
    # 子进程，它们不经过我们的 env -u 链路，只能靠文件本身干净。
    drm_fix_container_env

    _env_file=""
    for _f in /etc/default/locale /etc/environment; do
        [ -r "$_f" ] && _env_file="$_env_file $_f"
    done
    # 从发行版配置现读 locale（重构前写死 zh_CN.UTF-8，换 rootfs 后界面变英文）
    _lang=$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | head -1)
    [ -n "$_lang" ] || _lang=$(sed -n 's/^LANG=//p' /etc/environment 2>/dev/null | head -1)
    [ -n "$_lang" ] || _lang=C.UTF-8

    # ★★ 补齐 KDE 会话环境（2026-10-12 根因）★★
    # 本仓库是**直接 exec plasmashell**，绕过了 startplasma-wayland，
    # 于是整套会话环境变量从来没被建立过。最直接的后果：
    #   · /etc/xdg/menus/ 下**只有 plasma-applications.menu**，没有
    #     applications.menu。KDE 解析菜单名是
    #         ${XDG_CONFIG_DIRS}/menus/${XDG_MENU_PREFIX}applications.menu
    #     缺 XDG_MENU_PREFIX 就去找 applications.menu ⇒ 找不到 ⇒ **启动器全空**。
    #     现象是"输入法/设置/终端/预装软件全不见了"，但实测 102 个 .desktop
    #     与 ksycoca 缓存都在，只是没人去读 —— 不是软件丢了。
    #   · XDG_DATA_DIRS / XDG_CONFIG_DIRS 缺失让 KDE 找不到 share 与配置根。
    #   · KDE_FULL_SESSION / KDE_SESSION_VERSION / DESKTOP_SESSION 影响
    #     部分 KDE 组件的会话判定与面板布局。
    # 这些原本由 startplasma-wayland 负责；我们绕过它，就必须自己补。
    # ★★ 只设上游确认必需的那几条，**不要多设** ★★
    #
    # ★★ 2026-10-12 第二次复盘：掉帧的真正根因是 **locale**，不是 XDG_* ★★
    #
    # 这一段此前写过一版"XDG_DATA_DIRS/XDG_CONFIG_DIRS 让 sycoca 互相作废"的
    # 解释 —— **那个结论是错的，已推翻**。错在测量方法：`ls ksycoca6_*` 会同时
    # 列出两个文件，而 locale 是文件名的一部分：
    #     ksycoca6_en_<hostkey>   ← en_US 会话用的库
    #     ksycoca6_zh_<hostkey>   ← zh_CN 会话用的库
    # 把这两个文件的尺寸交替出现误读成了"同一个库在 350877↔224925 之间震荡"。
    # 实际上它们各自稳定，从未互相覆盖。
    #
    # 真正可复现的事实（A/B 对照，同一台机、同一份配置）：
    #     plasmashell  LANG=en_US.UTF-8   →  15 秒耗 0.00 秒 CPU（桌面空闲）
    #     plasmashell  LANG=zh_CN.UTF-8   →  20 秒耗 14.61 秒 CPU（73%，满屏掉帧）
    # 且 `LC_MESSAGES=zh_CN` 单独设置也会触发（它决定选哪个 sycoca 库），
    # 所以"英文 locale + 中文文案"这条路走不通。
    #
    # gdb 抓到的现场（pid 停在重建里）：
    #     #3 KBuildSycoca::recreate(bool)
    #     #4 KSycocaPrivate::buildSycoca()
    #     #5 KSycocaPrivate::checkDatabase(...)
    #     #6 KSycoca::ensureCacheValid()
    #     #7 KService::serviceByStorageId(QString const&)
    #     #8 libkickerplugin.so          ← Kickoff 开始菜单
    # 配合 /proc/<pid>/io：6 秒写 15.7 MB —— 确实在无限重建 sycoca。
    #
    # 已用实验否掉的两个候选判据（不要再往这两个方向查）：
    #   · 文件 mtime 过旧：把库 mtime 推到 1 小时后，循环照旧（库被立刻覆盖回来）。
    #   · 陈旧 .lock 残留：锁是 kwin_wayland 持有的**活锁**（内容是
    #     21712/kwin_wayland/DEBIAN/…），删掉后 15 秒仍烧 10.88 秒且锁重现。
    # 已定位的贡献者：Kickoff 占一半以上（把它从面板摘掉，73% → 35%），
    # 剩余部分来自其它 applet（任务栏 icontasks 同样要解析 .desktop）。
    # 容器根文件系统是 f2fs + `lazytime`（mtime 延迟落盘），是重要嫌疑但未定案。
    #
    # ⇒ 在 sycoca 循环被真正修掉之前，桌面会话**固定用 en_US.UTF-8**：
    #   这是唯一实测 0% CPU、不掉帧的配置。中文界面暂时放弃，
    #   代价换的是"能用"，而不是"能看中文但卡到不能用"。
    #   ★ 想恢复中文，必须先解决 sycoca 无限重建，不要只把 _lang 改回去。
    _lang=en_US.UTF-8
    if [ "${DEV_DESKTOP_LANG:-}" ]; then
        _lang=$DEV_DESKTOP_LANG
        drm_warn "桌面 locale 被设备层覆盖为 $_lang（若非 en_US.* 可能触发 sycoca 无限重建、严重掉帧）"
    fi

    # ★ 上游 display/desk-takeover.sh 的做法是：**只从 /etc/default/locale 与
    #   /etc/environment 里白名单 LANG=* / LC_*=* / XCURSOR_SIZE=* /
    #   QT_QPA_PLATFORMTHEME=* 四条**，其余一律不注入，并明确注释
    #   "MESA_* / TU_DEBUG 一律不由本脚本注入"。这里对齐上游。
    #
    # ★ 菜单那条继续用 XDG_MENU_PREFIX=plasma- 解决 —— 它只影响菜单文件
    #   的查找名，不参与 sycoca 的搜索路径哈希，因此安全。
    _kde_env="XDG_MENU_PREFIX=plasma-"
    _kde_env="$_kde_env XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland"

    # ★★ 摘掉容器 /etc/environment 里给**原始 Anland 显示桥**写的那批变量 ★★
    # 那份文件被 desktop-session.service 用 `EnvironmentFile=-/etc/environment`
    # 注入每个会话进程，内容是：
    #     MESA_LOADER_DRIVER_OVERRIDE=kgsl
    #     GALLIUM_DRIVER=kgsl
    #     FD_FORCE_KGSL=1
    #     WAYLAND_DISPLAY=wayland-0            ← 残留死 socket
    #     ANLAND=1 / ANLAND_SOCKET=/run/display.sock   ← 原始桥的 socket，已死
    #     ANLAND_DRM_DEVICE=/dev/dri/renderD128
    #     ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
    # 我们的接管把 Anland 换成了 DRM 直驱，但这份设置还在污染每个进程：
    #   · kgsl 那条 Gallium 路径在本机写出来的 buffer 布局是错的（fbdump 只有
    #     约 1% 字节非零）—— 当年"面板彩色条纹"就是它造成的，**不是** plasmashell
    #     的硬件 GL（那个结论已在 2026-10-12 推翻，见设备层注释）。
    #   · ANLAND=1 会让 Anland 感知的组件去找**已经死掉的** /run/display.sock，
    #     拿不到显示/GL ⇒ 应用自己回退软件渲染（现象：系统监视器提示
    #     "已回退软件渲染"）。
    #   · WAYLAND_DISPLAY=wayland-0 指向残留死 socket（我们的会话是 taketest）。
    # ⇒ 全部显式摘掉，别让它们漏进桌面会话和从菜单拉起的应用。
    #   注意 WAYLAND_DISPLAY 不在这里摘 —— 下面每处都显式赋成 $_sock。
    _unset_env="-u GALLIUM_DRIVER -u FD_FORCE_KGSL"
    _unset_env="$_unset_env -u ANLAND -u ANLAND_SOCKET"
    _unset_env="$_unset_env -u ANLAND_DRM_DEVICE -u ANLAND_SKIP_IMPLICIT_SYNC_WAIT"

    _kactiv=$(for c in /usr/lib/aarch64-linux-gnu/libexec/kactivitymanagerd \
                     /usr/lib/*/libexec/kactivitymanagerd \
                     /usr/libexec/kactivitymanagerd /usr/bin/kactivitymanagerd; do
                  [ -x "$c" ] && { printf '%s\n' "$c"; break; }
              done)

    if [ -n "$_kactiv" ]; then
        drm_log "拉起 kactivitymanagerd（plasmashell 的硬依赖）"
        setsid nohup runuser -u "$DESKTOP_USER" -- \
            env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS \
                $_unset_env \
                WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                QT_QPA_PLATFORM=wayland LANG="$_lang" \
                $_kde_env \
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
    # ★★ QT_QUICK_BACKEND=software —— 这是"面板密集彩色条纹"的真正修复 ★★
    #   实测变量隔离：KWin 保持 freedreno 硬件 GL 合成、输出 8 位 AR24 不变，
    #   只把 plasmashell 从硬件 GL 换成软件渲染 ⇒ 条纹消失、出完整 KDE 桌面。
    #   反过来（plasmashell 硬件 GL）就是满屏垂直彩色条纹。
    #   所以设备层默认把 DEV_QT_QUICK_BACKEND 设成 software（见
    #   core/device/opd2511.sh 里的长注释与对照表）。
    #   设备层可用 DEV_PLASMA_ENV 追加/覆盖。
    [ -n "${DEV_PLASMA_ENV:-}" ] && drm_log "注入 plasma 环境变量：$DEV_PLASMA_ENV"
    # ★ 只在显式配置时才注入 QT_QUICK_BACKEND。
    #   早先写成 QT_QUICK_BACKEND="${DEV_QT_QUICK_BACKEND:-software}"，
    #   结果是**永远**注入，硬件 GL 可用时也强行让 Qt Quick 走软件渲染，
    #   白白丢掉加速。现在设备层留空 = 不注入（用 Qt 自己的默认，即 GL）。
    _qtqb=""
    if [ -n "${DEV_QT_QUICK_BACKEND:-}" ]; then
        _qtqb="QT_QUICK_BACKEND=$DEV_QT_QUICK_BACKEND"
        drm_log "Qt Quick 后端固定为 $DEV_QT_QUICK_BACKEND"
    fi

    # ★★ 输入法环境（2026-10-12 重大修正）★★
    #
    # ★★★ 结论：**不要注入 QT_IM_MODULE=fcitx 这一套，也不要跑 fcitx5。** ★★★
    #
    # 历史：重构前这里把 QT_IM_MODULE / GTK_IM_MODULE / XMODIFIERS 全部 `env -u`
    # 摘掉，当时认为"摘掉就没输入法了"，于是改成"装了 fcitx5 就指向它"。
    # 这个改动是**错的**，它是键盘一闪一闪的根因。
    #
    # ★ 实测根因（有完整证据，见 docs/键盘一闪一闪-输入法冲突.md）：
    #   容器里同时装了 fcitx5 和 maliit-keyboard，而 maliit-keyboard 是 KWin
    #   通过 Wayland 的 zwp_input_method_v1 协议拉起来的**合成器级输入法**。
    #   我们又装了 fcitx5-module-wayland，它让 fcitx5 也走 Wayland 输入法协议。
    #   于是同一个文本框被两个输入法同时响应：
    #       应用获得焦点 → KWin 给 maliit 发 activate → 键盘弹出（报高 429）
    #       → fcitx5 的候选窗抢走焦点 → KWin 给 maliit 发 deactivate
    #       → 键盘收起（报高 39）→ 焦点回到应用 → 又 activate → 无限循环
    #   在 kwin.log 里就是这两行交替刷：
    #       keyboard is reporting <x y w h>: < 0 571 1600 429 >
    #       keyboard is reporting <x y w h>: < 0 961 1600 39 >
    #   实测统计：一次会话里 activate 82 次 / deactivate 80 次 /
    #   InputMethodContext 析构 80 次，且循环**自行持续**，无需用户操作。
    #   这就是用户描述的"拖影还会一闪一闪的"。
    #
    # ★ 判决实验：pkill -x fcitx5 之后，30 秒内 "keyboard is reporting"
    #   增长 **0** 次（基线 309 → 309），循环彻底停止。
    #
    # ★ 而且 fcitx5 在这里**根本没被任何应用用上**：实测 /etc/environment、
    #   plasmashell 的环境里都没有 QT_IM_MODULE/GTK_IM_MODULE/XMODIFIERS。
    #   中文拼音是 maliit 自己在做（maliit-keyboard 包自带 zh-hans 插件和
    #   libpinyin 词库），用户已确认"输入法能打字"。
    #   所以 fcitx5 在这里纯粹是制造冲突的负担。
    #
    # ★ 触摸屏要的是**屏幕键盘**，而 fcitx5 不提供虚拟键盘（实测结论），
    #   只有 maliit 能弹。所以正确组合是：**只跑 maliit，不跑 fcitx5。**
    #
    # ★ 想改用 fcitx5 做物理键盘输入法的话，必须**同时**满足两条，否则
    #   又会开始闪：把 maliit 从 kwinrc 的 InputMethod 摘掉（否则两个抢），
    #   并设 DEV_IM_FCITX=1 打开下面的开关。
    _im_env=""
    if [ "${DEV_IM_FCITX:-0}" = 1 ]; then
        _im_env="QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx"
        _im_env="$_im_env SDL_IM_MODULE=fcitx GLFW_IM_MODULE=ibus"
        drm_log "输入法：fcitx5 已启用（DEV_IM_FCITX=1）—— 注意此时必须同时摘掉 kwinrc 的 InputMethod，否则键盘会闪"
    else
        # 默认路径：交给 Wayland 输入法协议（KWin + maliit）。
        # 把 fcitx 的变量摘干净，避免应用去连一个没在跑的 fcitx5。
        _im_env="-u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS"
        _im_env="$_im_env -u SDL_IM_MODULE -u GLFW_IM_MODULE"
        drm_log "输入法：走 Wayland 协议（KWin + maliit），已摘掉 fcitx 变量"
    fi

    setsid nohup runuser -u "$DESKTOP_USER" -- \
        env -u DISPLAY $_unset_env \
            WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            QT_QPA_PLATFORM=wayland LANG="$_lang" \
            $_kde_env \
            $_qtqb \
            $_im_env \
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
            env -u DISPLAY $_unset_env WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
                QT_QPA_PLATFORM=wayland LANG="$_lang" \
                $_kde_env \
            xdg-desktop-portal >>"${DRM_LOG_DIR}/portal.log" 2>&1 &
    fi

    drm_start_input_methods "$_sock" "$_lang" "$_im_env"

    return 0
}

# ── 输入法进程 ────────────────────────────────────────────
#
# ★ 2026-10-12 新增。为什么必须单独拉起：
#   上游 desk-takeover.sh 会起 kded6，kded6 里有输入法模块；
#   本仓库没有 kded6（见待办），所以输入法进程没有任何人拉 ——
#   现象就是用户实测的"**没有输入法弹出屏幕键盘我没法输入密码**"：
#   容器里装了 fcitx5 和 maliit-keyboard，但一个都没在跑。
#
# ★ 两个东西职责完全不同，别混：
#   · fcitx5        —— 输入法**引擎**，服务物理键盘打中文（拼音/五笔）。
#                      不提供虚拟键盘，触摸屏上点了不会弹任何东西。
#   · maliit-keyboard —— KDE 的**屏幕键盘**（OSK）。它注册 Wayland 的
#                      zwp_input_method_v2，KWin 在触摸设备上聚焦文本框时
#                      请求它弹出。**触摸屏输 WiFi 密码靠的是这个。**
#
# ⚠️ 已知冲突：两者都想当 Wayland input-method。本机优先保 maliit
#   （触摸设备第一需求是"能打字"），所以 fcitx5 只用 -d 后台起引擎、
#   靠 QT_IM_MODULE=fcitx 被应用加载，**不让它抢 input-method 协议**。
#   若将来插了物理键盘要主打 fcitx5，应改成用 fcitx5 的虚拟键盘模块
#   并停掉 maliit。
drm_start_input_methods() {
    _sock=$1
    _lang=$2
    _im=$3

    # ── kded6 ────────────────────────────────────────────────
    # ★★ 2026-10-12 实测：本仓库从来没起过 kded6 ★★
    # 上游 desk-takeover.sh 的注释原话："没有它所有 kded 模块都不在 ——
    # 蓝牙托盘图标、配对代理、很多 KDE 功能"。
    # 本机实测缺它的直接后果：
    #   · 系统托盘里没有蓝牙图标（bluedevil.so 是 kded 模块）
    #   · 设备自动挂载、通知、剪贴板同步、触摸板配置全都不工作
    # ⚠️ 关于 WiFi 密钥代理 —— 2026-10-12 勘误：
    #   旧注释写的是"kded6 跑起来也没用，SecretAgent 仍然 no such name，
    #   那个模块提供的是小程序后端不是密钥代理"。**这个结论是错的。**
    #   错在判据：org.freedesktop.NetworkManager.SecretAgent 这个名字
    #   **永远没有 owner** —— NM 的代理协议走 AgentManager.Register()，
    #   代理用唯一名（:1.xxx）注册。
    #   正确判据是 NM 日志出现
    #       agent-manager: agent[.../org.kde.plasma.networkmanagement/1000]:
    #           agent registered
    #   实测：kded6 起来之后**还必须显式 loadModule networkmanagement**
    #   （autoloaded=true 也不会自动加载），加载后代理即注册，
    #   用户在图形界面输一次密码就连上了。
    #   ⇒ 所以下面 kded6 起来后要顺手加载这个模块，见 kded 段落末尾。
    # ★ 放在输入法检查之前：kded6 是独立需求，不能因为没装输入法就跳过。
    if ds_exec 'command -v kded6 >/dev/null 2>&1' >/dev/null 2>&1; then
        if ds_exec 'pgrep -x kded6 >/dev/null 2>&1' >/dev/null 2>&1; then
            drm_log "kded6 已在跑，复用"
        else
            setsid nohup runuser -u "$DESKTOP_USER" -- \
                env -u DISPLAY $_unset_env \
                    WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                    XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                    QT_QPA_PLATFORM=wayland LANG="$_lang" \
                    XDG_MENU_PREFIX=plasma- XDG_CURRENT_DESKTOP=KDE \
                    XDG_SESSION_TYPE=wayland \
                kded6 >>"${DRM_LOG_DIR}/kded6.log" 2>&1 &
            sleep 6
            if ds_exec 'pgrep -x kded6 >/dev/null 2>&1' >/dev/null 2>&1; then
                drm_log "已拉起 kded6（蓝牙托盘/设备通知/自动挂载等 kded 模块就位）"
            else
                drm_warn "kded6 没起来，看 ${DRM_LOG_DIR}/kded6.log"
            fi
        fi
    else
        drm_warn "容器里没有 kded6，跳过"
    fi

    # ── ★★ 加载 networkmanagement kded 模块（WiFi 密钥代理）★★ ──
    # 为什么单独一步：kded6 起来**不会**自动加载这个模块，
    # 即使它的元数据里写着 X-KDE-Kded-autoload、autoloaded 也返回 true。
    # 不加载 ⇒ NM 问遍总线没有代理应答 ⇒ 图形界面点 WiFi 直接失败：
    #     no secrets: No agents were available for this request.
    #     state change: need-auth -> failed (reason 'no-secrets')
    # 加载 ⇒ NM 日志出现
    #     agent-manager: agent[.../org.kde.plasma.networkmanagement/1000]:
    #         agent registered
    # ⇒ 用户在托盘里输一次密码就能连上（这正是用户要的图形界面路径）。
    #
    # ★ kded6 的 DBus 对象路径是 **/kded**，不是 /kded6（后者报 UnknownObject，
    #   会让人误以为 kded6 没起来）。
    # ★ 判据是上面那行 NM 日志，**不是** SecretAgent 名字有没有 owner
    #   （那个名字永远没有 owner）。
    if ds_exec 'pgrep -x kded6 >/dev/null 2>&1' >/dev/null 2>&1; then
        if ds_exec 'command -v qdbus6 >/dev/null 2>&1' >/dev/null 2>&1; then
            _nmload=$(ds_exec "runuser -u $DESKTOP_USER -- env \
                HOME=$DESKTOP_HOME XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR \
                DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
                qdbus6 org.kde.kded6 /kded \
                org.kde.kded6.loadModule networkmanagement" 2>&1 | tr -d '\r')
            if [ "$_nmload" = "true" ]; then
                drm_log "已加载 networkmanagement 模块（WiFi 密钥代理就位，图形界面可提示输密码）"
            else
                drm_warn "加载 networkmanagement 模块返回 '$_nmload'，WiFi 图形界面可能无法提示密码"
            fi
            # 顺手设为自动加载，减少下次依赖
            ds_exec "runuser -u $DESKTOP_USER -- env \
                HOME=$DESKTOP_HOME XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR \
                DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
                qdbus6 org.kde.kded6 /kded \
                org.kde.kded6.setModuleAutoloading networkmanagement true" \
                >/dev/null 2>&1 || true
        else
            drm_warn "容器里没有 qdbus6，无法加载 networkmanagement 模块"
        fi
    fi

    # ── 屏幕键盘：告诉 KWin 用哪个 ────────────────────────────
    # ★★ 2026-10-12 实测：只把 maliit-keyboard 跑起来**不够** ★★
    # 用户反馈"没有输入法弹出屏幕键盘我没法输入密码"。maliit 进程在跑、
    # 也连上了 Wayland，但点文本框不弹 —— 因为 KWin 不知道用哪个 OSK。
    # KWin 读 kwinrc 的 [Wayland] InputMethod=。
    # ★ 另一个实测结论：**fcitx5 不提供虚拟键盘**，弹不出来是正常的 ——
    #   它是输入法引擎（服务物理键盘），触摸屏要的是 maliit。
    #
    # ★★ 2026-10-12 第二次实测：KWin **自己会拉起** InputMethod ★★
    # 只要 kwinrc 里有这两行，KWin 就会 fork 出 maliit 并持有它：
    #     [Wayland]
    #     InputMethod[$e]=/usr/share/applications/com.github.maliit.keyboard.desktop
    #     VirtualKeyboardEnabled=true
    # 实测此时 `pgrep -x maliit-keyboard` 的父进程就是 kwin_wayland。
    # ★ 所以**绝不能再手工起一个** —— 两个键盘窗口重叠会合成出拖影，
    #   症状是"任务栏那有一层拖影，只有刚弹出那几秒有，之后消失"
    #   （两个实例里有一个随后被收走）。屏幕键盘的启动权归 KWin。
    #
    # ★ 匹配要用 '^InputMethod' 而不是 '^InputMethod=' ——
    #   KDE 自己写的是带展开标记的 `InputMethod[$e]=`，用等号匹配会漏判，
    #   于是我们**再追加一行** InputMethod=，和 KDE 那行冲突。
    _kwinrc="$DESKTOP_HOME/.config/kwinrc"
    if [ -d "$DESKTOP_HOME/.config" ] && [ -n "${DEV_OSK_BIN:-}" ]; then
        _kwinrc_dirty=0
        if [ ! -f "$_kwinrc" ] || ! grep -aq '^InputMethod' "$_kwinrc" 2>/dev/null; then
            if grep -aq '^\[Wayland\]' "$_kwinrc" 2>/dev/null; then
                awk '/^\[Wayland\]$/ && !d {print; print "InputMethod='"$DEV_OSK_BIN"'"; d=1; next} {print}' \
                    "$_kwinrc" > "$_kwinrc.new" && mv "$_kwinrc.new" "$_kwinrc"
            else
                printf '\n[Wayland]\nInputMethod=%s\n' "$DEV_OSK_BIN" >> "$_kwinrc"
            fi
            _kwinrc_dirty=1
            drm_log "kwinrc 已写入 InputMethod=$DEV_OSK_BIN"
        else
            drm_log "kwinrc 已有 InputMethod（KWin 会据此拉起屏幕键盘），不覆盖"
        fi
        # VirtualKeyboardEnabled 必须为 true，否则 KWin 不会为文本框拉起 OSK
        if ! grep -aq '^VirtualKeyboardEnabled=true' "$_kwinrc" 2>/dev/null; then
            if grep -aq '^\[Wayland\]' "$_kwinrc" 2>/dev/null; then
                awk '/^\[Wayland\]$/ && !d {print; print "VirtualKeyboardEnabled=true"; d=1; next} {print}' \
                    "$_kwinrc" > "$_kwinrc.new" && mv "$_kwinrc.new" "$_kwinrc"
            else
                printf '\n[Wayland]\nVirtualKeyboardEnabled=true\n' >> "$_kwinrc"
            fi
            _kwinrc_dirty=1
            drm_log "kwinrc 已写入 VirtualKeyboardEnabled=true"
        fi
        [ "$_kwinrc_dirty" = 1 ] && chown "$DESKTOP_USER" "$_kwinrc" 2>/dev/null
    fi

    # ── 关掉 KWin 的 slide 特效：屏幕键盘弹出拖影的根因 ──────────
    #
    # ★ 症状：键盘刚弹出那几秒，任务栏附近有一层拖影，之后自愈。
    #
    # ★ 根因：KWin 在窗口显示/隐藏时做「滑入/滑出」动画
    #   （kwin_wayland 里有 SurfaceInterface::slideOnShowHideChanged、
    #     KWindowEffects::SlideFromLocation、KWin::SlideEffect、kwin_slide、
    #     slideIn/slideOut/slideInDuration/slideOutDuration 这些符号）。
    #   键盘不是瞬间出现，而是从屏幕底部滑上来；滑动过程中前一帧留在屏幕上的
    #   轨迹就是那个拖影。动画几百毫秒就结束，画面本身随即正确，但残留的帧要
    #   等下一次全屏重绘才被彻底覆盖 —— 所以"几秒后自愈"。
    #
    # ★ 已排除的假设（别再回头查这些）：
    #   1. /etc/environment 里 kgsl/msm 驱动选择冲突
    #      —— 确有其事并已修（掉帧 8%→1%），但修完拖影仍在。
    #   2. 双 maliit 实例互相覆盖
    #      —— 确有其事并已修（现在只剩 KWin 拉起的那一个），但拖影仍在。
    #   3. KWinWRAP_SPLIT_* 分屏裁切导致某一段没更新
    #      —— 读 kwinwrap.c 确认 4 条 plane 是同一幅整宽帧缓冲按
    #         SRC_X = i*SPLIT_W 硬件裁切，不存在"某段落后"。
    #   4. Plasma 面板占位把键盘顶起来
    #      —— 改成 panelVisibility=2 后拖影仍在（但那个改动本身是用户要的，
    #         见下面那段，保留）。
    #
    # ★ 修法：卸载 slide / slideback 两个特效。D-Bus 立即生效，同时写进
    #   kwinrc 的 [Plugins] 段让它持久。
    #   ★ 注意 KWin 6.3 的 /Effects 接口**没有** isEffectActive（那是老版本的
    #     方法名，调用会报 UnknownMethod），但 unloadEffect 是可用的，返回 ()。
    _kwinrc_plugins=0
    if [ -f "$_kwinrc" ]; then
        for _e in slide slideback; do
            if grep -aq "^${_e}Enabled=" "$_kwinrc" 2>/dev/null; then
                grep -aq "^${_e}Enabled=false" "$_kwinrc" 2>/dev/null || {
                    sed -i "s/^${_e}Enabled=.*/${_e}Enabled=false/" "$_kwinrc" 2>/dev/null
                    _kwinrc_plugins=1
                }
            else
                if grep -aq '^\[Plugins\]' "$_kwinrc" 2>/dev/null; then
                    awk -v k="${_e}Enabled=false" \
                        '/^\[Plugins\]$/ && !d {print; print k; d=1; next} {print}' \
                        "$_kwinrc" > "$_kwinrc.new" 2>/dev/null \
                        && mv "$_kwinrc.new" "$_kwinrc"
                else
                    printf '\n[Plugins]\n%sEnabled=false\n' "$_e" >> "$_kwinrc"
                fi
                _kwinrc_plugins=1
            fi
        done
        [ "$_kwinrc_plugins" = 1 ] && chown "$DESKTOP_USER" "$_kwinrc" 2>/dev/null
        if grep -aq '^slideEnabled=false' "$_kwinrc" 2>/dev/null; then
            drm_log "kwinrc 已写入 slideEnabled=false / slidebackEnabled=false（消键盘弹出拖影）"
            drm_state_set KWIN_NO_SLIDE 1
        fi
    fi

    # ── 面板可见性：让屏幕键盘盖住任务栏 ──────────────────────
    #
    # ★ 用户明确要的效果："要不键盘就直接覆盖任务栏好了"。
    # 平板上的屏幕键盘本来就该盖住任务栏，而不是被任务栏顶起来。
    #
    # Plasma 面板的可见性存在 appletsrc 的 panelVisibility。
    # ★ 枚举是 Plasma::Types::Visibility，**不是**直觉上的顺序：
    #     0 = NormalPanel     始终可见（默认，会给窗口留占位）
    #     1 = AutoHide        自动隐藏
    #     2 = DodgeWindows    ★ 只在普通窗口碰到时才躲 —— 输入法面板不算普通窗口
    #     3 = WindowsCanCover ★ 允许窗口盖住它 ← 用这个
    #     4 = WindowsGoBelow  窗口永远在它下面
    #
    # ★★ 这里之前写成 2 并注释成"窗口可以覆盖"，是错的 ★★
    #   2 是 DodgeWindows。实测症状：屏幕键盘弹出时，任务栏仍然画在键盘
    #   最后一行**上面**，把那一行盖掉 —— 用户报的"底下任务栏那一块缺了"。
    #   因为 KWin 不把输入法面板当普通窗口，DodgeWindows 对它不生效。
    #
    # 实测背景：本机的面板是**浮动面板**（location=4），而且 panelVisibility
    # 在 appletsrc 里出现在 plugin=org.kde.panel **之前** ——
    # 所以"先标记面板段再插值"的写法会漏掉它，只能按整行替换。
    #
    # ★ 必须**先停 plasmashell 再改**，否则它会把文件回写掉。
    #   所以这个改动放在启动 plasmashell **之前**做。
    _appletsrc="$DESKTOP_HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$_appletsrc" ]; then
        if grep -aq '^plugin=org\.kde\.panel' "$_appletsrc" 2>/dev/null; then
            # 先备份（只备份一次）
            if ! ls -1 "$_appletsrc".bak-panel-* >/dev/null 2>&1; then
                cp -a "$_appletsrc" "$_appletsrc.bak-panel-$(date +%s)" 2>/dev/null
            fi
            # 按整行替换（panelVisibility 出现在 plugin= 之前，插值逻辑会漏）
            if grep -aq '^panelVisibility=' "$_appletsrc" 2>/dev/null; then
                sed -i 's/^panelVisibility=.*/panelVisibility=3/' "$_appletsrc" 2>/dev/null
            else
                # 一个都没有：在面板段末尾补一行
                awk '
                    /^\[Containments\]\[[0-9]+\]$/ {
                        if (sect != "" && ispanel && !done) print "panelVisibility=3"
                        sect = $0; ispanel = 0; done = 0; print; next
                    }
                    /^\[/ {
                        if (sect != "" && ispanel && !done) print "panelVisibility=3"
                        sect = ""; ispanel = 0; done = 0; print; next
                    }
                    /^plugin=org\.kde\.panel$/ { ispanel = 1 }
                    /^panelVisibility=/ { done = 1 }
                    { print }
                    END { if (sect != "" && ispanel && !done) print "panelVisibility=3" }
                ' "$_appletsrc" > "$_appletsrc.new" 2>/dev/null && mv "$_appletsrc.new" "$_appletsrc"
            fi
            chown "$DESKTOP_USER" "$_appletsrc" 2>/dev/null
            if grep -aq '^panelVisibility=3' "$_appletsrc" 2>/dev/null; then
                drm_log "面板已设为「窗口可以覆盖」（panelVisibility=3），屏幕键盘会盖住任务栏"
                drm_state_set PANEL_COVER 1
            else
                drm_warn "panelVisibility 写入失败，面板仍是「始终可见」—— 任务栏会盖住键盘最后一行"
            fi
        fi
    fi

    _ok=0
    # ★ 判据是**必须有 maliit**，不能是"fcitx5 或 maliit 有其一"。
    #   触摸屏要的是屏幕键盘，只有 maliit 能弹；fcitx5 不提供虚拟键盘。
    #   早先写成 `for _c in fcitx5 maliit-keyboard` 只要有一个就算过，
    #   结果只装了 fcitx5 的机器会走到下面却发现没有键盘可用。
    for _c in maliit-keyboard; do
        ds_exec "command -v $_c >/dev/null 2>&1" >/dev/null 2>&1 && _ok=1
    done
    if [ "$_ok" = 0 ]; then
        drm_warn "容器里没装 maliit-keyboard，跳过输入法（触摸屏将没有屏幕键盘）"
        drm_warn "  装法：network/net-takeover.sh deps（或在容器里 apt-get install maliit-keyboard）"
        return 0
    fi

    # 先把上轮的残留清掉，避免重复实例互相顶
    # ★ 注意**不要**杀 kded6 —— 它是单例守护，杀了会连带 kded 模块一起掉。
    ds_exec 'pkill -x fcitx5 2>/dev/null; pkill -x maliit-keyboard 2>/dev/null; true' >/dev/null 2>&1
    sleep 1

    # ★★ 默认**不启动 fcitx5** ★★
    #
    # 这里是键盘一闪一闪的根因所在。容器里 fcitx5 和 maliit-keyboard 同时存在，
    # 而 fcitx5-module-wayland 让 fcitx5 也走 Wayland 输入法协议，于是和
    # KWin 拉起的 maliit 抢同一个文本框，焦点来回跳 ⇒ 键盘在"显示/隐藏"之间
    # 无限循环 ⇒ 用户看到一闪一闪。
    #
    # 判决实验：pkill -x fcitx5 后 30 秒内 kwin.log 的 "keyboard is reporting"
    # 增长 0 次（基线 309 → 309）。完整证据见
    # docs/键盘一闪一闪-输入法冲突.md。
    #
    # ★ 上面那行 pkill 保留是**故意**的：上一次会话若留下了 fcitx5 进程，
    #   不清掉就会立刻开始闪。所以"清掉残留"和"不再拉起"两件事都要做。
    #
    # 要用 fcitx5 的话设 DEV_IM_FCITX=1，并且**必须同时**把 maliit 从 kwinrc
    # 的 InputMethod 摘掉，否则两个输入法会继续互相抢焦点。
    if [ "${DEV_IM_FCITX:-0}" = 1 ] && ds_exec 'command -v fcitx5 >/dev/null 2>&1' >/dev/null 2>&1; then
        setsid nohup runuser -u "$DESKTOP_USER" -- \
            env -u DISPLAY $_unset_env \
                WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
                XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
                QT_QPA_PLATFORM=wayland LANG="$_lang" \
                XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
                $_im \
            fcitx5 -d >>"${DRM_LOG_DIR}/fcitx5.log" 2>&1 &
        drm_log "已拉起 fcitx5（DEV_IM_FCITX=1）"
        drm_warn "  ★ fcitx5 与 maliit 同时当输入法会互相抢焦点，键盘会一闪一闪"
        drm_warn "  ★ 请同时把 kwinrc 的 [Wayland] InputMethod 摘掉"
    else
        drm_log "不启动 fcitx5（默认）：输入法交给 KWin + maliit 的 Wayland 协议"
    fi

    # ── maliit 的活跃语言：必须用 GSettings 设，环境变量完全无效 ──
    #
    # ★★ 2026-10-12 实测 ★★
    # maliit-keyboard **不读** LANG / LC_ALL / LANGUAGE。实测用
    #     LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN maliit-keyboard
    # 启动，日志依然是：
    #     registerActiveLanguage(): activeLanguage is: "en"
    #     plugin ".../languages/en/libenplugin.so" loaded
    #     DB path: .../languages/en/database_en.db
    #
    # 它的语言存在 GSettings 的 org.maliit.keyboard.maliit 里（schema 文件
    # /usr/share/glib-2.0/schemas/org.maliit.keyboard.maliit.gschema.xml）：
    #     active-language    (s)   默认 'en'
    #     enabled-languages  (as)  默认 ['en']
    #
    # ★ 关键坑：这个 schema 的**缓存没编译**时，`gsettings list-schemas` 根本
    #   看不见它（实测输出为空）⇒ gsettings 报 not found ⇒ maliit 只能退回
    #   默认 'en'。所以三步缺一不可：编译缓存 → 设 enabled-languages → 设
    #   active-language。
    #
    # 中文插件本身是装好的（maliit-keyboard 包自带 zh-hans + libpinyin 词库）：
    #     /usr/lib/aarch64-linux-gnu/maliit/keyboard2/languages/zh-hans/
    # 设好后它打开的会是 /usr/lib/aarch64-linux-gnu/libpinyin/data/bigram.db。
    #
    # ★ 另一个实测结论：**fcitx5 不能当 OSK**，触摸屏要的是 maliit。
    if ds_exec 'command -v gsettings >/dev/null 2>&1' >/dev/null 2>&1; then
        _osk_lang=${DEV_OSK_LANG:-zh-hans}
        ds_exec "glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null
                 runuser -u $DESKTOP_USER -- env HOME=$DESKTOP_HOME \
                     XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR \
                     DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
                     gsettings set org.maliit.keyboard.maliit enabled-languages \"['en', '$_osk_lang']\" 2>/dev/null
                 runuser -u $DESKTOP_USER -- env HOME=$DESKTOP_HOME \
                     XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR \
                     DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
                     gsettings set org.maliit.keyboard.maliit active-language '$_osk_lang' 2>/dev/null
                 runuser -u $DESKTOP_USER -- env HOME=$DESKTOP_HOME \
                     XDG_RUNTIME_DIR=$DESKTOP_RUNTIME_DIR \
                     DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
                     gsettings list-recursively org.maliit.keyboard.maliit 2>/dev/null | grep -E 'language'" \
            2>&1 | tr -d '\r' | sed 's/^/    /'
        drm_log "maliit 语言已设为 $_osk_lang（GSettings）"
    else
        drm_warn "容器里没有 gsettings（属 libglib2.0-bin）⇒ maliit 语言无法设置，会停在英文"
        drm_warn "  装法：network/net-takeover.sh deps，或在容器里 apt-get install -y libglib2.0-bin"
    fi

    # ── maliit-keyboard：**交给 KWin 启动，我们不起** ──────────
    #
    # ★★ 2026-10-12 实测（拖影根因）★★
    # 上面已经把 kwinrc 的 [Wayland] InputMethod= 与 VirtualKeyboardEnabled=true
    # 配好，KWin 会自己 fork 出 maliit 并持有它（实测父进程就是 kwin_wayland）。
    #
    # 这里原本还会**再手工起一个** maliit —— 后果是两个键盘窗口重叠：
    #     $ for P in $(pgrep -x maliit-keyboard); do awk '{print $4}' /proc/$P/stat; done
    #     21712      ← kwin_wayland（KWin 拉起的）
    #     6197       ← 我们的 wrapper（多余的）
    # 用户看到的症状是"任务栏那有一层拖影，只有刚弹出那几秒有，之后消失" ——
    # 两个实例里有一个随后被收走，画面就自愈了。
    #
    # 所以这里只做**校验**，不启动。屏幕键盘的启动权归 KWin。
    # 校验点：KWin 知道用哪个 OSK（kwinrc 里有 InputMethod），且 maliit 装了。
    if ds_exec 'command -v maliit-keyboard >/dev/null 2>&1' >/dev/null 2>&1; then
        if ds_exec "grep -aq '^InputMethod' '$DESKTOP_HOME/.config/kwinrc' 2>/dev/null" >/dev/null 2>&1; then
            drm_log "屏幕键盘归 KWin 管理（kwinrc 的 InputMethod + VirtualKeyboardEnabled）"
            drm_state_set OSK_OWNER kwin
            drm_state_set OSK_OK 1
        else
            drm_warn "kwinrc 里没有 InputMethod ⇒ KWin 不会拉起屏幕键盘"
            drm_state_set OSK_OK 0
        fi
        # 顺带报一下当前实例数：>1 就说明有残留，会拖影
        _osk_n=$(drm_pids_by_comm maliit-keyboard 2>/dev/null | grep -c . )
        [ -n "$_osk_n" ] && [ "$_osk_n" -gt 1 ] 2>/dev/null && \
            drm_warn "maliit 实例数=$_osk_n（>1 会拖影），应只有 KWin 那一个"
    fi
    return 0
}
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

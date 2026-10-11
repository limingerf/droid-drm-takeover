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

drm_bin_resolve() {
    [ -n "$DRM_BIN_DIR" ] && return 0
    for _c in \
        "$(dirname "$0")/../bin" \
        "/root/$DRM_PROJECT/bin" \
        "/opt/$DRM_PROJECT/bin" \
        "/usr/local/lib/$DRM_PROJECT/bin"
    do
        [ -d "$_c" ] && { DRM_BIN_DIR="$_c"; return 0; }
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
    chmod 666 "$DEV_DRM_CARD" 2>/dev/null

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
    chmod 666 "$DEV_DRM_RENDER" 2>/dev/null

    # GPU 渲染节点（kgsl 路线）
    [ -e /dev/kgsl-3d0 ] && chmod 666 /dev/kgsl-3d0 2>/dev/null

    # 其它内核 input 设施：容器里通常没有，缺了会静默降级
    drm_mknod_if_missing /dev/uhid    10 239
    drm_mknod_if_missing /dev/uinput  10 223
    drm_mknod_if_missing /dev/rfkill  10 242
    chmod 666 /dev/uhid /dev/uinput /dev/rfkill 2>/dev/null
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
    chmod 666 "$TOUCH_NODE" 2>/dev/null
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

_drm_write_udev_record() {
    _file=$1; shift
    mkdir -p /run/udev/data 2>/dev/null
    printf '%s' "$1" >"$_file" 2>/dev/null || { drm_warn "写 udev 记录失败：$_file"; return 1; }
    chmod a+r "$_file" 2>/dev/null
    return 0
}

drm_write_udev_records() {
    mkdir -p /run/udev/data 2>/dev/null

    # kwin 的 Hardware 白名单只收 i915/amdgpu/nouveau/vmwgfx；
    # msm_drm 会被判定为"不支持的驱动"直接拒绝。伪装成 vmwgfx。
    # （vmwgfx 在 kwin 里没有额外 quirk，是最安全的选择。）
    _drv=${DEV_DRM_DRIVER_ALIAS:-vmwgfx}
    _card_maj=${DEV_DRM_MAJOR:-226}
    _card_min=${DEV_DRM_MINOR:-0}
    _rend_min=${DEV_DRM_RENDER_MINOR:-128}

    _dp=${DEV_DRM_DEVPATH:-}
    [ -n "$_dp" ] || _dp="/devices/platform/soc/drm/card0"

    # ① card0
    if ! grep -q '^E:DRIVER=' "/run/udev/data/c${_card_maj}:${_card_min}" 2>/dev/null; then
        _dpc=${_dp%renderD*}
        [ -n "$_dpc" ] || _dpc=$_dp
        _dpc=${_dpc%card0}
        _drm_write_udev_record "/run/udev/data/c${_card_maj}:${_card_min}" \
"Q:100
E:DEVPATH=${_dpc}card0
E:MAJOR=${_card_maj}
E:MINOR=${_card_min}
E:SUBSYSTEM=drm
E:DEVTYPE=drm_minor
E:DEVNAME=dri/card0
E:DRIVER=${_drv}
H:uaccess
H:seat
"
    fi

    # ② renderD128 —— 独立判断（重构前它挂在 card0 的条件下面）
    if ! grep -q '^E:DRIVER=' "/run/udev/data/c${_card_maj}:${_rend_min}" 2>/dev/null; then
        _dpc=${_dp%renderD*}
        [ -n "$_dpc" ] || _dpc=${_dp%card0}
        _drm_write_udev_record "/run/udev/data/c${_card_maj}:${_rend_min}" \
"Q:101
E:DEVPATH=${_dpc}renderD128
E:MAJOR=${_card_maj}
E:MINOR=${_rend_min}
E:SUBSYSTEM=drm
E:DEVTYPE=drm_minor
E:DEVNAME=dri/renderD128
E:DRIVER=${_drv}
H:uaccess
H:seat
"
    fi

    # ③ 触摸屏 —— 独立判断，且按**本次发现的** event 名与主次号重写
    if [ -n "${TOUCH_MAJOR:-}" ] && [ -n "${TOUCH_MINOR:-}" ]; then
        _f="/run/udev/data/c${TOUCH_MAJOR}:${TOUCH_MINOR}"
        if ! grep -q "input/${TOUCH_EVENT}" "$_f" 2>/dev/null; then
            _grp=${DEV_TOUCH_GROUP:-}
            [ -n "$_grp" ] || _grp="${TOUCH_MAJOR}/${TOUCH_MINOR}"
            _cal=""
            [ -n "${DEV_TOUCH_CALIB:-}" ] && _cal="E:LIBINPUT_CALIBRATION_MATRIX=${DEV_TOUCH_CALIB}
"
            _drm_write_udev_record "$_f" \
"Q:100
E:DEVPATH=/devices/virtual/input/${TOUCH_EVENT}
E:MAJOR=${TOUCH_MAJOR}
E:MINOR=${TOUCH_MINOR}
E:SUBSYSTEM=input
E:DEVNAME=input/${TOUCH_EVENT}
E:ID_INPUT=1
E:ID_INPUT_TOUCH=1
E:ID_INPUT_TOUCHSCREEN=1
E:LIBINPUT_DEVICE_GROUP=${_grp}:${DEV_TOUCH_NAME:-touch}
${_cal}H:uaccess
H:seat
"
        fi
    fi

    chmod -R a+rX /run/udev 2>/dev/null
    drm_log "udev 合成记录就绪（card0 / renderD128 / ${TOUCH_EVENT:-无触摸}）"
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

    # 第一轮：按命令行特征杀（KDE 监督者必须先死，否则会补进程）
    for _pat in kwin_wayland_wrapper kwinwrap xdg-desktop-portal \
                dmesg-harvester.sh keepbright.sh; do
        _pids=$(drm_pids_by_cmdline "$_pat" | drm_pids_uniq)
        [ -n "$_pids" ] || continue
        drm_log "  kill -9 [$_pat] → $(printf '%s' "$_pids" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        drm_kill_pids 9 $_pids
    done
    # 按精确进程名杀
    for _name in kwin_wayland plasmashell kactivitymanagerd plasma-keyboard; do
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
}

# 谁还持有 DRM 节点（本侧 /proc 扫描）。
#
# 一次 ls 全部 fd 再 grep 一次 —— 不要写成"每个进程 fork 一次 ls|grep"，
# 那在 30 秒 × 每 0.5 秒的轮询里会变成上万次 fork。
drm_card_fd_holders() {
    _node=${1:-$DEV_DRM_CARD}
    ls -l /proc/[0-9]*/fd 2>/dev/null \
        | grep -F -- "-> $_node" \
        | sed -n 's#^.*/proc/\([0-9][0-9]*\)/fd/.*#\1#p' \
        | sort -u \
        | grep -v -x "$$" 2>/dev/null
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

    _split_env=$(drm_kwinwrap_split_env 2>/dev/null | head -1)

    drm_log "kwinwrap 交接 → kwin_wayland --drm --socket=$_sock"
    # shellcheck disable=SC2086
    env KWINWRAP_HIJACK=1 KWINWRAP_SECCOMP=1 KWINWRAP_FILTER=1 \
        KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
        KWINWRAP_BRIGHTNESS="$DEV_BRIGHTNESS" \
        $_split_env \
        "$_kw" --out "$_out" -- \
        env -u DISPLAY -u WAYLAND_DISPLAY -u ANLAND -u ANLAND_SOCKET \
            -u ANLAND_DRM_DEVICE -u GALLIUM_DRIVER -u FD_FORCE_KGSL \
            HOME="$DESKTOP_HOME" \
            KWIN_DRM_DEVICES="$DEV_DRM_CARD" \
            FD_MESA_DEBUG=noubwc \
            KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
            XDG_SESSION_ID=bogus \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
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
    runuser -u "$DESKTOP_USER" -- env -u DISPLAY \
        WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
        XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" QT_QPA_PLATFORM=wayland \
        drm_timeout 8 wayland-info >"${DRM_LOG_DIR}/wayland-info.log" 2>&1
    if [ $? -ne 0 ]; then
        drm_err "wayland-info 连不上合成器（socket=$_sock）"
        return 1
    fi
    drm_log "wayland socket 自检通过"
    return 0
}

# 强制点亮：stop 时安卓走关机流程会把 connector DPMS 拉 Off 并灭背光，
# kwin 的新 commit 不一定把它拉回来 ⇒ 现象是"有模式、有提交、屏是黑的"。
drm_force_display_on() {
    _sp=$(drm_tool setprop 2>/dev/null)  && "$_sp" 0 DPMS >/dev/null 2>&1
    _sb=$(drm_tool setbright 2>/dev/null) && "$_sb" "$DEV_BRIGHTNESS" >/dev/null 2>&1
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
    setsid nohup runuser -u "$DESKTOP_USER" -- \
        env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u SDL_IM_MODULE \
            -u GLFW_IM_MODULE -u XMODIFIERS \
            WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$DESKTOP_RUNTIME_DIR/bus" \
            QT_QPA_PLATFORM=wayland LANG="$_lang" \
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
        for _p in $(drm_pids_by_comm kwin_wayland); do
            _fds=$(ls -l "/proc/$_p/fd" 2>/dev/null)
            case "$_fds" in *event*) ;; *) _ok=0 ;; esac
        done
        [ "$_ok" = 1 ] && [ "$_i" -gt 2 ] && break
        udevadm trigger --action=change --subsystem-match=input 2>/dev/null
        sleep 1
        _i=$((_i + 1))
    done
    drm_log "输入设备重打 udev 完成（$_i 轮）"
    return 0
}

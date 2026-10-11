#!/bin/sh
# core/lib/common.sh — 全项目共享基础层：日志、超时执行、状态文件、互斥锁。
#
# 【为什么单独抽出来】
#   重构前 drm-takeover.sh / desk-takeover.sh 各自复制了 ~150 行同样的
#   "解析桌面账号 / 找触摸节点 / 建 DRM 节点 / 写 udev 记录 / 停起安卓" 逻辑，
#   两份实现还会漂移（一份改了另一份没改）。这里收成唯一事实源。
#
# 【兼容性约束】★ 必须同时能被两种 shell 解析：
#   · 安卓侧  /system/bin/sh  = mksh（Android 10+）
#   · 容器侧  /bin/sh         = dash 或 bash
#   所以本文件只用 POSIX 构造：不用数组、不用 [[ ]]、不用 ${var//}、
#   不用 process substitution、不用 $'...'。local 可以用（三者都支持）。
#
# 【调用约定】任何脚本第一件事：
#   . "$(dirname "$(readlink -f "$0")")/../core/lib/common.sh"

# ─────────────────────────── 常量 ───────────────────────────

# 项目名（用于日志前缀、状态目录、通知标题）
DRM_PROJECT="droid-drm-takeover"

# 我们跑在安卓侧还是容器侧？由 device.sh 的 drm_detect_side() 最终确定，
# 这里先给一个基于 /system/bin/getprop 存在性的初判，供日志早期可用。
if [ -x /system/bin/getprop ] && [ ! -e /etc/os-release ]; then
    DRM_SIDE=${DRM_SIDE:-android}
else
    DRM_SIDE=${DRM_SIDE:-container}
fi

# ★ 安卓侧 payload 根目录。**这个路径的选择有安全含义，不是随手挑的。**
#
#   /data/local/tmp 的权限是 0771 shell:shell —— adb shell（uid 2000）可写。
#   而我们的脚本以 root 执行（APK 已经持有 su 授权，不会再弹提示）。
#   两者相加 = 任何能写该目录的本地进程都能拿到 **root 代码执行**。
#
#   所以 payload 放 /data/local/drm-takeover：
#   /data/local 是 0711 root:root，只有 root 能写。
#   并且 drm_assert_payload_trusted() 会兜底拒绝在不可信路径上运行 ——
#   万一将来路径又被改回某个可写目录，那道检查会拦住。
DRM_ANDROID_PAYLOAD=${DRM_ANDROID_PAYLOAD:-/data/local/drm-takeover}

# ★ 请求会合目录 —— 容器侧与安卓侧之间的**唯一**控制通道。
#
#   为什么需要它（三条都是实测出来的，不是设计洁癖）：
#   1. 容器里没有 adb 能力：Droidspaces v6.6.0 的容器**没有 USB 节点**
#      （/dev/bus/usb 不存在），adbd 也没监听 TCP ⇒ 容器里 `adb devices`
#      恒为空。而接管必须停 surfaceflinger 和 composer HAL，那只有能访问
#      init 属性服务的安卓侧做得到。所以容器只能"请求"，不能"执行"。
#   2. 容器的 /root 是 0700 root:root，而"进 Linux"是**桌面用户**点出来的
#      —— 他既读不了 .drm-device（认不出设备），也写不了请求文件。
#   3. 这个目录在 rootfs 里，所以两侧看到的是**同一个目录**：
#        安卓侧  <rootfs>/var/lib/droid-drm-takeover
#        容器侧  /var/lib/droid-drm-takeover
#      不需要任何 bind mount，也不受容器 /root 权限限制。
#
#   权限 1777：两侧都要能建文件；sticky 保证只有属主（或 root）能删。
#   ★ 请求的**内容不参与任何执行决策**（只看文件在不在），
#     所以"世界可写"在这里不构成注入面。安卓侧只认文件名。
DRM_RENDEZVOUS=${DRM_RENDEZVOUS:-/var/lib/$DRM_PROJECT}

# 运行期目录：安卓侧放 payload 下的 run/（重启不丢，便于取证，且同样 root-only）；
# 容器侧放 /run（tmpfs，容器一重启自然清空，正是我们要的语义）。
if [ "$DRM_SIDE" = android ]; then
    DRM_RUN_DIR=${DRM_RUN_DIR:-$DRM_ANDROID_PAYLOAD/run}
    DRM_LOG_DIR=${DRM_LOG_DIR:-$DRM_RUN_DIR/logs}
else
    DRM_RUN_DIR=${DRM_RUN_DIR:-/run/$DRM_PROJECT}
    DRM_LOG_DIR=${DRM_LOG_DIR:-/root/$DRM_PROJECT-logs}
fi

DRM_STATE_FILE=${DRM_STATE_FILE:-$DRM_RUN_DIR/state}
DRM_LOCK_DIR=${DRM_LOCK_DIR:-$DRM_RUN_DIR/.lock}
DRM_JOURNAL=${DRM_JOURNAL:-$DRM_LOG_DIR/journal.log}

# ─────────────────────────── 日志 ───────────────────────────

# 所有日志同时进 journal（带时间戳）和 stderr（给人看）。
# 不用 `set -x` 全局打开——重构前的教训：desk-takeover.sh 开着 set -x
# 把 WiFi PSK 明文写进了日志。
drm_ts() { date '+%F %T'; }

drm_log() {
    _m="[$(drm_ts)] $*"
    printf '%s\n' "$_m" >&2
    if [ -n "${DRM_JOURNAL:-}" ]; then
        mkdir -p "$(dirname "$DRM_JOURNAL")" 2>/dev/null
        printf '%s\n' "$_m" >>"$DRM_JOURNAL" 2>/dev/null
    fi
}

drm_warn() { drm_log "WARN  $*"; }
drm_err()  { drm_log "ERROR $*"; }

drm_die() {
    drm_err "$*"
    drm_state_set PHASE error 2>/dev/null
    drm_state_set LAST_ERROR "$*" 2>/dev/null
    exit 1
}

# 阶段横幅：让 journal 一眼能看出这次跑到了哪一步。
drm_phase() {
    drm_log "──── $* ────"
    drm_state_set PHASE "$1" 2>/dev/null
    drm_state_set PHASE_AT "$(drm_ts)" 2>/dev/null
}

# ─────────────────── payload 可信性自检 ───────────────────
#
# 为什么需要它：本项目的脚本**以 root 执行**，而它们住在文件系统的某个
# 目录里。如果那个目录任何非 root 用户都能写，那么"能写目录的人"就等于
# 拿到了 root 代码执行 —— 而 APK 已经持有 su 授权，不会再弹提示拦一下。
#
# /data/local/tmp 正是这种目录（0771 shell:shell）。所以：
#   1. payload 默认放 /data/local/drm-takeover（0711 root:root）
#   2. 这个函数在每次做特权操作前兜底检查
#
# 返回值：0 = 可信（或无法判断/用户显式放行）；1 = 不可信，调用方应中止。
drm_assert_payload_trusted() {
    _root=${1:-${DRM_ROOT:-}}
    [ -n "$_root" ] || return 0

    # 非 root 身份无从判断（容器里以普通用户跑是正常情况）
    [ "$(id -u 2>/dev/null || echo 0)" = 0 ] || return 0

    # ── 已知的不可信位置（前缀匹配，覆盖子目录）──
    case "$_root" in
        /data/local/tmp|/data/local/tmp/*|/sdcard|/sdcard/*|/storage/*|/mnt/sdcard/*)
            drm_err "════════════════════════════════════════════════"
            drm_err "拒绝运行：payload 位于非 root 独占目录"
            drm_err "  $_root"
            drm_err ""
            drm_err "该目录对非 root 可写，而本脚本以 root 执行 ——"
            drm_err "等于把 root 代码执行权交出去。"
            drm_err ""
            drm_err "请把 payload 放到 $DRM_ANDROID_PAYLOAD"
            drm_err "（在 APK 里点一次「安装/更新 payload」即可）。"
            drm_err "仅限自己的调试环境可设 DRM_ALLOW_UNTRUSTED=1 绕过。"
            drm_err "════════════════════════════════════════════════"
            [ "${DRM_ALLOW_UNTRUSTED:-0}" = "1" ] && {
                drm_warn "DRM_ALLOW_UNTRUSTED=1：已放行，风险自负"
                return 0
            }
            return 1
            ;;
    esac

    # ── 通用检查：树根必须属于 root，且不可被 group/other 写 ──
    if [ -d "$_root" ]; then
        _ls=$(ls -ld "$_root" 2>/dev/null || true)
        _owner=$(printf '%s\n' "$_ls" | awk '{print $3}')
        _perm=$(printf '%s\n' "$_ls" | awk '{print $1}')
        # 第 6/9 位是 group/other 的 w
        case "$_perm" in
            ??????w*|???????w*)
                drm_err "拒绝运行：$_root 对 group/other 可写（$_perm）"
                [ "${DRM_ALLOW_UNTRUSTED:-0}" = "1" ] && return 0
                return 1
                ;;
        esac
        if [ -n "$_owner" ] && [ "$_owner" != "root" ]; then
            drm_err "拒绝运行：$_root 属于 $_owner 而非 root"
            [ "${DRM_ALLOW_UNTRUSTED:-0}" = "1" ] && return 0
            return 1
        fi
    fi

    return 0
}

# ─────────────────────────── 工具 ───────────────────────────

drm_have() { command -v "$1" >/dev/null 2>&1; }

# 在 PATH 里找第一个存在的文件（安卓侧 PATH 经常不全）
drm_find() {
    for _d in ${DRM_EXTRA_PATH:-} /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /system/bin /system/xbin /vendor/bin; do
        [ -n "$_d" ] || continue
        [ -x "$_d/$1" ] && { printf '%s\n' "$_d/$1"; return 0; }
    done
    return 1
}

# 定位仓库内的一个脚本（相对路径，例如 tools/probe/card-holders.sh）。
#
# ★ 为什么不直接用 $DRM_ROOT：
#   DRM_ROOT 由**各入口脚本**自己设 —— common.sh 设不了，因为它被 source
#   时 $0 是调用方的路径，推不出仓库根（core/switch.sh 要退一级，
#   tools/verify/*.sh 要退两级，没有统一公式）。
#   一旦哪个调用方忘了设，"文件不存在"在这里的后果可能是**静默返回空**：
#   例如"谁持有 card0"返回空 ⇒ 上层读成"composer 已经松手" ⇒
#   在错误的时刻接管 ⇒ kwin 有 master 但 atomic 报 EACCES。
#   所以按候选列表找，并且**找不到时返回非零**，让调用方必须处理。
drm_repo_script() {
    for _base in "${DRM_ROOT:-}" \
                 "/root/$DRM_PROJECT" \
                 "${DRM_ANDROID_PAYLOAD:-/data/local/$DRM_PROJECT}" \
                 "/opt/$DRM_PROJECT"; do
        [ -n "$_base" ] || continue
        if [ -f "$_base/$1" ]; then
            printf '%s\n' "$_base/$1"
            return 0
        fi
    done
    return 1
}

# ★ 带超时的命令执行。
#   重构前所有 `adb shell` 都是裸调用；参考仓库实测过一次事故：
#   desk-stop 卡死在它第一个 adb 调用上，日志断在 wake_unlock 那行，
#   后面的 `start` 从未执行 ⇒ 纯黑屏。这里统一兜住。
#   用法: drm_timeout 12 adb -s "$DEV" shell true
DRM_TIMEOUT_BIN=""
drm_timeout() {
    _secs=$1; shift
    if [ -z "$DRM_TIMEOUT_BIN" ]; then
        DRM_TIMEOUT_BIN=$(drm_find timeout 2>/dev/null || true)
    fi
    if [ -n "$DRM_TIMEOUT_BIN" ]; then
        "$DRM_TIMEOUT_BIN" "$_secs" "$@"
        _rc=$?
        [ "$_rc" = 124 ] && drm_warn "TIMEOUT(${_secs}s): $*"
        return $_rc
    fi
    # 没有 timeout(1) 时退化为后台 + 轮询（mksh/toybox 环境可能缺）
    "$@" &
    _pid=$!
    _n=0
    while [ "$_n" -lt "$_secs" ]; do
        kill -0 "$_pid" 2>/dev/null || { wait "$_pid"; return $?; }
        sleep 1
        _n=$((_n + 1))
    done
    drm_warn "TIMEOUT(${_secs}s): $*"
    kill -9 "$_pid" 2>/dev/null
    return 124
}

# ─────────────────────── 进程查找（纯 /proc）───────────────────────
#
# ★ 为什么不用 pgrep / pkill / fuser：
#
#   · `fuser` 在安卓的 toybox 里**根本不存在**（实测报
#     "inaccessible or not found"）。原来 drm_kill_linux_stack 用它做
#     最后兜底，等于那条兜底路径在设备上是死的。
#
#   · `pgrep -f` / `pkill -f` 是按**整条命令行做正则匹配**。这有两个坑：
#       (a) 会匹配到"命令行里恰好提到这个字符串"的无关进程 ——
#           包括调用方自己的 shell（项目在 netd 那边踩过这个坑，
#           当时把 $WIFI_CONF 当 pkill -f 的模式，结果连调用方一起杀）；
#       (b) 模式里的 `|` 是正则的"或"，不是字面量，容易写出意外的匹配。
#
#   · /proc 扫描没有这些歧义，dash 和 mksh 上都能跑，也不依赖任何外部命令。
#
# 用法：
#   drm_pids_by_comm kwin_wayland      → 精确匹配进程名（/proc/PID/comm）
#   drm_pids_by_cmdline "keepbright"   → 命令行**子串**匹配（非正则，安全）

# 按进程名精确查找（comm 最长 15 字符，这是内核限制）
drm_pids_by_comm() {
    _want=$1
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ "$_p" = "$$" ] && continue
        [ -r "$_d/comm" ] || continue
        # 不用 $(cat)：某些环境下 cat 也会成为噪声；read 是内建
        read -r _c <"$_d/comm" 2>/dev/null || continue
        [ "$_c" = "$_want" ] && printf '%s\n' "$_p"
    done
}

# 按命令行子串查找。用 case 做字面量子串匹配，**不是**正则，
# 所以模式里的 . | * 等字符都不会有特殊含义。
drm_pids_by_cmdline() {
    _want=$1
    [ -n "$_want" ] || return 0
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ "$_p" = "$$" ] && continue
        [ -r "$_d/cmdline" ] || continue
        # cmdline 是 NUL 分隔的，转成空格再找子串
        _cl=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null) || continue
        [ -n "$_cl" ] || continue          # 内核线程的 cmdline 是空的
        case "$_cl" in
            *"$_want"*) printf '%s\n' "$_p" ;;
        esac
    done
}

# 合并去重（多个查找结果拼起来后用）
drm_pids_uniq() {
    sort -u 2>/dev/null || cat
}

# 对一组 pid 发信号；空列表是安全的空操作
drm_kill_pids() {
    _sig=$1; shift
    for _p in "$@"; do
        [ -n "$_p" ] || continue
        [ "$_p" = "$$" ] && continue
        kill "-$_sig" "$_p" 2>/dev/null
    done
}

# 便捷封装：按进程名精确杀掉（替代 `pkill -x <name>`）
drm_kill_by_comm() {
    _sig=$1; _name=$2
    _pids=$(drm_pids_by_comm "$_name")
    [ -n "$_pids" ] || return 0
    # shellcheck disable=SC2086
    drm_kill_pids "$_sig" $_pids
}

# 便捷封装：按命令行子串杀掉（替代 `pkill -f <pat>`，但用字面量子串而非正则）
drm_kill_by_cmdline() {
    _sig=$1; _pat=$2
    _pids=$(drm_pids_by_cmdline "$_pat")
    [ -n "$_pids" ] || return 0
    # shellcheck disable=SC2086
    drm_kill_pids "$_sig" $_pids
}

# ─────────────────────────── 状态文件 ───────────────────────────
#
# 重构前唯一的状态是 `takeover.ok` 一个空文件：布尔、无时间戳、无模式、
# 无 PID，而且 drm-takeover.sh 在结尾**无条件** touch 它，
# 直接把自己 150s 保险丝的判据弄失效了。
#
# 现在换成 key=value 文件。选 key=value 而不是 JSON：安卓侧没有 jq，
# 而 mksh 里解析 JSON 是自找麻烦。
#
# 阶段取值：
#   android-active   安卓在跑，Linux 未接管（初始态 / 回退完成态）
#   entering         正在进入 Linux（已开始动安卓服务）
#   linux-active     Linux 桌面在跑，安卓已停
#   returning        正在返回安卓
#   error            上一轮失败，需要人工确认

drm_state_init() {
    mkdir -p "$DRM_RUN_DIR" "$DRM_LOG_DIR" 2>/dev/null
    [ -f "$DRM_STATE_FILE" ] || {
        {
            printf 'PHASE=android-active\n'
            printf 'SINCE=%s\n' "$(drm_ts)"
            printf 'BOOT_ID=%s\n' "$(drm_boot_id)"
        } >"$DRM_STATE_FILE"
    }
}

drm_boot_id() {
    # 用内核启动时刻当"这一次开机"的身份，避免重启后旧状态被误认成当前
    if [ -r /proc/stat ]; then
        awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null
    fi
}

drm_state_get() {
    [ -f "$DRM_STATE_FILE" ] || return 1
    sed -n "s/^$1=//p" "$DRM_STATE_FILE" 2>/dev/null | head -1
}

drm_state_set() {
    _k=$1; shift
    _v=$*
    mkdir -p "$(dirname "$DRM_STATE_FILE")" 2>/dev/null
    [ -f "$DRM_STATE_FILE" ] || drm_state_init
    _tmp="$DRM_STATE_FILE.$$"
    grep -v "^$_k=" "$DRM_STATE_FILE" >"$_tmp" 2>/dev/null
    printf '%s=%s\n' "$_k" "$_v" >>"$_tmp"
    mv -f "$_tmp" "$DRM_STATE_FILE"
}

drm_state_phase() { drm_state_get PHASE 2>/dev/null || echo unknown; }

# ── 跨侧会话报告（会合目录）──────────────────────────────
#
# ★★★ 为什么必须有这个：**状态文件不跨侧共享**。
#     安卓：DRM_STATE_FILE = $DRM_ANDROID_PAYLOAD/run/state
#     容器：DRM_STATE_FILE = /run/$DRM_PROJECT/state   ← 容器自己的 tmpfs
#
#   而接管流程是**跨侧**的：
#     「会话拉起」跑在容器里 → 容器 state 写上 KWIN_HOLDS_DRM=1
#     「验证」   跑在安卓侧 → 读安卓 state → 永远读到**空字符串**
#
#   重构前 enter.sh 的 verify 直接 drm_state_get，于是**每一轮接管都被自己的
#   验证判死**。更毒的是回滚会把安卓 composer 拉回来**抢走 DRM master**，
#   KWin 之后所有 atomic 提交变成 EACCES(-13) —— 看 kwinatomic.log 就是
#   「先 ret=0 提交成功，回滚一开始立刻变 -13」，极易误判成"KWin 提交不了"。
#
#   现象极具误导性：容器侧日志一路绿（`kwin 持DRM : 1`），安卓侧却报
#   `kwin 没有持有 /dev/dri/card0（kwin_holds_drm=）` —— 注意那个**空值**，
#   它才是线索：读到空 = 读错文件了，不是真的没持有。
#
#   所以跨侧结论一律走**会合目录**（两侧是同一个目录的两个视角，见
#   drm_rendezvous_local 的注释）。
drm_session_report_write() {
    _d=$(drm_rendezvous_ensure 2>/dev/null) || return 0
    [ -n "$_d" ] || return 0
    {
        printf 'KWIN_HOLDS_DRM=%s\n' "${1:-0}"
        printf 'PLASMA_OK=%s\n' "${2:-0}"
        printf 'NET_OK=%s\n' "${3:-0}"
        printf 'AT=%s\n' "$(drm_ts)"
    } >"$_d/session.report" 2>/dev/null || return 1
    chmod 644 "$_d/session.report" 2>/dev/null
    return 0
}

# 读回本侧视角下的会话报告；没有就返回 1（调用方保留原值）
drm_session_report_get() {
    _d=$(drm_rendezvous_local 2>/dev/null) || return 1
    [ -n "$_d" ] && [ -r "$_d/session.report" ] || return 1
    sed -n "s/^${1:-KWIN_HOLDS_DRM}=//p" "$_d/session.report" 2>/dev/null | tail -1
}

# 打印人类可读状态（Linux app 与 APK 都用它）
drm_state_show() {
    printf 'phase      : %s\n' "$(drm_state_phase)"
    printf 'since      : %s\n' "$(drm_state_get SINCE 2>/dev/null || echo -)"
    printf 'phase_at   : %s\n' "$(drm_state_get PHASE_AT 2>/dev/null || echo -)"
    printf 'device     : %s\n' "$(drm_state_get DEVICE 2>/dev/null || echo -)"
    printf 'mode       : %s\n' "$(drm_state_get MODE 2>/dev/null || echo -)"
    printf 'last_error : %s\n' "$(drm_state_get LAST_ERROR 2>/dev/null || echo -)"
}

# ─────────────────────────── 互斥锁 ───────────────────────────
#
# 重构前没有任何"是否已在接管中"的前置守卫：重复跑 desk-takeover.sh
# 会起第二套 kwinwrap / wpa_supplicant / dhcpcd / 守护进程。
#
# 用 mkdir 做原子锁（POSIX 下最可移植的原子操作）。
# 持锁进程死了要能自动接管——否则一次崩溃就永久锁死。

drm_lock_acquire() {
    _who=${1:-switch}
    mkdir -p "$(dirname "$DRM_LOCK_DIR")" 2>/dev/null
    if mkdir "$DRM_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$DRM_LOCK_DIR/pid"
        printf '%s\n' "$_who" >"$DRM_LOCK_DIR/who"
        printf '%s\n' "$(drm_ts)" >"$DRM_LOCK_DIR/at"
        DRM_LOCK_HELD=1
        return 0
    fi
    # 已有锁：判断持有者是否还活着
    _op=$(cat "$DRM_LOCK_DIR/pid" 2>/dev/null)
    _ow=$(cat "$DRM_LOCK_DIR/who" 2>/dev/null)
    if [ -n "$_op" ] && [ -d "/proc/$_op" ]; then
        drm_err "已有操作在进行中（who=$_ow pid=$_op）——拒绝并发执行"
        return 1
    fi
    drm_warn "发现僵尸锁（pid=$_op who=$_ow 已不存在），接管"
    rm -rf "$DRM_LOCK_DIR"
    mkdir "$DRM_LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" >"$DRM_LOCK_DIR/pid"
    printf '%s\n' "$_who" >"$DRM_LOCK_DIR/who"
    printf '%s\n' "$(drm_ts)" >"$DRM_LOCK_DIR/at"
    DRM_LOCK_HELD=1
    return 0
}

drm_lock_release() {
    [ "${DRM_LOCK_HELD:-0}" = 1 ] || return 0
    _op=$(cat "$DRM_LOCK_DIR/pid" 2>/dev/null)
    [ "$_op" = "$$" ] && rm -rf "$DRM_LOCK_DIR"
    DRM_LOCK_HELD=0
}

drm_lock_holder() {
    [ -d "$DRM_LOCK_DIR" ] || return 1
    printf 'pid=%s who=%s at=%s\n' \
        "$(cat "$DRM_LOCK_DIR/pid" 2>/dev/null)" \
        "$(cat "$DRM_LOCK_DIR/who" 2>/dev/null)" \
        "$(cat "$DRM_LOCK_DIR/at" 2>/dev/null)"
}

# ─────────────────────────── 其它 ───────────────────────────

# 与将被我们杀掉的 GUI 栈脱钩：从桌面终端启动时必须先 setsid 甩出去，
# 否则杀掉 kwin 的瞬间 pty 关闭，脚本陪葬，而安卓已 stop ⇒ 两头全黑。
# （这是参考仓库被咬过两次的坑，target 版也踩过。）
drm_detach_and_rerun() {
    _id_var=$1
    shift

    eval "_cur=\${$_id_var:-}"
    [ -n "$_cur" ] && return 0   # 已经是脱钩后的真身

    eval "$_id_var=\"\$\$.detached\""
    eval "export $_id_var"

    _log="${DRM_LOG_DIR}/$(basename "$0").log"
    mkdir -p "$DRM_LOG_DIR" 2>/dev/null

    # 用与本次相同的解释器再跑一遍自己。
    # 不能假定 $0 有可执行位（用户可能 `sh desk-takeover.sh` 起的）。
    if [ -x "$0" ]; then
        setsid nohup "$0" "$@" >>"$_log" 2>&1 </dev/null &
    else
        setsid nohup sh "$0" "$@" >>"$_log" 2>&1 </dev/null &
    fi
    _child=$!
    drm_log "已脱钩后台执行（pid=$_child），日志：$_log"

    # 前台转发日志，让调用者能看到进度
    if command -v tail >/dev/null 2>&1; then
        tail -n 40 -f "$_log" 2>/dev/null &
        _tail=$!
        wait "$_child" 2>/dev/null
        kill "$_tail" 2>/dev/null
    else
        wait "$_child" 2>/dev/null
    fi
    exit 0
}

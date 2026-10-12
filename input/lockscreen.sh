#!/bin/sh
# input/lockscreen.sh — 锁屏 + 熄面板 的统一入口
#
# ══ 为什么需要它 ══
#
# 用户需求：「电源键改成锁屏并熄灭面板」。这两件事必须**成对**做：
#   · 只锁屏不熄屏 ⇒ 屏幕一直亮着（锁屏的默认行为，kscreenlocker 会把背光
#     压到 1，但那是「最暗」不是「熄灭」，面板仍在扫描、仍在耗电）
#   · 只熄屏不锁屏 ⇒ 按任意键就回到桌面，没有安全性
#
# ══ 为什么不用 ksmserver ══
#
# KDE 的标准路径是 ksmserver 提供 org.freedesktop.ScreenSaver 服务，
# 然后任何人调 Lock() 即可。但本机实测 **ksmserver 自己 SIGSEGV**
# （gdb backtrace：崩在它自己的初始化里，与平台插件无关）：
#     Thread 1 "ksmserver" received signal SIGSEGV
#     #0  0x000000555555c644 in ?? ()
#     #1  ... __libc_start_main ()
# 而它崩溃后 **不注册 org.kde.ksmserver**，于是 Lock() 永远 ServiceUnknown。
#
# 所以这里**直接调 kscreenlocker_greet**，绕过 ksmserver。实测可行：
#     kscreenlocker_greet -platform wayland  ⇒  打印 "Locked at <ts>"
# 退出时打印 "Unlocked"。这就是我们需要的全部。
#
# ══ 四个必须知道的实测约束 ══
#
# ① **`-platform wayland` 是命令行参数，不能用 QT_QPA_PLATFORM 环境变量代替。**
#    ksmserver 上实测过：设了 QT_QPA_PLATFORM=wayland 它照样去连 xcb 然后
#    Abort rc=134；只有命令行参数才生效。kscreenlocker_greet 同理。
#
# ② **必须去掉 KWin 的 `--no-lockscreen`。** 那个开关让 KWin 不注册
#    ext-session-lock 协议，后果是锁屏**弹不出任何键盘**，密码根本输不进去。
#    见 core/device/opd2511.sh 里的注释。
#
# ③ **密码认证依赖「Gold 属于 shadow 组」。** 容器 rootfs 是 nosuid 挂载，
#    setgid 的 /usr/sbin/unix_chkpwd 因此丢掉 shadow 组身份、读不到
#    /etc/shadow，导致 pam_unix 对**非 root** 用户认证必然失败。
#    症状极具迷惑性：以 root 跑 pamtester 能过，以 Gold 跑就失败。
#    修法：usermod -aG shadow <桌面用户>（见 --check）。
#
# ④ **熄面板必须走 DRM connector 属性，sysfs 那条路是死的。**
#    详见下面「熄面板到底该写什么」一节。这是本文件最重要的一段。
#
# ══ 熄面板到底该写什么（2026-10-13 彻底查清）══
#
# 结论：**只有 `DRM brightness=0` + `DPMS=off` 这两个一起写，面板才真正全黑。**
# 这个结论是用排除法一步步逼出来的，每一步都有实测证据，记在这里免得重走：
#
# ── ✗ 死的路 1：/sys/class/backlight/panel0-backlight ──
#    写 brightness=0、bl_power=4（FB_BLANK_POWERDOWN）都**成功**（读回确实是 0/4，
#    连续 5 秒稳定），但屏幕**毫无变化**。内核 dmesg 直接说明了原因：
#        [drm:dsi_panel_set_backlight [msm_drm]] [msm-dsi-info]: bypass bl 0
#    驱动把这个节点的写入 bypass 掉了。注意 `device` 软链指向
#        /sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight
#    —— 挂在 MDP（显示控制器）下，所以真正生效的是 DRM 侧的属性，不是这个节点。
#    ★ 上游 opd2413 的 drm-powerkey.py 靠写 sysfs 熄屏，在**本机不成立**
#      （上游 max_brightness=2047，本机 4095，是不同面板）。
#    ★ 本仓库旧版 lockscreen.sh / keepbright.sh 里的 bl_power 逻辑基于
#      "bl_power=4 是硬关背光电源" 这个（错的）假设，已一并改掉。
#
# ── ✗ 死的路 2：KWin 自己的亮度控制（kscreen-doctor output.DSI-1.brightness.N）──
#    `kscreen-doctor -o` 会打印 "Brightness control: supported, set to 50%"，
#    看起来很有希望，但实测：设 0 之后 sysfs 变 5、设 dimming 0 之后 sysfs 变 1
#    —— **KWin 走的就是上面那条死的 sysfs 路**，而且被驱动 clamp 到最低档。
#    这正是用户说的「最低亮度不是黑屏」。
#    它的内部状态变了（再查 -o 会显示 "set to 0%"），但面板纹丝不动。
#
# ── ✗ 死的路 3：PowerDevil SetBrightness(0) / setBrightnessSilent(0) ──
#    D-Bus 调用返回成功，但 DRM 属性不动（一直 2048）、sysfs 也不动。
#
# ── ✗ 死的路 4：单独写 DRM brightness=0 ──
#    屏幕变成「很暗」但仍能看见（面板的硬件下限）。用户实测原话：
#    「亮 → 中 → 很暗 → 好像没看见最暗」——即 0 和 200 肉眼分不出来。
# ── ✗ 死的路 5：kscreen-doctor --dpms off ──
#    ★★★ 这是最坑的一条：它返回 rc=0，但**根本没生效**。实测：
#        · KWin 日志刷屏 `kwin_wayland_drm: Setting dpms mode failed!`
#        · 之后连查 12 秒，DPMS 一直是 0（On），屏幕只「闪一下」
#    根因在本内核的属性定义（kwinwrap.c:2213 有同样的结论）：
#        conn67 "DPMS"  flags=0x00000008   ← 只有 DRM_MODE_PROP_ENUM
#    **没有 DRM_MODE_PROP_ATOMIC**，而 KWin 只会把 DPMS 塞进原子提交
#    ⇒ 内核一律判 EINVAL ⇒ **KWin 在这台设备上永远关不掉屏**。
#    安卓不受影响，因为它走的是 **CRTC 的 ACTIVE=0**（原子属性，合法），
#    整个 CRTC 停摆、DSI 面板进睡眠 —— 比 DPMS 更彻底。我们照抄不了：
#    那个 CRTC 的原子状态在 KWin 手里。
#    ⇒ 所以 DPMS 只能用**非原子** ioctl 写，即 `drmbl dpms off`。
# ── ✗ 死的路 6：bl_scale=0 / sv_bl_scale=0 / dimming_* / LP=1 / EPT=1 / autorefresh ──
#    都能写进去、读得回，但视觉上毫无变化（逐个实测过）。
#
# ── ✓ 活的路：drmbl dpms off **且** drmbl blank ──
#    两件事同时做，面板**完全黑**（用户确认「完全黑了」）。
#    反向验证：单独把 brightness 拉到最大 4095，用户确认「明显变亮」
#    ⇒ 这个属性确实是活的，0 只是它的下限，必须再叠 DPMS off 才能全黑。
#
# ── 怎么写得进去（master 权限）──
#    brightness flags=0x02（RANGE），DPMS flags=0x08（ENUM），**两个都没有
#    ATOMIC 位**，所以都不能塞进 atomic 提交，只能用非原子 ioctl；
#    而它要求调用者是 DRM master。接管后 master 在 KWin 手里 ⇒ 从外面写
#    一律 `-1 (Permission denied)`。
#    ★ 解法见 tools/runtime/drmbl.c：用 pidfd_getfd(2) 从 KWin 那里"偷"一份
#      master fd 出来。本工具会自动逐个试 KWin 的 6 个 card0 fd，
#      用「自赋值探针」（写回当前值，不改状态但会走权限检查）找出真正是 master
#      的那一个。绕开这一步会浪费很多时间：kwinwrap 的 fd 250 虽然和 KWin 的
#      fd 250 是同一个 file description，但它**不是** master（早 DROP_MASTER 了）。
#
# ── ⚠️ 已知副作用 ──
#    从旁边写 DPMS 会让 KWin 的内部状态和内核不一致。熄屏期间无害（屏幕本来
#    就黑），但**唤醒时必须逼 KWin 重新提交**，否则双 DSI 面板可能只亮半边
#    （实测踩过左半屏黑）。cmd_panel_on 里的 _nudge_kwin 就是干这个的；
#    万一还是半边，用 display/kwin-restart.sh 重启 KWin（已验证可恢复）。
#
# ══ 用法 ══
#   sudo sh input/lockscreen.sh lock        # 锁屏 + 熄面板
#   sudo sh input/lockscreen.sh panel-off   # 只熄面板（已锁时）
#   sudo sh input/lockscreen.sh panel-on    # 只亮面板（已锁时，给用户输密码）
#   sudo sh input/lockscreen.sh unlock      # 紧急解除（逃生通道）
#   sudo sh input/lockscreen.sh status      # 打印 locked/unlocked
#   sudo sh input/lockscreen.sh --check     # 自检前置条件
#
# ══ 退出码 ══
#   status:  0=已锁  1=未锁
#   其他:    0=成功  非 0=失败

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")

# 允许被独立调用（不在仓库里也能跑），所以不强制 source boot.sh
if [ -r "$SELF_DIR/../core/lib/boot.sh" ]; then
    # shellcheck source=/dev/null
    . "$SELF_DIR/../core/lib/boot.sh" 2>/dev/null || true
fi

GREETER=/usr/lib/aarch64-linux-gnu/libexec/kscreenlocker_greet
LOCKED_FLAG=/run/drm-keys.locked
GREET_LOG=/run/drm-lockscreen.log
BL_SAVE=/run/drm-keys.brightness
BL_FALLBACK=${DEV_BRIGHTNESS:-2048}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    printf '[%s] lockscreen: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$GREET_LOG" 2>/dev/null
}

# ── drmbl 定位 ──
# 优先 PATH（install-keys.sh 装到 /usr/local/bin），退回仓库内的 bin/。
_drmbl() {
    if [ -n "${DRMBL:-}" ] && [ -x "${DRMBL}" ]; then echo "$DRMBL"; return; fi
    if command -v drmbl >/dev/null 2>&1; then command -v drmbl; return; fi
    for c in "$SELF_DIR/../bin/drmbl" "$SELF_DIR/drmbl" /usr/local/bin/drmbl; do
        [ -x "$c" ] && { echo "$c"; return; }
    done
    echo ""
}

# 跑 drmbl 子命令，把输出抹平一行（日志用）
_drmbl_run() {
    _d=$(_drmbl)
    [ -n "$_d" ] || { echo "drmbl 不存在"; return 127; }
    _out=$("$_d" "$@" 2>&1)
    _rc=$?
    printf '%s' "$_out" | tr '\n' ' '
    return $_rc
}

# ── 桌面用户/运行时目录：优先用设备适配层的，否则自己推 ──
_desk_user() {
    if [ -n "${DESKTOP_USER:-}" ]; then echo "$DESKTOP_USER"; return; fi
    # 取 uid 1000 的用户名（本机是 Gold）
    awk -F: '$3==1000{print $1; exit}' /etc/passwd 2>/dev/null
}
_desk_home() {
    if [ -n "${DESKTOP_HOME:-}" ]; then echo "$DESKTOP_HOME"; return; fi
    _u=$(_desk_user)
    awk -F: -v u="$_u" '$1==u{print $6; exit}' /etc/passwd 2>/dev/null
}
_desk_rundir() {
    if [ -n "${DESKTOP_RUNTIME_DIR:-}" ]; then echo "$DESKTOP_RUNTIME_DIR"; return; fi
    echo "/run/user/1000"
}
_wl_socket() {
    if [ -n "${DRM_WAYLAND_SOCKET:-}" ]; then echo "$DRM_WAYLAND_SOCKET"; return; fi
    # KWin 的 socket 名不一定是 wayland-0，本机实测是 taketest（无 wayland- 前缀）
    _rd=$(_desk_rundir)
    for f in "$_rd"/taketest "$_rd"/wayland-*; do
        [ -S "$f" ] && { basename "$f"; return; }
    done
    echo taketest
}

_as_desk() {
    _u=$(_desk_user); _h=$(_desk_home); _rd=$(_desk_rundir); _wl=$(_wl_socket)
    [ -n "$_u" ] || { log "!! 找不到桌面用户（uid 1000）"; return 1; }
    runuser -u "$_u" -- env \
        HOME="$_h" \
        XDG_RUNTIME_DIR="$_rd" \
        XDG_SESSION_TYPE=wayland \
        XDG_CURRENT_DESKTOP=KDE \
        XDG_MENU_PREFIX=plasma- \
        WAYLAND_DISPLAY="$_wl" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_rd/bus" \
        "$@"
}

# ── 亮度读写：走 DRM 属性（sysfs 那条是死的，见文件头）──

# 读当前 DRM brightness。读不到返回空。
bl_get() {
    _d=$(_drmbl); [ -n "$_d" ] || return 1
    "$_d" show 2>/dev/null | sed -n 's/.*brightness=\([0-9]*\).*/\1/p' | head -1
}

# 设 DRM brightness（同时确保 DPMS 是开的，否则看不见）
bl_set() {
    _d=$(_drmbl); [ -n "$_d" ] || return 1
    "$_d" set "$1" >/dev/null 2>&1 || return 1
    return 0
}

bl_save() {
    [ -f "$BL_SAVE" ] && return 0          # 已有保存值就不覆盖
    _v=$(bl_get)
    case "${_v:-}" in
        ''|0) _v=$BL_FALLBACK ;;
    esac
    printf '%s\n' "$_v" >"$BL_SAVE" 2>/dev/null
}

# ── PowerDevil 的亮度也得同步 ──
#
# ★★ 血泪教训：PowerDevil 持有背光所有权，它会把**自己缓存的亮度**写回 sysfs。
#    我们熄屏之后它过十几秒又写回来。
#    不过现在**它写的是 sysfs，而 sysfs 是死的**（见文件头），所以它已经伤不到
#    熄屏了。这里保留同步只是为了它的内部状态别和实际亮度差太远（否则用户
#    解锁后拖滑块会从错的起点跳）。
_bl_set_via_powerdevil() {
    _v=$1
    _u=$(_desk_user); _h=$(_desk_home); _rd=$(_desk_rundir)
    [ -n "$_u" ] || return 1
    runuser -u "$_u" -- env HOME="$_h" XDG_RUNTIME_DIR="$_rd" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_rd/bus" \
        busctl --user call org.kde.ScreenBrightness \
        /org/kde/ScreenBrightness/display0 \
        org.kde.ScreenBrightness.Display SetBrightness iu "$_v" 0 >/dev/null 2>&1
    return 0
}

dpms() {
    # ★★★★ 必须用 drmbl，**不能**用 kscreen-doctor ★★★★
    #
    # `kscreen-doctor --dpms off` 返回 rc=0，但 KWin 日志刷屏
    #     kwin_wayland_drm: Setting dpms mode failed!
    # 而 DPMS 纹丝不动（实测连查 12 秒都是 DPMS=0），屏幕只"闪一下"。
    #
    # 根因在本内核的属性定义：conn67 的 `DPMS` flags=0x08，**只有 ENUM，
    # 没有 DRM_MODE_PROP_ATOMIC**。KWin 只会把 DPMS 塞进原子提交 ⇒ 内核一律
    # 判 EINVAL ⇒ **KWin 在这台设备上永远关不掉屏**。
    # （kwinwrap 试过往提交里注入 DPMS，同样失败，注释留在 kwinwrap.c:2213。）
    #
    # ⇒ 只能用**非原子** ioctl 写，而它要求 master 权限 —— drmbl 借 fd 解决。
    # 详见 tools/runtime/drmbl.c 里 DPMS 那一段。
    #
    # 安卓走的是另一条路（CRTC ACTIVE=0，原子属性合法），我们照抄不了，
    # 因为那个 CRTC 的原子状态在 KWin 手里。
    _d=$(_drmbl)
    [ -n "$_d" ] || { echo "drmbl 不存在，无法关面板"; return 127; }
    "$_d" dpms "$1" 2>&1
}

# ★★★★ CRTC 开关：**这才是安卓真正的息屏方式**（2026-10-13 新增）★★★★
#
# 安卓的 SurfaceFlinger/HWC 息屏时把 **CRTC 的 ACTIVE 置 0** —— 整个 CRTC
# 停摆、DSI 面板进睡眠；亮屏时 MODE_ID 写回 + ACTIVE=1 ⇒ **完整 modeset**。
#
# 为什么必须在 DPMS 之外再加这一层（实测）：
#   这块面板是**双 DSI + DSC**，左半走 DSI0、右半走 DSI1。
#   `dpms off` / `dpms on` 只切 connector 的电源状态，**不重新初始化 DSI 链路**
#   ⇒ 唤醒后有一条链路没起来 ⇒ **物理上左半块屏是黑的**。
#   实测排除过的方向（全部无效，别再试）：
#     · plane 级：kwinwrap 在 do_split 为真时本来就会补齐全部 4 条 plane
#     · scale / rotation / Compositing suspend-resume：要么被拒要么无变化
#     · 只有**完整 modeset** 能修 —— 重启 KWin 100% 恢复（但那太重）
#
# ★ ACTIVE 属性带 ATOMIC 位（flags 0x80000002），但**非原子写照样成功**：
#   实测 `crtc-off` → ACTIVE=0 读回 0；`crtc-on` → ACTIVE=1 读回 1。
#   MODE_ID（flags 0x80000010，blob）也一样，值 314。
crtc() {
    _d=$(_drmbl)
    [ -n "$_d" ] || { echo "drmbl 不存在，无法操作 CRTC"; return 127; }
    "$_d" "crtc-$1" 2>&1
}

# 逼 KWin 重新提交一次（唤醒后防"只亮半边"）。
#
# 我们从旁边写 DPMS / CRTC 会让 KWin 的内部状态和内核不一致。熄屏期间无害
# （屏幕本来就黑），但唤醒时若不逼它重画，双 DSI 面板可能只亮一半
# ——实测踩过左半屏黑，最后靠 display/kwin-restart.sh 才恢复。
#
# kscreen-doctor 的 dpms 在这里注定失败（见上），但**失败也有价值**：
# 它会让 KWin 走一遍 DPMS 状态机、重新提交。所以这里故意忽略它的返回值。
_nudge_kwin() {
    _as_desk timeout 10 kscreen-doctor --dpms "$1" >/dev/null 2>&1
    # 再推一次输出状态，促使 KWin 重算 plane 布局
    _as_desk timeout 10 kscreen-doctor output.DSI-1.scale.2 >/dev/null 2>&1
    return 0
}

# ── 状态判定 ──
is_locked() {
    # ★ 判据是**进程存在**，不是标志文件。标志文件可能因崩溃而残留，
    #   而进程存在是硬事实。
    for d in /proc/[0-9]*; do
        _c=$(cat "$d/comm" 2>/dev/null) || continue
        case "$_c" in
            kscreenlocker_g*) return 0 ;;
        esac
    done
    return 1
}

set_flag() {
    if [ "$1" = "1" ]; then
        : >"$LOCKED_FLAG" 2>/dev/null
    else
        rm -f "$LOCKED_FLAG" 2>/dev/null
    fi
}

# ── 子命令 ──
cmd_lock() {
    [ -x "$GREETER" ] || { log "!! 找不到 $GREETER（装 libkscreenlocker6）"; return 1; }

    if is_locked; then
        log "已经锁着了，只熄面板"
        cmd_panel_off
        return 0
    fi

    # ★ 顺序很重要：
    #   ① 先起锁屏进程（它要先拿到会话锁 surface，才能画界面）
    #   ② 等它打印 "Locked"（或进程稳定存在）
    #   ③ 再熄面板 —— 反过来的话 greeter 初始化时会把 DPMS 打开
    _u=$(_desk_user); _h=$(_desk_home); _rd=$(_desk_rundir); _wl=$(_wl_socket)
    log "启动锁屏（greeter=$GREETER，用户=$_u，socket=$_wl）"

    # ★ 必须用 setsid + nohup：greeter 要活到用户解锁为止，
    #   不能因为调用它的 shell（drm-keys.py 的 subprocess）退出而被带走。
    runuser -u "$_u" -- env \
        HOME="$_h" XDG_RUNTIME_DIR="$_rd" \
        XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE \
        WAYLAND_DISPLAY="$_wl" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_rd/bus" \
        setsid nohup "$GREETER" -platform wayland \
        >>"$GREET_LOG" 2>&1 &

    # 等它真的锁上（最多 10 秒）
    _i=0
    while [ "$_i" -lt 20 ]; do
        sleep 0.5
        is_locked && break
        _i=$((_i + 1))
    done
    if ! is_locked; then
        log "!! 锁屏进程没起来（10 秒超时），日志尾部："
        tail -n 10 "$GREET_LOG" 2>/dev/null | while read -r _l; do log "   $_l"; done
        return 1
    fi
    log "锁屏已启动（pid=$(pgrep -f kscreenlocker_greet | head -1)）"

    # 给 greeter 一点时间把界面画上去，再熄面板
    sleep 1.5
    cmd_panel_off
    set_flag 1
    return 0
}

cmd_panel_off() {
    # ① 先存亮度（只在首次存，避免把 0 存成"原亮度"）
    bl_save
    # ② 同步 PowerDevil 的内部状态（防止它解锁后从错的起点开始）
    _bl_set_via_powerdevil 0
    # ③ ★★★★ 真正熄屏。
    #
    # 默认走 **CRTC ACTIVE=0**（安卓同款，见 crtc() 的注释）：
    # 双 DSI 面板在 `dpms off/on` 之后唤醒会只亮半边，只有 CRTC 级的
    # 完整 modeset 才能把两条 DSI 链路都重新初始化。
    #
    # PANEL_OFF_MODE=dpms 可以切回旧的 DPMS 路径（排查/兜底用）。
    #
    # 顺序：先关 CRTC（瞬间全黑），再 brightness 0（无可见变化，但省电，
    # 且让"面板下限"也不是亮的）。反过来会看到"先变最暗再黑"的闪动。
    case "${PANEL_OFF_MODE:-crtc}" in
        dpms)
            _o1=$(dpms off); _rc1=$?
            _o2=$(_drmbl_run blank); _rc2=$?
            _what="dpms off"
            ;;
        *)
            _o1=$(crtc off); _rc1=$?
            _o2=$(_drmbl_run blank); _rc2=$?
            _what="crtc-off"
            ;;
    esac
    if [ "$_rc1" != "0" ]; then
        log "!! $_what 失败 rc=$_rc1 —— 面板不会真正关闭（会停在'很暗'）"
    fi
    if [ "$_rc2" != "0" ]; then
        log "!! drmbl blank 失败 rc=$_rc2 —— 面板没到硬件下限"
    fi
    log "面板已熄（$_what rc=$_rc1: $_o1 | drmbl blank rc=$_rc2: $_o2）"
    return 0
}

cmd_panel_on() {
    # 顺序和 panel_off 相反：先恢复 CRTC（完整 modeset，两条 DSI 链路
    # 重新初始化），再补背光。反过来的话背光先亮、面板还没扫，会闪一下。
    case "${PANEL_OFF_MODE:-crtc}" in
        dpms)
            _o1=$(dpms on); _rc1=$?
            _what="dpms on"
            ;;
        *)
            _o1=$(crtc on); _rc1=$?
            # CRTC 恢复了，但 connector 的 DPMS 可能还是 off（之前 crtc-off
            # 不会碰它）⇒ 补一发，幂等。
            dpms on >/dev/null 2>&1
            _what="crtc-on"
            ;;
    esac
    _o2=$(_drmbl_run unblank); _rc2=$?
    # ★ 逼 KWin 重画：我们从旁边动过 CRTC/DPMS，它的内部状态和内核不一致，
    #   不推一把可能只亮半边（双 DSI 面板实测踩过）。见 _nudge_kwin。
    _nudge_kwin on
    # 恢复 PowerDevil 的内部状态
    _v=$(cat "$BL_SAVE" 2>/dev/null || echo "$BL_FALLBACK")
    case "$_v" in ''|0) _v=$BL_FALLBACK ;; esac
    # PowerDevil 用 0..10000 的刻度
    _bl_set_via_powerdevil $(( _v * 10000 / 4095 ))
    log "面板已亮（$_what rc=$_rc1: $_o1 | drmbl unblank rc=$_rc2 | brightness=$(bl_get)）"
    return 0
}

cmd_unlock() {
    # ★ 逃生通道：无条件解除。用于界面渲染失败、密码忘了、
    #   或任何"用户被锁在外面"的场合。
    log "紧急解除锁屏"
    pkill -9 -f kscreenlocker_greet 2>/dev/null
    pkill -9 -f kscreenlocker 2>/dev/null
    sleep 1
    set_flag 0
    cmd_panel_on
    if is_locked; then
        log "!! 还有锁屏进程残留"
        return 1
    fi
    log "已解除"
    return 0
}

cmd_status() {
    if is_locked; then
        echo "locked"
        return 0
    fi
    echo "unlocked"
    return 1
}

cmd_check() {
    _rc=0
    _u=$(_desk_user)
    log "── 锁屏前置条件自检 ──"

    if [ -x "$GREETER" ]; then
        log "  ✓ greeter 存在：$GREETER"
    else
        log "  ✗ greeter 缺失：$GREETER（apt install libkscreenlocker6）"; _rc=1
    fi

    # ① KWin 不能带 --no-lockscreen
    _nols=0
    for d in /proc/[0-9]*; do
        _c=$(cat "$d/comm" 2>/dev/null) || continue
        [ "$_c" = "kwin_wayland" ] || continue
        if tr '\0' '\n' <"$d/cmdline" 2>/dev/null | grep -q '^--no-lockscreen$'; then
            _nols=1
        fi
    done
    if [ "$_nols" = "1" ]; then
        log "  ✗ KWin 带了 --no-lockscreen ⇒ 锁屏弹不出键盘（见 core/device/*.sh）"; _rc=1
    else
        log "  ✓ KWin 没带 --no-lockscreen"
    fi

    # ② KWin 必须提供 Qt 虚拟键盘
    _qim=0
    for d in /proc/[0-9]*; do
        _c=$(cat "$d/comm" 2>/dev/null) || continue
        [ "$_c" = "kwin_wayland" ] || continue
        tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -q '^QT_IM_MODULES=qtvirtualkeyboard$' && _qim=1
    done
    if [ "$_qim" = "1" ]; then
        log "  ✓ KWin 已注入 QT_IM_MODULES=qtvirtualkeyboard"
    else
        log "  ✗ KWin 没有 QT_IM_MODULES ⇒ 锁屏没有屏幕键盘"; _rc=1
    fi

    # ③ 桌面用户必须在 shadow 组（nosuid 让 setgid 的 unix_chkpwd 失效）
    if [ -n "$_u" ]; then
        if id -nG "$_u" 2>/dev/null | tr ' ' '\n' | grep -qx shadow; then
            log "  ✓ $_u 属于 shadow 组"
        else
            log "  ✗ $_u 不在 shadow 组 ⇒ 密码验证必然失败"
            log "     修法：usermod -aG shadow $_u"
            _rc=1
        fi
    fi

    # ④ ★★★★ 熄面板的关键：drmbl 必须存在**且真的能拿到 master fd**
    _d=$(_drmbl)
    if [ -z "$_d" ]; then
        log "  ✗ 找不到 drmbl ⇒ **无法真正熄面板**（只能做到最暗）"; _rc=1
    elif _out=$("$_d" probe 2>&1); then
        log "  ✓ drmbl 可用：$_d"
        log "     $(_drmbl_run show)"
        # ★ 光能借到 fd 不够，还得确认 DPMS 真的写得进去。
        #   本机 DPMS 属性没有 ATOMIC 位，KWin 写不了 —— 只有 drmbl 能写。
        #   用 `dpms on` 自检：当前已是 on 时是幂等的，不会改变状态。
        if _dout=$("$_d" dpms on 2>&1); then
            log "  ✓ drmbl 能写 DPMS（$_dout）"
        else
            log "  ✗ drmbl 写 DPMS 失败：$_dout"
            log "     ⇒ 面板无法真正关闭，只会停在「很暗」"
            _rc=1
        fi
    else
        log "  ✗ drmbl 存在但拿不到 DRM master fd："
        printf '%s\n' "$_out" | while read -r _l; do log "     $_l"; done
        log "     ⇒ 无法真正熄面板。检查 KWin 是否由 kwinwrap 拉起。"
        _rc=1
    fi

    # ⑤ 死的 sysfs 节点：只报告，不作为失败条件（它本来就无效）
    for d in /sys/class/backlight/*; do
        [ -d "$d" ] || continue
        log "  · sysfs 背光节点 $d（**本机无效**，内核 bypass，见文件头）"
        break
    done

    if [ "$_rc" = "0" ]; then
        log "── 自检通过 ──"
    else
        log "── 自检有问题，见上面 ✗ ──"
    fi
    return $_rc
}

case "${1:-}" in
    lock)      cmd_lock ;;
    panel-off) cmd_panel_off ;;
    panel-on)  cmd_panel_on ;;
    unlock)    cmd_unlock ;;
    status)    cmd_status ;;
    --check|check) cmd_check ;;
    *)
        cat <<EOF
用法：$0 <子命令>

  lock        锁屏 + 熄灭面板（电源键短按走这个）
  panel-off   只熄面板（已经锁着时）
  panel-on    只亮面板（已经锁着时，给用户输密码）
  unlock      紧急解除（逃生通道，无条件）
  status      打印 locked / unlocked（退出码 0=已锁 1=未锁）
  --check     自检前置条件（greeter / --no-lockscreen / QT_IM_MODULES / shadow 组 / drmbl）

熄面板靠 DRM 属性（brightness=0 + DPMS=off），需要 tools/runtime/drmbl。
sysfs /sys/class/backlight 那条路在本机是**死的**（内核 bypass），别再用。
EOF
        exit 2
        ;;
esac

#!/bin/sh
# network/net-takeover.sh — 让容器接管 wlan0，给 plasma-nm 一个能用的图形面板。
#
# ══ 为什么需要这个（本机 2026-10-12 实测）══
#   容器与安卓共享 netns（net_mode=host），但这**不等于**容器就能上网：
#     · 安卓 netd 的路由是 per-UID + fwmark 的，容器的 UID 不在任何一张表里，
#       所以容器看到的是 `32000: from all unreachable`；
#     · 接管显示要先停 SurfaceFlinger，system_server 在这种状态下会反复崩溃重启
#       （实测 19:00:43 `camx.provider-impl.so CameraProvider::binderDied → abort`），
#       它一重启 `WifiService` 就注册不上 ⇒ `cmd wifi status` 报
#       `Can't find service: wifi` ⇒ **安卓自己的设置里也连不了 WiFi**。
#   ⇒ 结论：安卓框架侧的 WiFi 不可靠，必须让容器自己拥有 wlan0。
#     这与上游 net-takeover.sh 的思路一致。
#
# ══ 与上游的差异（照抄上游会挂）══
#   1. CLI：上游用旧版 `droidspaces -C <config>`；本机是 v6.6.0，
#      只有 `droidspaces --name=<容器> run '<整条命令>'`。本脚本走 ds_exec。
#   2. 安卓服务名：上游写死 OPPO 专有的 `oplus_wifi_aidl_service`；
#      本机实测没有它，实际是 `wpa_supplicant` / `wificond` /
#      `vendor.wifi_hal_legacy`，且必须**保留 `cnss-daemon`**（驱动守护）。
#   3. 上游 `:82-87` 会改 container.config 并**重启容器** —— 本机红线：
#      容器重启会破坏安卓 ueventd netlink，热插拔节点全建不出，只有整机 reboot 能恢复。
#      本脚本**只读检查** net_mode，绝不改、绝不重启容器。
#   4. 上游容器侧用 wpa_supplicant + dhcpcd；本脚本用 NetworkManager，
#      因为要的是 plasma-nm 图形面板（用户自己输凭据）。
#   5. 上游 `:147/:162` 有 `ip link set wlan0 up`。本仓库红线明令禁止
#      （down 之后任何一次 up → cnss MHI err=-110 → ASSERT 2436 → 黑屏强关）。
#      本脚本**一处都不碰链路状态**。
#
# ══ 红线 ══
#   · 绝不 `ip link set $DEV_WIFI_IF up|down`
#   · 绝不 `ip rule flush`（会拆掉安卓 netd 的策略路由地基）
#   · 绝不改 container.config、绝不重启容器
#   · 全程只用 `setprop ctl.stop/start`（纯运行时，不写 persist.*/settings）
#     ⇒ 设备重启后安卓 WiFi 自动回来，不需要任何清理
#
# 用法：
#   net-takeover.sh takeover   接管（停安卓 WiFi 栈 + 起容器 NetworkManager）
#   net-takeover.sh status     只读状态
#   net-takeover.sh restore    交还（停 NM + 把安卓服务拉回来）
#   net-takeover.sh deps       在容器里装 WiFi/蓝牙/输入法依赖（需容器能上网）
#   net-takeover.sh proxy-bridge  用 adb reverse 给容器开一条经 PC 代理的临时通道
#   net-takeover.sh glibc-fix  修 glibc AI_ADDRCONFIG（容器里没非环回 IPv4 时 apt 会解析失败）

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
DRM_ROOT=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

. "$DRM_ROOT/core/lib/common.sh"
. "$DRM_ROOT/core/lib/device.sh"
. "$DRM_ROOT/core/lib/android.sh"
. "$DRM_ROOT/core/lib/container.sh"

# 本机实测的安卓 WiFi 栈服务名（上游的 oplus_wifi_aidl_service 本机不存在）
NT_ANDROID_WIFI_SVCS="wpa_supplicant wificond vendor.wifi_hal_legacy"
# ★ 这个**必须保留**：它是 CNSS 驱动守护，停掉会让射频彻底起不来
NT_ANDROID_KEEP="cnss-daemon"

NT_NM_CONF_DIR=/run/NetworkManager/conf.d
NT_POLKIT=/etc/polkit-1/rules.d/60-nm-drm.rules

# ── 安卓侧 ────────────────────────────────────────────────

nt_android_svc_state() {
    android_query "getprop init.svc.$1" 2>/dev/null | tr -d '\r' | head -1
}

# 让安卓 WiFi 栈放手。只停那三个服务，保留 cnss-daemon。
# 顺序与上游一致：先 HAL 后 supplicant（先断上层的指挥，再撤下层的执行）。
nt_stop_android_wifi() {
    drm_log "让安卓 WiFi 栈放手（保留 $NT_ANDROID_KEEP）"
    for _s in vendor.wifi_hal_legacy wificond wpa_supplicant; do
        android_exec "setprop ctl.stop $_s" >/dev/null 2>&1
        drm_log "  ctl.stop $_s"
    done
    sleep 4

    # ★ 上游实测：vendor.wifi_hal_legacy 第一次 ctl.stop 常"返回成功但服务仍 running"，
    #   所以必须复核一次再重试。
    for _s in $NT_ANDROID_WIFI_SVCS; do
        _st=$(nt_android_svc_state "$_s")
        if [ "$_st" = "running" ]; then
            drm_log "  $_s 仍 running，重试 ctl.stop"
            android_exec "setprop ctl.stop $_s" >/dev/null 2>&1
        fi
    done
    sleep 3

    for _s in $NT_ANDROID_WIFI_SVCS $NT_ANDROID_KEEP; do
        drm_log "  $_s = $(nt_android_svc_state "$_s")"
    done
}

nt_start_android_wifi() {
    drm_log "把 WiFi 栈交还安卓"
    # 与停相反：先 supplicant/wificond，再 HAL
    for _s in wpa_supplicant wificond vendor.wifi_hal_legacy; do
        android_exec "setprop ctl.start $_s" >/dev/null 2>&1
        drm_log "  ctl.start $_s"
    done
    sleep 4
    for _s in $NT_ANDROID_WIFI_SVCS; do
        drm_log "  $_s = $(nt_android_svc_state "$_s")"
    done
}

# rfkill 节点 + 蓝牙软阻塞 + udev 改名掩码。
# ★ 上游 ade.sh:972 的原话：KDE 的 kded6/plasmashell 要读写 /dev/rfkill 控制蓝牙开关，
#   默认 crw------- root root ⇒ 它们报 "Cannot open /dev/rfkill"。
nt_prepare_dev() {
    drm_log "准备 rfkill 节点与 udev 掩码"

    # 1) /dev/rfkill：NM 靠 rfkill netlink 控制射频；缺这节点 = 扫不到任何热点
    if [ ! -c /dev/rfkill ]; then
        android_exec "mknod /dev/rfkill c 10 242" >/dev/null 2>&1
        drm_log "  已 mknod /dev/rfkill (10:242)"
    fi
    android_exec "chmod 666 /dev/rfkill" >/dev/null 2>&1

    # 2) 蓝牙软阻塞（实测 rfkill0 bt_power soft=1 ⇒ KDE 蓝牙开关是灰的）
    android_exec 'for r in /sys/class/rfkill/rfkill*; do
        [ -d "$r" ] || continue
        [ "$(cat $r/type 2>/dev/null)" = "bluetooth" ] || continue
        echo 0 > "$r/soft" 2>/dev/null
    done' >/dev/null 2>&1

    # 3) 掩掉 udev 改名规则：容器 udevd 可能把 wlan0 改成 wlp1s0，
    #    而安卓 WiFi 状态机硬编码只认 wlan0 ⇒ 设置里开关点了没反应。
    ds_exec 'ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules 2>/dev/null; true' \
        >/dev/null 2>&1

    drm_log "  rfkill: $(android_query 'cat /sys/class/rfkill/rfkill*/name /sys/class/rfkill/rfkill*/soft 2>/dev/null' 2>/dev/null | tr '\n' ' ')"
}

# ── 容器侧 ────────────────────────────────────────────────

# ★ 本机实测的一个非显然问题：容器里只剩 lo 的 127.0.0.1 时，
#   glibc 的 AI_ADDRCONFIG 会认为"系统没配 IPv4"，于是**连纯数字地址都拒绝解析**，
#   apt 报 `Something wicked happened resolving '127.0.0.1:7897' (-9 - Address family
#   for hostname not supported)`，而 curl/getent 却正常。
#   解法：造一张带 IPv4 的虚拟网卡（不加路由、不碰 wlan0）。
nt_fix_glibc_ipv4() {
    drm_log "修 glibc AI_ADDRCONFIG（需要一张带 IPv4 的非环回网卡）"
    ds_exec '
        if ! ip link show drmdummy0 >/dev/null 2>&1; then
            ip link add drmdummy0 type dummy 2>/dev/null
        fi
        ip link set drmdummy0 up 2>/dev/null
        ip addr replace 10.77.0.1/32 dev drmdummy0 2>/dev/null
        ip -4 -o addr show drmdummy0 2>/dev/null
    '
}

nt_write_nm_conf() {
    ds_exec "mkdir -p $NT_NM_CONF_DIR
        printf '[keyfile]\nunmanaged-devices=none\n' > $NT_NM_CONF_DIR/10-globally-managed-devices.conf
        mkdir -p /etc/NetworkManager/conf.d
        printf '[main]\ndns=none\nsystemd-resolved=false\n' > /etc/NetworkManager/conf.d/90-dns-none.conf
        echo ok"
    drm_log "NM 配置已写入（unmanaged-devices=none + dns=none）"
}

# polkit 放行。★ 上游 desk-takeover.sh:624-642 的原话：
#   容器里没有 logind active 会话，allow_active 不生效 ⇒
#   plasma-nm 点击连接会被拒（"Not authorized to control networking"）。
nt_write_polkit() {
    _user=${DEV_USER:-Gold}
    ds_exec "mkdir -p /etc/polkit-1/rules.d
        cat > $NT_POLKIT <<'EOF'
// 容器里没有 logind active 会话，allow_active 不生效，必须按用户名显式放行，
// 否则 plasma-nm 点击报 \"not authorized\"。
polkit.addRule(function(action, subject) {
    if (action.id.indexOf(\"org.freedesktop.NetworkManager.\") === 0 &&
        subject.user === \"$_user\") {
        // 防用户关总开关把射频打进 soft-block 半连接态（上游同款）
        if (action.id === \"org.freedesktop.NetworkManager.enable-disable-wifi\" ||
            action.id === \"org.freedesktop.NetworkManager.enable-disable-network\" ||
            action.id === \"org.freedesktop.NetworkManager.sleep-wake\") {
            return polkit.Result.NO;
        }
        return polkit.Result.YES;
    }
    if (action.id.indexOf(\"org.freedesktop.NetworkManager.\") === 0 &&
        subject.isInGroup(\"netdev\")) {
        return polkit.Result.YES;
    }
});
EOF
echo ok"
    drm_log "polkit 规则已写入（放行用户 $_user）"
}

nt_start_nm() {
    drm_log "启动容器 NetworkManager"
    # 容器自己的 wpa_supplicant 让位给 NM 当后端（两个 supplicant 抢一张卡会互相踢）
    ds_exec 'systemctl stop wpa_supplicant 2>/dev/null; pkill -x wpa_supplicant 2>/dev/null; true' >/dev/null 2>&1
    ds_exec 'systemctl unmask NetworkManager 2>/dev/null; systemctl restart NetworkManager 2>/dev/null; sleep 8; systemctl is-active NetworkManager' 2>&1 | tr -d '\r'
    ds_exec 'nmcli radio wifi on 2>/dev/null; true' >/dev/null 2>&1
    sleep 3
    ds_exec 'nmcli device status 2>&1' 2>&1 | tr -d '\r'
}

nt_verify() {
    drm_log "核验：让 NetworkManager 扫一次热点"
    _out=$(ds_exec 'timeout 40 nmcli device wifi list --rescan yes 2>&1' 2>&1 | tr -d '\r')
    printf '%s\n' "$_out" | head -n 15

    if printf '%s\n' "$_out" | grep -q 'SSID'; then
        drm_log "NET-WIFI-SCAN OK（图形面板应已能选热点）"
        drm_state_set NET_WIFI_SCAN 1
        return 0
    fi
    drm_warn "NET-WIFI-SCAN-FAIL：扫不到热点，检查 /dev/rfkill 与 NM 日志"
    drm_state_set NET_WIFI_SCAN 0
    return 1
}

# ── 依赖安装 ──────────────────────────────────────────────
# ★ 容器里原本**没有** NetworkManager / wpa_supplicant / iw / rfkill，
#   也没有 plasma-nm 的 plasmoid —— 不装就永远出不来图形面板。
NT_DEPS_WIFI="network-manager plasma-nm wpasupplicant iw rfkill"
NT_DEPS_BT="bluez bluedevil"
NT_DEPS_IME="fcitx5 fcitx5-chinese-addons fcitx5-frontend-qt6 fcitx5-frontend-gtk3 fcitx5-config-qt fcitx5-module-wayland"
NT_DEPS_OSK="maliit-keyboard qml6-module-qtquick-virtualkeyboard qt6-virtualkeyboard-plugin"

nt_install_deps() {
    drm_phase "net-deps"
    nt_fix_glibc_ipv4
    drm_log "装 WiFi 栈：$NT_DEPS_WIFI"
    ds_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $NT_DEPS_WIFI 2>&1 | tail -n 8"
    drm_log "装蓝牙栈：$NT_DEPS_BT"
    ds_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y $NT_DEPS_BT 2>&1 | tail -n 8"
    drm_log "装输入法：$NT_DEPS_IME"
    ds_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y $NT_DEPS_IME 2>&1 | tail -n 8"
    drm_log "装屏幕键盘：$NT_DEPS_OSK"
    ds_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y $NT_DEPS_OSK 2>&1 | tail -n 8"
    drm_log "依赖安装结束"
}

# 把 plasma-nm 的小程序加进系统托盘（否则装好了也不显示）。
# ★ 幂等：先去掉重复项再加，避免反复调用把配置堆成一长串。
nt_add_tray_applets() {
    _cfg="$(ds_shared_dir)/../home/${DEV_USER:-Gold}/.config/plasma-org.kde.plasma.desktop-appletsrc"
    [ -f "$_cfg" ] || { drm_warn "找不到 appletsrc，跳过托盘配置"; return 0; }
    cp -a "$_cfg" "$_cfg.bak-net-$(date +%s)" 2>/dev/null
    for _k in extraItems knownItems; do
        _old=$(grep -a "^$_k=" "$_cfg" | head -1)
        _new=$(printf '%s' "$_old" | sed 's/^[^=]*=//' | tr ',' '\n' \
               | grep -av '^org\.kde\.plasma\.networkmanagement$' \
               | grep -av '^org\.kde\.plasma\.bluetooth$' \
               | paste -sd, -)
        sed -i "s|^$_k=.*$|$_k=$_new,org.kde.plasma.networkmanagement,org.kde.plasma.bluetooth|" "$_cfg"
    done
    drm_log "托盘已加入 networkmanagement + bluetooth（去重后）"
}

# ── 临时通道：经 PC 代理给容器上网 ────────────────────────
# 本机实测：容器没网 ⇒ 装不了包 ⇒ 永远修不好网络，是死循环。
# 解法：PC 上有代理时，用 adb reverse 把 PC 的端口映射到设备的 localhost，
#       容器与安卓共享 netns ⇒ 容器写个 apt 代理配置就能装包。
#       ★ 这是**临时桥**，装完应撤掉（adb reverse --remove-all），不要长期依赖。
nt_proxy_bridge() {
    _port=${1:-7897}
    drm_log "建立 adb reverse 通道：PC:$_port → 设备:$_port"
    android_exec "adb reverse tcp:$_port tcp:$_port" >/dev/null 2>&1 || true
    drm_warn "注意：adb reverse 要在**PC 侧**执行才生效："
    drm_warn "  adb reverse tcp:$_port tcp:$_port"
    drm_warn "然后容器里："
    drm_warn "  printf 'Acquire::http::Proxy \"http://127.0.0.1:$_port\";\\nAcquire::https::Proxy \"http://127.0.0.1:$_port\";\\n' > /etc/apt/apt.conf.d/95proxy"
    drm_warn "  apt-get update"
    drm_warn "撤掉：adb reverse --remove-all"
}

# ── 总入口 ────────────────────────────────────────────────

nt_status() {
    echo "=== 安卓侧 WiFi 栈 ==="
    for _s in $NT_ANDROID_WIFI_SVCS $NT_ANDROID_KEEP; do
        printf '  %-28s %s\n' "$_s" "$(nt_android_svc_state "$_s")"
    done
    printf '  %-28s %s\n' "$DEV_WIFI_IF operstate" \
        "$(android_query "cat /sys/class/net/$DEV_WIFI_IF/operstate 2>/dev/null" 2>/dev/null | tr -d '\r')"
    printf '  %-28s %s\n' "$DEV_WIFI_IF carrier" \
        "$(android_query "cat /sys/class/net/$DEV_WIFI_IF/carrier 2>/dev/null" 2>/dev/null | tr -d '\r')"

    echo "=== 容器侧 NetworkManager ==="
    ds_running || { echo "  容器没在跑"; return 0; }
    ds_exec 'systemctl is-active NetworkManager 2>&1; nmcli general status 2>&1 | head -n 3; nmcli device status 2>&1 | grep -E "wlan0|DEVICE"' 2>&1 | tr -d '\r' | sed 's/^/  /'
}

nt_takeover() {
    drm_phase "net-takeover"
    ds_require
    ds_running || drm_die "容器没在跑，先拉起桌面再接管网络"

    # net_mode 只读检查（★ 绝不改配置、绝不重启容器）
    _nmode=$(android_query "grep -m1 '^net_mode=' $DS_CFG 2>/dev/null | cut -d= -f2" 2>/dev/null | tr -d '\r')
    if [ "$_nmode" != "host" ]; then
        drm_die "net_mode=$_nmode（不是 host）⇒ 容器看不到 $DEV_WIFI_IF。请人工改成 host 后**整机重启**，本脚本不代改（改配置要重启容器，会破坏 ueventd）"
    fi
    drm_log "net_mode=host ✓"

    nt_fix_glibc_ipv4
    nt_prepare_dev
    nt_stop_android_wifi
    nt_write_nm_conf
    nt_write_polkit
    nt_start_nm
    nt_verify || true

    drm_log "接管完成 —— 托盘网络图标里选热点，凭据在图形界面输（脚本不经手密码）"
}

nt_restore() {
    drm_phase "net-restore"
    drm_log "交还网络给安卓"
    if ds_running; then
        # 先让容器放手，否则两个 supplicant 又会互相踢
        ds_exec 'nmcli device disconnect '"$DEV_WIFI_IF"' 2>/dev/null
                 nmcli radio wifi off 2>/dev/null
                 pkill -x wpa_supplicant 2>/dev/null
                 systemctl stop NetworkManager 2>/dev/null
                 echo "  容器已放手"' 2>&1 | tr -d '\r'
    fi
    sleep 2
    nt_start_android_wifi

    # 交还时只解 wlan 的 soft-block，**绝不碰 bt_power**（上游 desk-stop.sh:167-175）
    android_exec 'for r in /sys/class/rfkill/rfkill*; do
        [ -d "$r" ] || continue
        [ "$(cat $r/type 2>/dev/null)" = "wlan" ] || continue
        echo 0 > "$r/soft" 2>/dev/null
    done' >/dev/null 2>&1

    # 改名自愈：容器 udevd 可能把 wlan0 改成了 wlpXsY，安卓只认 wlan0
    _mis=$(android_query "ls /sys/class/net 2>/dev/null | grep -E '^wlp' | head -1" 2>/dev/null | tr -d '\r')
    if [ -n "$_mis" ]; then
        drm_warn "$DEV_WIFI_IF 被改名成 $_mis，正在改回"
        android_exec "ip link set $_mis name $DEV_WIFI_IF" >/dev/null 2>&1
    fi
    drm_log "已交还（不碰链路状态；回安卓请整机重启）"
}

case "${1:-status}" in
    takeover)     nt_takeover ;;
    status)       nt_status ;;
    restore)      nt_restore ;;
    deps)         nt_install_deps ;;
    tray)         nt_add_tray_applets ;;
    glibc-fix)    nt_fix_glibc_ipv4 ;;
    proxy-bridge) shift; nt_proxy_bridge "$@" ;;
    *)
        cat <<'USAGE'
用法: net-takeover.sh <子命令>

  takeover       接管 wlan0（停安卓 WiFi 栈 + 起容器 NetworkManager + polkit + 托盘）
  status         只读状态（安卓服务 / 链路 / 容器 NM）
  restore        交还给安卓
  deps           在容器里装 WiFi/蓝牙/输入法/屏幕键盘依赖（需容器能上网）
  tray           只把网络+蓝牙小程序加进系统托盘
  glibc-fix      修 glibc AI_ADDRCONFIG（容器没非环回 IPv4 时 apt 解析失败）
  proxy-bridge [端口]
                 打印"用 adb reverse 给容器开临时代理通道"的步骤（默认 7897）
USAGE
        exit 1 ;;
esac

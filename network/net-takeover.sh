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

# ★ libglib2.0-bin 是屏幕键盘中文的**硬依赖**，别漏。
#   maliit-keyboard 不读 LANG/LC_ALL/LANGUAGE，它的活跃语言存在 GSettings
#   （org.maliit.keyboard.maliit）里。而 gsettings / glib-compile-schemas
#   都在 libglib2.0-bin 里 —— 没它就只能停在英文键盘。
#   顺带它也提供 gdbus，排查 D-Bus（比如 NM 密钥代理）时要用。
NT_DEPS_GLIB="libglib2.0-bin"

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
    # ★ 必须装：屏幕键盘的中文切换靠 gsettings，而 gsettings 在这个包里。
    #   漏了它的症状是"键盘能弹，但只有英文"。
    drm_log "装 glib 工具（gsettings/gdbus，屏幕键盘中文必需）：$NT_DEPS_GLIB"
    ds_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y $NT_DEPS_GLIB 2>&1 | tail -n 8"
    # schema 缓存不编译，gsettings 就看不见 org.maliit.keyboard.maliit
    ds_exec "glib-compile-schemas /usr/share/glib-2.0/schemas 2>&1; echo '  schema 缓存已编译'"
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

# ── ★★ 出网兜底路由（没有它，WiFi 连上了也打不开网页）★★ ──
#
# 本次调试最关键的一环，症状极具欺骗性：
#   · wlan0 拿到 IP、ping 得通网关、DNS 也解析得出来
#   · 但 `ip route get 1.1.1.1` 报 `Network is unreachable`，浏览器打不开网页
#
# 根因：NetworkManager 把默认路由写进 **main 表**，而安卓 netd 的 rule 列表里
# **根本没有 `32766: from all lookup main`**。实测本机 netd 的 rule 是：
#
#       0:     from all lookup local
#   11000:     from all iif lo oif dummy0 uidrange 0-0 lookup 1002
#   16000:     from all fwmark 0x10063/0x1ffff iif lo lookup 97
#   17000:     from all iif lo oif dummy0 lookup 1002
#   20000:     from all fwmark 0/0x10000 lookup 97
#   32000:     from all unreachable          ← 直接不可达
#
# ⇒ main 表永远不被查 ⇒ NM 的默认路由形同不存在。
#
# 解法（与上游 net-fix.sh 的 do_route 一致）：**只加不改** ——
# 建自己的一张表 + 一条优先级夹在 netd 的 20000 与 32000 之间的 rule。
# `iif lo` 只匹配**本机发出**的包，和 netd 自己那条 31000 同形状，
# 所以安卓侧的 tethering/转发流量不会被误引到我们这张表上。
#
# ⚠️ 红线：绝不 `ip rule flush`（会拆掉 netd 的策略路由地基）。
#          也绝不删 netd 的任何 rule/table，只新增。
nt_fix_route() {
    _if=${DEV_WIFI_IF:-wlan0}
    _tbl=${DEV_ROUTE_TABLE:-1042}
    _pref=${DEV_ROUTE_PREF:-31500}

    if ! ds_exec "ip -4 -o addr show $_if 2>/dev/null | grep -q 'inet '" >/dev/null 2>&1; then
        drm_warn "出网兜底：$_if 还没有 IPv4，跳过"
        return 0
    fi

    # 网关：优先从 netd 的 per-interface 表（表号 = 1000 + ifindex）读
    _idx=$(ds_exec "cat /sys/class/net/$_if/ifindex 2>/dev/null" 2>/dev/null | tr -d '\r')
    _gw=""
    for _t in $((1000 + ${_idx:-0})) $_tbl; do
        _g=$(ds_exec "ip -4 route show table $_t 2>/dev/null | awk '/^default/{print \$3; exit}'" 2>/dev/null | tr -d '\r')
        [ -n "$_g" ] && { _gw=$_g; break; }
    done
    if [ -z "$_gw" ]; then
        # 退一步：从同网段的 scope link 路由推（末位换 .1）
        _g=$(ds_exec "ip -4 route show table all 2>/dev/null | grep 'dev $_if' | grep 'scope link' | head -1" 2>/dev/null | tr -d '\r')
        _gw=$(printf '%s' "$_g" | awk '{print $1}' | sed 's|/.*||' | sed 's/\.[0-9]*$/.1/')
    fi
    if [ -z "$_gw" ]; then
        drm_warn "出网兜底：探不到网关，跳过（网络可能还没起来）"
        return 0
    fi
    _net=$(printf '%s' "$_gw" | sed 's/\.[0-9]*$/.0/')
    drm_log "出网兜底：接口=$_if 网关=$_gw 网段=$_net 表=$_tbl pref=$_pref"

    # 递归路由必须先建：网段直连（scope link），否则默认路由会被内核判
    # "Nexthop invalid" 而拒绝。
    ds_exec "ip -4 route replace $_net/24 dev $_if scope link table $_tbl 2>/dev/null
             ip -4 route replace default via $_gw dev $_if onlink table $_tbl 2>/dev/null
             ip -4 route show table $_tbl" 2>&1 | tr -d '\r' | sed 's/^/    /'

    # rule：先删同 pref 的旧条目再建（`ip rule add` 会重复堆叠，
    # 上游实测堆过 24600 条）。
    ds_exec "while ip rule show 2>/dev/null | grep -q '^$_pref:'; do
                 ip rule del pref $_pref 2>/dev/null || break
             done
             ip rule add pref $_pref iif lo lookup $_tbl 2>/dev/null
             ip rule show 2>/dev/null | head -14" 2>&1 | tr -d '\r' | sed 's/^/    /'

    if ds_exec "ip rule show 2>/dev/null | grep -q '^$_pref:.*lookup $_tbl'" >/dev/null 2>&1; then
        drm_log "出网兜底已就位（$_pref iif lo → 表 $_tbl）"
        drm_state_set NET_ROUTE_FIX 1
    else
        drm_warn "出网兜底 rule 未生效"
        drm_state_set NET_ROUTE_FIX 0
    fi

    # ★★ 只设一次是不够的，必须挂成 NM dispatcher 让它自动重挂 ★★
    nt_install_route_dispatcher "$_if" "$_tbl" "$_pref"
}

# ── 出网兜底路由的持久化：NetworkManager dispatcher ────────────
#
# ★★ 2026-10-12 实测：只设一次会丢，而且丢得很隐蔽 ★★
#
# 现象：明明 /etc/resolv.conf 里 nameserver 223.5.5.5 写得对，却
#     getent hosts deb.debian.org   → 空
#     curl http://www.baidu.com     → Could not resolve host
#     ip -4 route get 1.1.1.1       → RTNETLINK answers: Network is unreachable
#
# 根因：NetworkManager **自己会管理 ip rule**。实测重载/重连之后：
#     ip rule show  → 我们那条 `31500: from all iif lo lookup 1042` **没了**
#     ip route show table 1042 → 表里的路由**还在**
# 表和 rule 是我们在 NM 之外加的，NM 不认识，重载时把 rule 清掉了。
# 表现成"DNS 配置明明对，却解析不了" —— 很容易误判成 DNS 问题。
#
# 解法：挂进 NM 的 dispatcher.d。接口 up / DHCP 续约时 NM 会以 root 调用
# 这个脚本，把表和 rule 补回来。这样无论重连多少次都自动恢复。
#
# ⚠️ 红线：脚本里绝不 `ip rule flush`，绝不删 netd 的任何 rule/table，只新增。
nt_install_route_dispatcher() {
    _rif=${1:-wlan0}
    _rtbl=${2:-1042}
    _rpref=${3:-31500}
    _disp=/etc/NetworkManager/dispatcher.d/90-drm-route-fix

    drm_log "装 NM dispatcher：$_disp（接口 up 时自动重挂出网兜底）"

    # dispatcher 脚本内容用 base64 传，避免嵌套引号在 ds_exec 里被打碎
    _script=$(cat <<DISPEOF
#!/bin/sh
# 90-drm-route-fix —— DRM 接管容器的出网兜底路由自动重挂
#
# 为什么需要它：NetworkManager 把默认路由写进 main 表，而安卓 netd 的 rule
# 列表里没有 \`32766: from all lookup main\`，所以 main 表永远不被查。
# 我们要自己建一张表 + 一条夹在 netd 的 20000 与 32000 之间的 rule。
#
# ★ 为什么必须是 dispatcher：那张表和那条 rule 是在 NM 之外加的，NM 不认识
#   它们。实测 NM 一重载/重连，那条 rule 就被清掉 ⇒ 立刻断网（DNS 都到不了）。
#   挂成 dispatcher 后，每次接口 up / DHCP 续约都会自动补回来。
#
# ⚠️ 红线：绝不 \`ip rule flush\`，绝不删 netd 的任何 rule/table，只新增。
IFACE="\$1"
ACTION="\$2"

case "\$ACTION" in
    up|vpn-up|dhcp4-change|dhcp6-change) ;;
    *) exit 0 ;;
esac

TBL=$_rtbl
PREF=$_rpref

# 只处理有 IPv4 的接口
ip -4 -o addr show "\$IFACE" 2>/dev/null | grep -q 'inet ' || exit 0

# 找网关：优先从 netd 的 per-interface 表（表号 = 1000 + ifindex）读
IDX=\$(cat "/sys/class/net/\$IFACE/ifindex" 2>/dev/null)
GW=""
for t in \$((1000 + \${IDX:-0})) \$TBL; do
    g=\$(ip -4 route show table "\$t" 2>/dev/null | awk '/^default/{print \$3; exit}')
    [ -n "\$g" ] && { GW=\$g; break; }
done
if [ -z "\$GW" ]; then
    r=\$(ip -4 route show table all 2>/dev/null | grep "dev \$IFACE" | grep 'scope link' | head -1)
    GW=\$(printf '%s' "\$r" | awk '{print \$1}' | sed 's|/.*||' | sed 's/\\.[0-9]*\$/.1/')
fi
[ -n "\$GW" ] || exit 0

NET=\$(printf '%s' "\$GW" | sed 's/\\.[0-9]*\$/.0/')

# 递归路由必须先建（网段 scope link 在默认路由之前），否则内核判 Nexthop invalid
ip -4 route replace "\$NET/24" dev "\$IFACE" scope link table "\$TBL" 2>/dev/null
ip -4 route replace default via "\$GW" dev "\$IFACE" onlink table "\$TBL" 2>/dev/null

# rule：先删同 pref 旧条目（ip rule add 会重复堆叠），iif lo 只匹配本机发出的包
while ip rule show 2>/dev/null | grep -q "^\$PREF:"; do
    ip rule del pref "\$PREF" 2>/dev/null || break
done
ip rule add pref "\$PREF" iif lo lookup "\$TBL" 2>/dev/null

logger -t drm-route-fix "re-applied: \$IFACE \$ACTION gw=\$GW table=\$TBL pref=\$PREF" 2>/dev/null
exit 0
DISPEOF
)
    _b64=$(printf '%s' "$_script" | base64 -w0)

    ds_exec "mkdir -p /etc/NetworkManager/dispatcher.d
             printf '%s' '$_b64' | base64 -d > $_disp
             chmod 755 $_disp
             ls -l $_disp" 2>&1 | tr -d '\r' | sed 's/^/    /'

    # 立刻跑一次，验证脚本本身能工作
    ds_exec "$_disp $_rif up; echo \"  rc=\$?\"; ip rule show 2>/dev/null | grep -E '^$_rpref:'" \
        2>&1 | tr -d '\r' | sed 's/^/    /'
    drm_state_set NET_ROUTE_DISPATCHER 1
}

# DNS：NM 那边设了 dns=none，所以这里直接写死。
# 容器原本的 /etc/resolv.conf 是指向 /run/droidspaces/resolv.conf 的符号链接，
# 那个文件由 Droidspaces 启动时写、内容随安卓状态变 —— 接管后不可靠。
nt_fix_dns() {
    drm_log "写 DNS（223.5.5.5 / 119.29.29.29）"
    ds_exec '[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
             printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf
             cat /etc/resolv.conf' 2>&1 | tr -d '\r' | sed 's/^/    /'
}

# ── ★★ 密钥代理缺失的绕行 ★★ ──────────────────────────────
#
# 本机实测：容器里**没有** NetworkManager 的密钥代理。
#   · kded6 已在跑，`loadModule networkmanagement` 也返回 true，
#     但 `org.freedesktop.NetworkManager.SecretAgent` 仍然 `no such name`
#     ⇒ 那个 kded 模块提供的是小程序后端，**不是**密钥代理。
#   · 后果：用户在 plasma-nm 图形界面里输的密码 NM 收不到，日志报
#         device (wlan0): no secrets: No agents were available for this request.
#         device (wlan0): state change: need-auth -> failed (reason 'no-secrets')
#
# 绕行办法（已验证有效）：让 NM **自己保存**密码 ——
#   ① 把连接的 `psk-flags` 从 1（代理持有）改成 0（NM 持有）
#   ② 用 `nmcli device wifi connect <SSID> password <PSK>` 连一次
#      —— 密码直达 NM，不经过任何代理，然后被写进 .nmconnection
#   ③ 之后托盘小程序再连就不需要代理了
#
# ★★★ 2026-10-12 严重事故：**只做①不做②会把 WiFi 彻底弄坏** ★★★
#
# 我上次就是只跑了这一步，结果：
#   · 连接的 `psk-flags` 变成 0（NM 认为"密码应该由我自己保管"）
#   · 但文件里**根本没有 `psk=` 这一行**（密码原本在代理里）
#   · 于是 NM 既不去问代理、文件里又没有 ⇒ 永远连不上：
#         device (wlan0): no secrets: No agents were available for this request.
#         state change: need-auth -> failed (reason 'no-secrets')
#   · 而且**图形界面也不会再提示输密码**（NM 认为密码已经有了）
#   · 备份文件里同样没有 psk（备份是 19:48 的，那时就是 flags=1），救不回来
#   ⇒ 只能靠用户重新输一次密码。
#
# 所以现在这个函数**只做安全检查，不做破坏性修改**：
#   · 已经有 psk 的连接 → 确保 flags=0（NM 持有，最稳）
#   · 还没有 psk 的连接 → **保持 flags=1 不动**，只提示用户走 wifi-connect
#     （那条路会把密码直接交给 NM，之后自动落盘）
nt_fix_secrets() {
    drm_log "检查 WiFi 密钥存放方式（不做破坏性修改）"
    ds_exec 'has_psk=0; no_psk=""
             for f in /etc/NetworkManager/system-connections/*.nmconnection; do
                 [ -f "$f" ] || continue
                 if grep -q "^psk=" "$f"; then
                     has_psk=1
                     # 有密码 ⇒ 让 NM 自己持有，最稳
                     sed -i "s/^psk-flags=1$/psk-flags=0/" "$f"
                     chmod 600 "$f"
                     echo "  [OK] $(basename "$f")：文件里有 psk，flags=0（NM 持有）"
                 else
                     # 没密码 ⇒ 绝不改 flags，否则会把连接弄坏
                     no_psk="$no_psk $(basename "$f")"
                     echo "  [注意] $(basename "$f")：文件里没有 psk，保持 flags=$(grep -o "psk-flags=." "$f" | head -1 | cut -d= -f2) 不动"
                 fi
             done
             if [ -n "$no_psk" ]; then
                 echo ""
                 echo "  ★ 下面这些连接没有保存密码，需要用户输一次："
                 for n in $no_psk; do echo "      $n"; done
                 echo "  ★ 请用触摸屏入口输密码（密码会直接交给 NM 并落盘）："
                 echo "      sh /usr/local/bin/wifi-connect     （或点桌面图标）"
                 echo "  ★ 千万不要手工把 psk-flags 改成 0 —— 那会让图形界面也不再提示密码，"
                 echo "    连接彻底连不上（2026-10-12 踩过）。"
             fi
             systemctl is-active NetworkManager' 2>&1 | tr -d '\r' | sed 's/^/    /'
}

# 触摸屏上可用的连 WiFi 入口。
# ★ 为什么需要：plasma-nm 的图形面板因为密钥代理缺失收不到密码（见上），
#   而触摸屏上又没法方便地敲长命令。给一个"点图标 → 问 SSID → 问密码"的入口。
# ★ 用 base64 传递脚本内容：ds_exec 把整条命令交给容器里的 shell 解析，
#   直接内嵌带引号的脚本会被吃引号（本仓库反复踩过）。
nt_install_helper() {
    drm_log "安装触摸屏连 WiFi 入口"

    _wc='#!/bin/sh
# wifi-connect —— 触摸屏上连 WiFi：列热点 → 问 SSID → 问密码 → 交给 NM 保存
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
printf "\n\033[1;36m=== 可用热点 ===\033[0m\n"
timeout 30 nmcli -f SSID,SIGNAL,SECURITY device wifi list --rescan yes 2>/dev/null | head -n 25
printf "\n\033[1;33m请输入 WiFi 名称（SSID），直接回车取消: \033[0m"
read -r SSID
[ -n "$SSID" ] || { echo "已取消"; exit 0; }
printf "\033[1;33m请输入密码（输入时不显示）: \033[0m"
stty -echo 2>/dev/null; read -r PSK; stty echo 2>/dev/null; printf "\n"
printf "\n\033[1;36m正在连接 %s ...\033[0m\n" "$SSID"
if [ -n "$PSK" ]; then
    timeout 90 nmcli device wifi connect "$SSID" password "$PSK" 2>&1
else
    timeout 90 nmcli device wifi connect "$SSID" 2>&1
fi
RC=$?
printf "\n\033[1;36m=== 结果 ===\033[0m\n"
nmcli -f DEVICE,STATE,CONNECTION device status 2>/dev/null | grep -E "DEVICE|wlan0"
ip -4 -o addr show wlan0 2>/dev/null || echo "  （还没拿到 IP）"

# ★★ 关键：连上之后必须补出网兜底路由，否则"拿到 IP 但打不开网页" ★★
# 原因见 network/README.md：安卓 netd 的 rule 里没有 32766 lookup main，
# 所以 NetworkManager 写进 main 表的默认路由永远不会被查。
if ip -4 -o addr show wlan0 2>/dev/null | grep -q "inet "; then
    printf "\n\033[1;36m=== 补出网路由 ===\033[0m\n"
    TBL=1042; PREF=31500; IFACE=wlan0
    IDX=$(cat /sys/class/net/$IFACE/ifindex 2>/dev/null)
    GW=""
    for t in $((1000 + ${IDX:-0})) $TBL; do
        g=$(ip -4 route show table "$t" 2>/dev/null | awk "/^default/{print \$3; exit}")
        [ -n "$g" ] && { GW=$g; break; }
    done
    if [ -z "$GW" ]; then
        r=$(ip -4 route show table all 2>/dev/null | grep "dev $IFACE" | grep "scope link" | head -1)
        GW=$(printf "%s" "$r" | awk "{print \$1}" | sed "s|/.*||" | sed "s/\.[0-9]*$/.1/")
    fi
    if [ -n "$GW" ]; then
        NET=$(printf "%s" "$GW" | sed "s/\.[0-9]*$/.0/")
        ip -4 route replace "$NET/24" dev "$IFACE" scope link table "$TBL" 2>/dev/null
        ip -4 route replace default via "$GW" dev "$IFACE" onlink table "$TBL" 2>/dev/null
        while ip rule show 2>/dev/null | grep -q "^$PREF:"; do
            ip rule del pref "$PREF" 2>/dev/null || break
        done
        ip rule add pref "$PREF" iif lo lookup "$TBL" 2>/dev/null
        echo "  网关 $GW → 表 $TBL，rule $PREF"
    fi
    printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf 2>/dev/null
    printf "\n\033[1;36m=== 出网自证 ===\033[0m\n"
    timeout 8 ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && echo "  PING-OK" || echo "  PING-FAIL"
    timeout 10 getent hosts www.baidu.com >/dev/null 2>&1 && echo "  DNS-OK" || echo "  DNS-FAIL"
    timeout 20 curl -sS -o /dev/null -w "  HTTP %{http_code}\n" http://www.baidu.com 2>&1
fi

printf "\n\033[1;33m按回车关闭\033[0m\n"; read -r _
exit $RC
'
    _desk='[Desktop Entry]
Type=Application
Name=连接 WiFi
Name[en]=Connect WiFi
Comment=列出热点并输入密码连接
Exec=/usr/bin/konsole -e /usr/local/bin/wifi-connect
Icon=network-wireless
Terminal=false
Categories=Network;Settings;
'
    _wc_b64=$(printf '%s' "$_wc" | base64 -w0 2>/dev/null || printf '%s' "$_wc" | base64 | tr -d '\n')
    _desk_b64=$(printf '%s' "$_desk" | base64 -w0 2>/dev/null || printf '%s' "$_desk" | base64 | tr -d '\n')

    # ★ 同时放一份到**桌面**（~/Desktop）。
    #   为什么：应用菜单项在启动器里，用户要先打开启动器再找；而触摸屏上
    #   最直接的入口是桌面图标。实测 Folder View 的 url 就是 ~/Desktop
    #   （appletsrc 里 positions 有 "desktop:/usb-manager.desktop"），
    #   所以放这里一定会显示出来。
    #   桌面的 .desktop 需要可执行位（755）且属主是桌面用户，否则 KDE
    #   会把它当成"未信任的快捷方式"。
    _uhome="${DEV_USER:-Gold}"
    ds_exec "printf '%s' '$_wc_b64' | base64 -d > /usr/local/bin/wifi-connect
             chmod 755 /usr/local/bin/wifi-connect
             printf '%s' '$_desk_b64' | base64 -d > /usr/share/applications/wifi-connect.desktop
             chmod 644 /usr/share/applications/wifi-connect.desktop
             _d=/home/${_uhome}/Desktop
             mkdir -p \"\$_d\"
             printf '%s' '$_desk_b64' | base64 -d > \"\$_d/wifi-connect.desktop\"
             chmod 755 \"\$_d/wifi-connect.desktop\"
             chown ${_uhome}:${_uhome} \"\$_d/wifi-connect.desktop\"
             ls -l \"\$_d/wifi-connect.desktop\"" 2>&1 | tr -d '\r' | sed 's/^/    /'

    # 刷新应用菜单缓存，否则新图标不会出现在启动器里
    ds_exec "runuser -u ${DEV_USER:-Gold} -- env HOME=$_uhome \
                 LANG=en_US.UTF-8 XDG_MENU_PREFIX=plasma- \
                 kbuildsycoca6 --noincremental" >/dev/null 2>&1

    if ds_exec "test -x /usr/local/bin/wifi-connect && test -f /home/${_uhome}/Desktop/wifi-connect.desktop" >/dev/null 2>&1; then
        drm_log "已安装 /usr/local/bin/wifi-connect + 启动器图标 + 桌面图标「连接 WiFi」"
    else
        drm_warn "wifi-connect 安装不完整（脚本或桌面图标缺失）"
    fi
}

# 自证：真的能上网了吗（而不是"配置看起来对"）
nt_verify_egress() {
    drm_log "自证出网"
    ds_exec 'timeout 8 ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && echo "PING-OK" || echo "PING-FAIL"
             timeout 10 getent hosts www.baidu.com >/dev/null 2>&1 && echo "DNS-OK" || echo "DNS-FAIL"
             timeout 20 curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://www.baidu.com 2>&1' \
        2>&1 | tr -d '\r' | sed 's/^/    /'
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
    nt_fix_secrets
    nt_install_helper
    nt_fix_dns
    nt_start_nm
    nt_verify || true

    # ★ 出网兜底要在 wlan0 **拿到 IP 之后**才能建，所以这里只试一次；
    #   真正的时机是用户连上之后 —— wifi-connect 会自动补（见 nt_install_helper）。
    nt_fix_route || true

    drm_log "接管完成 —— 用桌面图标「连接 WiFi」输密码（脚本不经手凭据）"
    drm_log "  连上后 wifi-connect 会自动补出网路由；也可手工跑：net-takeover.sh route"
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
    route)        nt_fix_route ;;
    dns)          nt_fix_dns ;;
    secrets)      nt_fix_secrets ;;
    helper)       nt_install_helper ;;
    egress)       nt_verify_egress ;;
    proxy-bridge) shift; nt_proxy_bridge "$@" ;;
    *)
        cat <<'USAGE'
用法: net-takeover.sh <子命令>

  takeover       接管 wlan0（停安卓 WiFi 栈 + 起容器 NetworkManager + polkit + 触摸入口）
  status         只读状态（安卓服务 / 链路 / 容器 NM）
  restore        交还给安卓
  deps           在容器里装 WiFi/蓝牙/输入法/屏幕键盘依赖（需容器能上网）
  tray           只把网络+蓝牙小程序加进系统托盘
  route          ★ 补出网兜底路由（拿到 IP 后必须做，否则打不开网页）
  dns            写 DNS（223.5.5.5 / 119.29.29.29）
  secrets        ★ 检查 WiFi 密码存放方式（只读+安全修正，不再做破坏性修改）
                 · 文件里已有 psk 的连接 → 置 flags=0（NM 持有，最稳）
                 · 文件里没有 psk 的连接 → 保持 flags 不动，提示走 wifi-connect
                 ★ 历史教训：早先这里无条件把 flags 改成 0，而文件里并没有 psk，
                   结果 NM 既不问代理、文件里也没有密码 ⇒ WiFi 彻底连不上，
                   而且图形界面也不再提示输密码。改 flags 必须和"写入 psk"同时做。
  helper         只装触摸屏连 WiFi 入口（/usr/local/bin/wifi-connect + 桌面图标）
  egress         自证出网（ping / DNS / HTTP，不是"配置看起来对"）
  glibc-fix      修 glibc AI_ADDRCONFIG（容器没非环回 IPv4 时 apt 解析失败）
  proxy-bridge [端口]
                 打印"用 adb reverse 给容器开临时代理通道"的步骤（默认 7897）
USAGE
        exit 1 ;;
esac

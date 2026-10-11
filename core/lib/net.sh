#!/bin/sh
# core/lib/net.sh — 容器侧网络接管（尽力而为，绝不影响已上屏的桌面）。
#
# 【为什么需要】
#   容器与安卓共享 netns（net_mode=host）。出网全靠安卓 netd 维护的
#   per-interface 路由表 + fwmark 规则。一旦安卓侧网络栈退场，
#   没人维护那些表，一路落到 `32000: from all unreachable`。
#   现象很有欺骗性：**有 IP、ping 得通网关、外网 unreachable**。
#
# 【兜底原理】
#   加一张自己的表 + 一条优先级夹在 netd 的 31000 与 32000 之间的 rule。
#   只加不改，安卓回来时把 rule 删掉即可，不动它的表。
#
# ══ 红线 ══
#   绝不 `ip link set $DEV_WIFI_IF up`。
#   参考仓库实测两次事故：down 之后的任何一次 up 都会触发
#   `cnss: Failed to start MHI err=-110` → `Recovery is already in progress
#   → ASSERT 2436` → adbd 陪葬 ⇒ system_server 起不全 ⇒ 黑屏强启。
#   down 同理，能不做就不做。
#
# ══ 红线 ══
#   绝不让 WiFi 失败连坐桌面。网络段是纯尽力而为：关联/出口失败只打警告，
#   已上屏的桌面保持不动。

NET_WPA_PIDFILE=/run/desk-wpa.pid
NET_WPA_CTRL=/run/wpa-takeover
NET_DYN_CONF=/run/desk-wifi-dyn.conf

# 从安卓读当前 SSID（不需要 root）
net_android_current_ssid() {
    android_query "cmd wifi status 2>/dev/null" 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's/.*connected to "\([^"]*\)".*/\1/p' \
        | head -1
}

# 从安卓读当前 PSK。
# ★ 这里必须静音：重构前 desk-takeover.sh 开着 `set -x`，
#   `printf '%s' "$CUR_PSK"` 把 WiFi 密码明文写进了日志。
net_android_current_psk() {
    _ssid=$1
    [ -n "$_ssid" ] || return 1
    android_exec "grep -A2 'SSID=\"$_ssid\"' /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml 2>/dev/null | sed -n 's/.*PreSharedKey=\"\\([^\"]*\\)\".*/\\1/p' | head -1" 2>/dev/null \
        | tr -d '\r' | head -1
}

# 生成 wpa_supplicant 配置。★ 全程 set +x，且不回显内容。
net_gen_wpa_conf() {
    _ssid=$1
    _psk=$2
    _out=$3

    ( set +x
      umask 077
      {
          printf 'ctrl_interface=%s\n' "$NET_WPA_CTRL"
          printf 'update_config=0\n'
          printf 'ap_scan=1\n'
          printf 'pmf=1\n'
          printf 'sae_pwe=2\n'
      } >"$_out"
      if command -v wpa_passphrase >/dev/null 2>&1; then
          printf '%s' "$_psk" | wpa_passphrase "$_ssid" >>"$_out" 2>/dev/null
      else
          # 没有 wpa_passphrase 时退化为明文 psk（wpa_supplicant 接受）
          printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$_ssid" "$_psk" >>"$_out"
      fi
    )
    chmod 600 "$_out" 2>/dev/null
    # 只回报"生成成功"，绝不回报内容
    [ -s "$_out" ] && drm_log "已生成 wpa 配置（SSID 长度 ${#_ssid}，凭据不回显）"
}

net_start_supplicant() {
    _conf=$1
    _wpa=$(for c in /usr/sbin/wpa_supplicant /sbin/wpa_supplicant; do
               [ -x "$c" ] && { printf '%s\n' "$c"; break; }
           done)
    [ -n "$_wpa" ] || { drm_warn "没有 wpa_supplicant，跳过 WiFi 接管"; return 1; }

    # 用 pid 文件精确停，不用 pkill -f（会误杀调用方 shell）
    if [ -f "$NET_WPA_PIDFILE" ]; then
        _op=$(cat "$NET_WPA_PIDFILE" 2>/dev/null)
        [ -n "$_op" ] && kill -TERM "$_op" 2>/dev/null
        sleep 1
        [ -n "$_op" ] && kill -9 "$_op" 2>/dev/null
        rm -f "$NET_WPA_PIDFILE"
    fi
    pkill -9 -x dhcpcd 2>/dev/null

    mkdir -p "$NET_WPA_CTRL" 2>/dev/null
    "$_wpa" -i "$DEV_WIFI_IF" -c "$_conf" -P "$NET_WPA_PIDFILE" \
        >>"${DRM_LOG_DIR}/wpa.log" 2>&1 &

    # 等关联完成
    _i=0
    while [ "$_i" -lt 30 ]; do
        if wpa_cli -p "$NET_WPA_CTRL" -i "$DEV_WIFI_IF" status 2>/dev/null \
            | grep -q 'wpa_state=COMPLETED'; then
            drm_log "WiFi 关联成功"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    drm_warn "WiFi 关联 30s 未完成（继续，桌面不受影响）"
    return 1
}

net_start_dhcp() {
    command -v dhcpcd >/dev/null 2>&1 || { drm_warn "没有 dhcpcd"; return 1; }
    dhcpcd -k "$DEV_WIFI_IF" 2>/dev/null
    pkill -9 -x dhcpcd 2>/dev/null
    dhcpcd -4 -w -t 20 "$DEV_WIFI_IF" >>"${DRM_LOG_DIR}/dhcpcd.log" 2>&1
    _i=0
    while [ "$_i" -lt 10 ]; do
        _ip=$(ip -4 -o addr show dev "$DEV_WIFI_IF" 2>/dev/null | awk '{print $4}' | head -1)
        [ -n "$_ip" ] && { drm_log "拿到租约 $_ip"; return 0; }
        sleep 1
        _i=$((_i + 1))
    done
    drm_warn "dhcpcd 10s 未拿到租约"
    return 1
}

# 动态探测网关/网段（换网不用改配置）
net_discover_gw() {
    _ip=$(ip -4 -o addr show dev "$DEV_WIFI_IF" 2>/dev/null | awk '{print $4}' | head -1)
    [ -n "$_ip" ] || return 1
    _addr=${_ip%/*}
    _pfx=${_ip#*/}
    NET_ADDR=$_addr
    NET_PREFIX=$_pfx

    _gw=$(ip -4 route show dev "$DEV_WIFI_IF" 2>/dev/null | awk '/^default/{print $3; exit}')
    if [ -z "$_gw" ]; then
        # 退化为 /24 推 .1
        _gw=$(printf '%s\n' "$_addr" | awk -F. '{printf "%s.%s.%s.1\n", $1, $2, $3}')
    fi
    NET_GW=$_gw
    # 网段
    if [ "$_pfx" = 24 ]; then
        NET_CIDR=$(printf '%s\n' "$_addr" | awk -F. '{printf "%s.%s.%s.0/24\n", $1, $2, $3}')
    else
        NET_CIDR="$_addr/$_pfx"
    fi
    drm_log "探测到 addr=$NET_ADDR/$NET_PREFIX gw=$NET_GW cidr=$NET_CIDR"
    return 0
}

# 兜底路由表 + rule（只加不改）
net_install_fallback_route() {
    _tbl=${DEV_ROUTE_TABLE:-1042}
    _pref=${DEV_ROUTE_PREF:-31500}

    [ -n "${NET_GW:-}" ] || return 1

    ip -4 route replace "$NET_CIDR" dev "$DEV_WIFI_IF" scope link table "$_tbl" 2>/dev/null
    ip -4 route replace default via "$NET_GW" dev "$DEV_WIFI_IF" onlink table "$_tbl" 2>/dev/null

    while ip rule show 2>/dev/null | grep -q "^$_pref:"; do
        ip rule del pref "$_pref" 2>/dev/null
    done
    ip rule add pref "$_pref" iif lo lookup "$_tbl" 2>/dev/null
    drm_log "兜底路由就绪（table $_tbl / rule pref $_pref）"
    drm_state_set NET_FALLBACK 1
}

net_dns() {
    rm -f /etc/resolv.conf 2>/dev/null
    printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' >/etc/resolv.conf 2>/dev/null
}

net_check_egress() {
    _i=0
    while [ "$_i" -lt 5 ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            drm_log "NET-TAKEOVER OK"
            drm_state_set NET_OK 1
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    drm_warn "NET-EGRESS-FAIL：桌面保持不动，仅网络不可用"
    ip -4 route show table all 2>/dev/null | head -n 20 >&2
    drm_state_set NET_OK 0
    return 1
}

# ── 总入口：尽力而为，永不 die ────────────────────────────
net_takeover_wifi() {
    drm_phase "net"
    if [ "${DRM_NET:-1}" != 1 ]; then
        drm_log "DRM_NET=0，跳过网络接管"
        return 0
    fi

    _ssid=${DRM_WIFI_SSID:-}
    _psk=${DRM_WIFI_PSK:-}

    if [ -z "$_ssid" ]; then
        _ssid=$(net_android_current_ssid 2>/dev/null || true)
        drm_log "从安卓读到 SSID：${_ssid:-（空）}"
    fi
    if [ -n "$_ssid" ] && [ -z "$_psk" ]; then
        _psk=$(net_android_current_psk "$_ssid" 2>/dev/null || true)
    fi

    if [ -z "$_ssid" ] || [ -z "$_psk" ]; then
        # 也支持预置配置文件（永不入库）
        if [ -r /root/desk-wifi.conf ]; then
            drm_log "用预置 /root/desk-wifi.conf"
            net_start_supplicant /root/desk-wifi.conf || return 0
        else
            drm_warn "读不到安卓 WiFi 凭据，也没有预置配置 —— 只起桌面，不动网络"
            return 0
        fi
    else
        net_gen_wpa_conf "$_ssid" "$_psk" "$NET_DYN_CONF" || return 0
        net_start_supplicant "$NET_DYN_CONF" || { rm -f "$NET_DYN_CONF"; return 0; }
    fi

    net_start_dhcp || true
    net_discover_gw || true
    net_install_fallback_route || true
    net_dns
    net_check_egress || true
    return 0
}

# ── 交还 ──────────────────────────────────────────────────
# 注意：这里**不** `ip link set down`（红线）。回安卓要重启设备，
# 网络栈会跟着重启，不需要我们碰链路状态。
net_release() {
    drm_log "交还网络（不碰链路状态）"
    if [ -f "$NET_WPA_PIDFILE" ]; then
        _op=$(cat "$NET_WPA_PIDFILE" 2>/dev/null)
        [ -n "$_op" ] && kill -9 "$_op" 2>/dev/null
        rm -f "$NET_WPA_PIDFILE"
    fi
    pkill -9 -x dhcpcd 2>/dev/null
    rm -f "$NET_DYN_CONF" 2>/dev/null
    _tbl=${DEV_ROUTE_TABLE:-1042}
    _pref=${DEV_ROUTE_PREF:-31500}
    while ip rule show 2>/dev/null | grep -q "^$_pref:"; do
        ip rule del pref "$_pref" 2>/dev/null
    done
    ip -4 route flush table "$_tbl" 2>/dev/null
    return 0
}

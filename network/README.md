# 网络接管（WiFi / 蓝牙）

本目录把"让容器自己拥有 wlan0，用 plasma-nm 图形面板连 WiFi"这条流程固化下来。

主脚本：`net-takeover.sh`

```sh
sh network/net-takeover.sh status       # 只读看状态
sh network/net-takeover.sh deps         # 在容器里装依赖（需容器能上网）
sh network/net-takeover.sh takeover     # 接管
sh network/net-takeover.sh restore      # 交还
```

---

## 1. 为什么 `net_mode=host` 还不够

容器与安卓共享 netns（`net_mode=host`），但**共享 netns ≠ 容器能上网**：

- 安卓 netd 的路由是 **per-UID + fwmark** 的。容器的 UID 不在任何一张表里，
  于是它看到的是 `32000: from all unreachable` —— 表现极具欺骗性：
  **有 IP、ping 得通网关、外网不通**。
- 接管显示要先停 SurfaceFlinger，`system_server` 在这种状态下会反复崩溃重启
  （实测 `camx.provider-impl.so CameraProvider::binderDied → abort`）。
  它一重启，`WifiService` 就注册不上 ⇒

  ```
  cmd wifi status        → Can't find service: wifi
  dumpsys wifi           → Can't find service: wifi
  ```

  ⇒ **安卓自己的"设置"里也连不了 WiFi**，不是容器的问题。

所以正确做法是上游那条路：**让容器接管 wlan0**。

---

## 2. 与上游 `net-takeover.sh` 的差异（照抄会挂）

| # | 上游做法 | 本机必须改成 | 为什么 |
|---|---|---|---|
| 1 | `droidspaces -C <config> start/stop` | `droidspaces --name=DEBIAN run '<整条命令>'` | 本机是 v6.6.0，旧 CLI 不存在 |
| 2 | 停 `oplus_wifi_aidl_service` | 停 `wpa_supplicant` / `wificond` / `vendor.wifi_hal_legacy` | 本机实测没有 `oplus_wifi_aidl_service` |
| 3 | — | **必须保留 `cnss-daemon`** | 它是 CNSS 驱动守护，停掉射频彻底起不来 |
| 4 | `:82-87` 改 `container.config` 并**重启容器** | **只读检查 net_mode，绝不改、绝不重启** | 容器重启会破坏安卓 ueventd netlink，热插拔节点全建不出，**只有整机 reboot 能恢复** |
| 5 | 容器侧 `wpa_supplicant` + `dhcpcd` | 容器侧 **NetworkManager** | 要的是 plasma-nm 图形面板 |
| 6 | `:147/:162` `ip link set wlan0 up` | **一处都不碰链路状态** | 见下面红线 |
| 7 | 20 秒看门狗定时器 | **不要** | 上游自己在 tether 模式实测 3 小时 flap 57 次 |

---

## 3. 红线（上游血泪 + 本机事故）

| 禁止 | 后果 |
|---|---|
| `ip link set wlan0 up/down` | `cnss: Failed to start MHI err=-110` → `Recovery is already in progress → ASSERT 2436` → **黑屏强关**（本机实测两次） |
| `ip rule flush` | 拆掉安卓 netd 策略路由的地基，整机网络崩 |
| 用 `ip route show default` 当健康检查 | netd 移除了 `32766 lookup main`，它**永远**是空的 |
| 改 `net_mode` 离开 `host` | 容器看不到 wlan0 |
| 写 `persist.*` / `settings` | 会跨重启污染安卓 |

本脚本全程只用 `setprop ctl.stop/start`（纯运行时）⇒ **设备重启后安卓 WiFi 自动回来，不需要任何清理**。

---

## 4. 一个非显然的坑：glibc `AI_ADDRCONFIG`

容器里只剩 `lo` 的 `127.0.0.1` 时，glibc 的 `AI_ADDRCONFIG` 会认为
"本机没配 IPv4"，于是**连纯数字地址都拒绝解析**：

```
apt: Something wicked happened resolving '127.0.0.1:7897'
     (-9 - Address family for hostname not supported)
apt: Could not resolve '127.0.0.1'
```

而 `getent hosts 127.0.0.1` 和 `curl -x` 都正常 —— 极难定位。

```sh
sh network/net-takeover.sh glibc-fix
# 等价于：
#   ip link add drmdummy0 type dummy
#   ip link set drmdummy0 up
#   ip addr replace 10.77.0.1/32 dev drmdummy0
```

不加路由、不碰 wlan0，纯粹为了让 glibc 相信"本机有 IPv4"。

---

## 5. 容器没网时怎么装包（鸡生蛋问题）

容器没网 ⇒ 装不了 NetworkManager ⇒ 修不好网络，是死循环。
若 PC 上有代理，用 `adb reverse` 开一条临时通道：

```sh
# ① PC 侧（必须在 PC 上执行）
adb reverse tcp:7897 tcp:7897

# ② 容器侧
sh network/net-takeover.sh glibc-fix
printf 'Acquire::http::Proxy "http://127.0.0.1:7897";\nAcquire::https::Proxy "http://127.0.0.1:7897";\n' \
    > /etc/apt/apt.conf.d/95proxy
apt-get update && sh network/net-takeover.sh deps

# ③ 装完撤掉（这是临时桥，不要长期依赖）
adb reverse --remove-all
rm -f /etc/apt/apt.conf.d/95proxy
```

---

## 6. polkit：容器里没有 logind 会话

容器里没有 logind 的 active 会话，polkit 的 `allow_active` **不生效**，
于是 plasma-nm 点击连接会被拒（`Not authorized to control networking`）。

上游 `desk-takeover.sh:624-642` 的做法是按**用户名**显式放行，
并显式**拒绝**三个动作，防止用户把总开关一关、射频进 soft-block 半连接态：

```
org.freedesktop.NetworkManager.enable-disable-wifi
org.freedesktop.NetworkManager.enable-disable-network
org.freedesktop.NetworkManager.sleep-wake
```

规则由 `net-takeover.sh takeover` 写到
`/etc/polkit-1/rules.d/60-nm-drm.rules`。

---

## 7. 蓝牙：另一条路，不在本脚本里

蓝牙**不走** WiFi 那条 HAL 路。上游用 `bt-bridge-up.sh`：

1. 安卓侧 `bthci-bridge` 持有 binder `android.hardware.bluetooth.IBluetoothHci/default`
2. 它开一个带 `n_hci` line discipline 的 pty ⇒ 容器里出现 `hci0`
3. 容器里跑 `bluetoothd`

需要两个设备节点：`/dev/uhid` (10:239) 和 `/dev/rfkill` (10:242)。

⚠️ `bluetooth.service` 带 `ConditionPathIsDirectory=/sys/class/bluetooth`，
**必须在 `hci0` 出现之后手工 `systemctl start bluetooth`**，否则它会静默跳过。

`net-takeover.sh` 目前只做 `/dev/rfkill` + 清蓝牙 soft-block，
HCI 桥（`bthci-bridge`）**尚未移植**。

---

## 8. ★★ 最容易漏的一步：出网兜底路由 ★★

**症状极具欺骗性 —— WiFi 连上了、拿到 IP 了，但浏览器打不开任何网页。**

实测现场：

```
wlan0    inet 192.168.31.23/24              ← 有 IP
ping 192.168.31.1   → 0% 丢包               ← 通网关
getent hosts www.baidu.com → 解析成功       ← DNS 也正常
ip route get 1.1.1.1 → RTNETLINK answers: Network is unreachable   ← 但出不去
```

**根因**：NetworkManager 把默认路由写进 **main 表**，而安卓 netd 的 rule
列表里**根本没有 `32766: from all lookup main`**：

```
netd 的 rule（实测本机）：
    0:     from all lookup local
    11000: from all iif lo oif dummy0 uidrange 0-0 lookup 1002
    16000: from all fwmark 0x10063/0x1ffff iif lo lookup 97
    17000: from all iif lo oif dummy0 lookup 1002
    20000: from all fwmark 0/0x10000 lookup 97
    32000: from all unreachable          ← 没有任何 lookup main
```

⇒ **main 表永远不被查，NM 的默认路由形同不存在。**

**解法**（与上游 `net-fix.sh` 的 `do_route` 一致，**只加不改**）：

```sh
TBL=1042; PREF=31500; IFACE=wlan0
ip -4 route replace $NET/24 dev $IFACE scope link table $TBL
ip -4 route replace default via $GW dev $IFACE onlink table $TBL
ip rule add pref $PREF iif lo lookup $TBL
```

```
结果：
  表 1042:  default via 192.168.31.1 dev wlan0 onlink
            192.168.31.0/24 dev wlan0 scope link
  rule:     31500: from all iif lo lookup 1042      ← 夹在 20000 与 32000 之间
```

**三个要点**：

1. **递归路由必须先建** —— 网段直连（`scope link`）要在默认路由之前，
   否则内核判 `Nexthop invalid` 直接拒绝。
2. **`iif lo` 不能省** —— 它只匹配**本机发出**的包，和 netd 自己那条 31000
   同形状，所以安卓侧的 tethering/转发流量不会被误引到我们这张表上。
3. **`ip rule add` 会重复堆叠** —— 必须先 `while ... grep -q "^$PREF:"; do
   ip rule del pref $PREF; done`。上游实测堆过 24600 条。

⚠️ 红线：**绝不 `ip rule flush`**（会拆掉 netd 的策略路由地基）；
也绝不删 netd 的任何 rule/table，只新增。

**执行时机**：必须在 wlan0 **拿到 IP 之后**，所以它不在 `takeover` 里完成，
而是由 `wifi-connect` 在连上之后自动补。也可手工跑：

```sh
sh network/net-takeover.sh route
sh network/net-takeover.sh egress     # 自证：ping / DNS / HTTP
```

修好后的自证结果：

```
HTTP  200   0.064s  -> http://www.baidu.com/
HTTPS 200   0.103s
```

### 8.1 ★★ 只设一次会丢：必须挂成 NM dispatcher ★★

**后补的实测（2026-10-12）**：按上面的步骤设好之后，网是通的。但过了一会儿又断了，
而且**断得很隐蔽**：

```
$ cat /etc/resolv.conf
nameserver 223.5.5.5          ← 配置明明是对的
nameserver 119.29.29.29

$ getent hosts deb.debian.org
（空）

$ curl http://www.baidu.com
curl: (6) Could not resolve host

$ ip -4 route get 1.1.1.1
RTNETLINK answers: Network is unreachable      ← ★ 真正的问题在这
```

**很容易误判成 DNS 问题** —— 因为配置确实是对的。实际是路由没了。

**根因：NetworkManager 自己会管理 `ip rule`。** 实测重载/重连之后：

```
$ ip rule show | grep 31500
（空）                                   ← ★ 我们那条 rule 被删了

$ ip route show table 1042
default via 192.168.31.1 dev wlan0 onlink      ← 表里的路由还在
192.168.31.0/24 dev wlan0 scope link
```

**表还在，rule 没了。** 表和 rule 都是我们在 NM 之外加的，NM 不认识它们，
重载时把 rule 清掉了。

**解法**：挂进 `/etc/NetworkManager/dispatcher.d/`。接口 up / DHCP 续约时
NM 会以 root 调用这个脚本，把表和 rule 补回来：

```sh
sh network/net-takeover.sh route      # 现在会顺带装 dispatcher
# 装出 /etc/NetworkManager/dispatcher.d/90-drm-route-fix
```

验证它真的被调用（journal 里能看到我们打的 logger 行）：

```
Oct 12 20:24:26 DEBIAN drm-route-fix[5447]: re-applied: wlan0 up gw=192.168.31.1 table=1042 pref=31500
```

**教训**：在 NM 之外手工加的 rule，一定要挂 dispatcher 保活。
这跟 §8 开头那条「`ip rule add` 会重复堆叠」是同一个机制的两面 ——
**NM 会动 rule，所以我们既不能假设它留着，也不能假设它只被加一次**。

---

## 9. ★★ 密钥代理缺失：图形界面输的密码 NM 收不到 ★★

**症状**：在 plasma-nm 图形面板里输入了密码、点了连接，但连不上。

**日志里的决定性一行**：

```
device (wlan0): Activation: (wifi) access point 'ImmortalWrt' has security, but secrets are required.
device (wlan0): state change: config -> need-auth (reason 'none')
device (wlan0): no secrets: No agents were available for this request.    ← ★
device (wlan0): state change: need-auth -> failed (reason 'no-secrets')
```

**根因**：容器里**没有** NetworkManager 的密钥代理（secret agent）。

排查过程（都排除掉了）：

| 检查 | 结果 |
|---|---|
| `kded6` 在跑吗 | ✓ 在跑（但本仓库从来没人起过它，是本次新加的） |
| kded 有 `networkmanagement.so` 吗 | ✓ 有 |
| 强制 `loadModule networkmanagement` | ✓ 返回 `boolean true` |
| `org.freedesktop.NetworkManager.SecretAgent` | ✗ **no such name** |
| 全盘找 `plasmanm_secretagent` | ✗ 不存在 |
| `plasma-nm` 包里带的可执行 | ✗ 只有 plasmoid，没有代理二进制 |

⇒ **kded 的 `networkmanagement` 模块提供的是小程序后端，不是密钥代理。**
Plasma 6 里那个代理不在 kded 里。

**绕行办法（已验证有效）—— 让 NM 自己保存密码**：

1. 把连接的 `psk-flags` 从 `1`（代理持有）改成 `0`（NM 持有）：

   ```sh
   sh network/net-takeover.sh secrets
   ```

2. 用 `nmcli` 连一次 —— 密码**直达 NM，不经过任何代理**，然后被写进
   `.nmconnection`：

   ```sh
   nmcli device wifi connect "ImmortalWrt" password "<密码>"
   ```

3. 之后托盘小程序再连就**不需要代理**了（NM 自己手里有密码）。

为了让触摸屏上也能方便地做第 2 步，脚本会装一个入口：

```sh
sh network/net-takeover.sh helper
# 装出：
#   /usr/local/bin/wifi-connect                    （列热点→问 SSID→问密码→连接→补路由→自证）
#   /usr/share/applications/wifi-connect.desktop   （应用菜单里的「连接 WiFi」图标）
```

`wifi-connect` 会顺带把**第 8 节的出网路由**也补上，所以用户只需要点一次图标。

---

## 10. 实测状态（2026-10-12）

容器内已验证可用：

```
NetworkManager 1.52.1      active
wpasupplicant  2:2.10-24
iw             6.9-1+b1
rfkill         2.41.5
plasma-nm      4:6.3.4-2   /usr/share/plasma/plasmoids/org.kde.plasma.networkmanagement
bluez          5.82-1.1
bluedevil      4:6.3.4-2
```

```
nmcli device status      → wlan0  disconnected（归 NM 管）
nmcli radio              → WIFI-HW enabled
nmcli device wifi list   → 扫到 20 个热点（含 ImmortalWrt ch48 89-94% WPA2）
```

安卓侧：

```
wpa_supplicant            stopped
wificond                  stopped
vendor.wifi_hal_legacy    stopped
cnss-daemon               running     ← 保留
rfkill0 bt_power soft     0           ← 原为 1
/dev/rfkill               crw-rw-rw-  ← 原为 crw-------
```

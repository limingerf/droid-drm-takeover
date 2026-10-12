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

## 8. 实测状态（2026-10-12）

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

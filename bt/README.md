# bt/ — 蓝牙 HCI 桥（HIDL 客户端）

在 **DRM 接管期**（安卓框架已停、桌面跑在容器里）让 **容器内的 BlueZ 拿到一颗
可用的 `hci0`**：能上电、能扫描、能配对。

```
容器内 bluetoothd / bluetoothctl / btmgmt
        ▲  AF_BLUETOOTH（HCI socket + mgmt）
        │  共享内核
   ┌────┴─────────────────────────────────────────────┐
   │  hci0  ← hci_uart(N_HCI, H4) ← pty slave        │  内核
   └────────────────────▲─────────────────────────────┘
                        │ pty master
   ┌────────────────────┴─────────────────────────────┐
   │  bthci-bridge（安卓侧 root，bionic）             │
   │    · HIDL 客户端 → IBluetoothHci/default         │
   │    · 回调节点（BpHw… 的对端 Bn/Bs）              │
   └────────────────────▲─────────────────────────────┘
                        │ /dev/hwbinder
              android.hardware.bluetooth@1.1-service-qti
                        │ glink / IBS
                     蓝牙芯片（上电、固件、射频全归 HAL 管）
```

桥只做一件事：**在 pty 的 H4 字节流和 HAL 的 HIDL 调用之间双向搬运**。
芯片上电、固件下载、UART/glink 时序、射频控制**全部仍由 vendor HAL 负责**，
桥不碰电源、不碰 `/dev/ttyHS0`、不碰 `/dev/btpower`、不碰 rfkill。

## 文件

| 文件 | 说明 |
| --- | --- |
| `bthci-bridge.cpp` | 桥本体（安卓侧，bionic） |
| `h4framing.h` | H4 分包与"写全"逻辑（纯函数，可宿主机单测） |
| `h4framing-test.cpp` | 上面那段的宿主机单测（21 条断言） |
| `build.sh` | NDK 交叉编译 + 宿主机单测（CI 的 `btbridge` job 用同一个脚本） |
| `bt-bridge-up.sh` | **设备侧**（`su -c` 跑）：起桥 + 4 条端到端验收 + 收桥 |
| `deploy.sh` | **主机侧**：构建 → push → 跑上面的脚本 |

## 快速开始

```sh
sh bt/deploy.sh            # 构建 + 推送 + 跑完整验收（跑完自动收桥）
sh bt/deploy.sh --stay     # 跑完把桥留着，容器里可以直接用蓝牙
sh bt/deploy.sh --down     # 只收桥并验残留
```

手工等价步骤：

```sh
sh bt/build.sh
adb push bt/out/bthci-bridge /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/bthci-bridge'
adb push bt/bt-bridge-up.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/bt-bridge-up.sh --stay'
```

收桥（**只用精确匹配**，绝不用 `-f`）：

```sh
adb shell su -c 'pkill -x bthci-bridge'
```

## 验收（实测输出，非"看起来对"）

`bt-bridge-up.sh` 跑出来的四条，全部在 **Lenovo TB710FU**（移植 ColorOS 后
`ro.product.model` 报成 `OPPO Pad OPD2511`，`ro.board.platform=pineapple`，
adb 序列号 `HA2HZAW2`，Android 17 / SDK 37）上实测通过：

| # | 判据 | 实测值 |
| --- | --- | --- |
| ① | 桥日志出现 `initializationComplete(status=0 SUCCESS)` | 通过（HAL 收下了我们的回调节点） |
| ② | 容器 `hciconfig -a hci0` 有 `Bus: UART` **且** BD_ADDR 非全零 | `Type: Primary Bus: UART` / `BD Address: 14:38:FA:15:E0:5D` / `UP RUNNING` / `errors:0` |
| ③ | 容器 `bluetoothctl show` 列出 Controller | `Powered: yes` / `PowerState: on` / 13 个 UUID / `Roles: central peripheral` |
| ④ | 收桥后 `/sys/class/bluetooth` 为空、rfkill 回基线、模块仍在 | **两边**都空 / `bt_power soft=0 hard=0` / 5 个模块 |

④ 必须**两边都查**（安卓侧 + 容器侧）：hci0 在共享内核里，只查一边会漏掉
"另一边还留着"。

外加一条**信息性**验证（不进退出码，射频环境不由我们决定）：容器里
`bluetoothctl --timeout 12 scan on` 实测**扫到 7~13 个真实设备**（midea 家电、
LAPTOP-… 等）—— 证明这不是"注册了个空壳设备节点"，而是射频真的在收发。

## 调试记录：踩过的坑

留在这里是因为每一条都**看起来像别的问题**，会把人带到错的方向上。

### `hci0/flags` 不存在，但被当成了"设备不存在"的判据

本机 `/sys/class/bluetooth/hci0/` 里只有 `power` / `rfkill9` / `subsystem` /
`uevent` —— **没有 `flags`**。早先状态行写的是

```sh
cat /sys/class/bluetooth/hci0/flags 2>/dev/null || echo NO-SYSFS-ON-ANDROID
```

于是**永远**打 `NO-SYSFS-ON-ANDROID`，把"其实好着呢"写成"看不见设备"，白白
误导了一轮排查。现在判据是**目录在不在**（`access(path, F_OK)`），打
`present` / `ABSENT`，顺带省掉每 10 秒一次 `popen`。

### 日志时间戳是假的

早先 `logmsg()` 拿 `CLOCK_MONOTONIC` 的秒数去喂 `localtime_r`，得到的是
"开机秒数当成 epoch 秒"的假时间：设备实际 `00:44`，日志写 `17:24`，跨进程对时
全错（当时正在排内核 setup 的超时，差点被这个带偏）。墙钟必须用
`CLOCK_REALTIME`；差值才用单调钟（那是 `now_ms()` 的事）。

### 桥有一次跑了几分钟后自行退场，日志什么都没说

实测遇到过一次：桥起来一切正常，跑了几分钟后走了**正常退场路径**
（`HAL close()` → 恢复 vtable 页 → 关 pty），但日志里没有任何原因。当时
`g_run = 0` 的三条路径里，**两条是完全静默的**：

```c
if (until && now_ms() >= until) break;        // --keep 到期：不吭声
if (s < 0 && errno != EINTR) break;           // poll 出错：不吭声
static void on_term(int) { g_run = 0; }       // 收到信号：连是哪个信号都不记
```

现在每条都记：`--keep` 到期、`poll` 失败（带 `strerror`）、
pty master `POLLHUP/POLLERR/POLLNVAL`（带 `revents`）、以及
`· 收到信号 N ⇒ 主动退场`。

**这次没复现出来**（如实说明）：插桩后跑了三轮 —— 裸 `nohup` 207 秒、
裸 `nohup` 391 秒、真实 `--stay` 路径 444 秒，全程 pid 不变、`hci0` 一直在。
最可疑的是 pty/ldisc 被内核侧拆掉导致 master 收到 `POLLHUP`（旧代码会静默
`break`），但**没有证据**，不下结论。下次再出现，日志会自己说出原因。

顺带排除：**不是 adb 会话回收**。完全断开 adb 静置 200 秒后桥照样活着
（pid 不变），所以 `nohup + </dev/null` 的 detach 是够的。

## 关键实现点（都是实测反推，不是照抄文档）

### 1. 为什么是 HIDL 不是 AIDL

本机 BT HAL 注册在 **hwservicemanager**（`/dev/hwbinder`），`lshal` 里是：

```
DM,FC  Y  android.hardware.bluetooth@1.0::IBluetoothHci/default
DM,FC  Y  android.hardware.bluetooth@1.1::IBluetoothHci/default
```

`service check android.hardware.bluetooth…` 在 framework servicemanager 里查不到。
所以走 `binder_ndk` 的 AIDL 桥在这个设备上**从根上就连不上**。

### 2. 回调节点：用 vendor 自己的 `Bs` 构造器 + 就地改 vtable

手写 `IBluetoothHciCallbacks` 实现类要踩虚继承 + vbase offset + RefBase 布局，
必错。改用 vendor `.so` 导出的构造器：

```
_ZN7android8hardware9bluetooth4V1_023BsBluetoothHciCallbacksC1ENS_2spINS2_22IBluetoothHciCallbacksEEE
ABI: void ctor(void* self, const sp<IBluetoothHciCallbacks>* impl)
```

对象布局（实测）：`+0x00` 主 vptr、`+0x08` HidlInstrumentor、`+0x60`
`sp<IBluetoothHciCallbacks> mImpl`、`+0x68` TaskRunner、`+0x78` RefBase。
`Bs` 的每个方法都 `ldr x21,[x21,#0x60]` 转发给 `mImpl` ⇒ 把 `mImpl` 指向自己，
再补丁主 vtable 就全部接管。

主 vtable 槽位（实测）：`13 initializationComplete`、`14 hciEventReceived`、
`15 aclDataReceived`、`16 scoDataReceived`。

**⚠️ 坑 A —— CFI。** 平台带 `-fsanitize=cfi-vcall`，虚调用前有 vtable 范围校验。
把 vptr 换成我们自己二进制里的表会被判失败（`__cfi_slowpath`）⇒ **必须
`mprotect` vendor 的 `.data.rel.ro` 就地改那张表**，vptr 保持原值。退出路径
（含错误分支）把页权限改回 `PROT_READ`，不给下一个加载者留一张可写的只读段。

**⚠️ 坑 B —— ABI。** 回调 handler 必须返回**非平凡类型**（`ReturnVoid`）。
返回 `void` 的话编译器不设 x8 传 sret，参数整体错位一格（`self` 收到 x1、
payload 收到 x2 垃圾）→ 段错误。同时 sret 的 offset 32（`mCheckedStatus`）
要置 1，否则平台 `Return::onIgnored()` 可能 fatal。

### 3. `HciPacket` 到底带不带 H4 类型字节：**不带**

依据是 AOSP 参考实现，不是猜：

```cpp
// hardware/interfaces/bluetooth/1.1/default/bluetooth_hci.cc
Return<void> BluetoothHci::sendHciCommand(const hidl_vec<uint8_t>& command) {
  sendDataToController(HCI_DATA_TYPE_COMMAND, command);
}
void BluetoothHci::sendDataToController(uint8_t type, const hidl_vec<uint8_t>& data) {
  VendorInterface::get()->Send(type, data.data(), data.size());
}
// hardware/interfaces/bluetooth/hci/h4_protocol.cc
size_t H4Protocol::Send(PacketType type, const uint8_t* data, size_t length) {
  struct iovec iov_array[] = {{&type, sizeof(type)}, {data, length}}; ...
}
```

类型是**单独参数**，payload 只有包体。回调方向同理。
不过 vendor 是 QTI 自己的实现，所以回调方向做了**长度自校验的自动判定**
（`cbHasTypeByte()`）：拿"包内声明的长度是否等于实际长度"来判，**不拿首字节猜**
—— 事件码 / ACL handle 低位与 `0x01..0x05` 的取值范围重叠，首字节启发式必错。
判定结果会打进日志（本机实测：不带）。

### 4. ★ 顺序：`openPty → initialize(HAL) → 起泵 → 最后才挂 N_HCI`

**这条是这次调试里最值钱的发现，写错会让整件事"看起来成功但完全没用"。**

内核一收到 `HCIUARTSETPROTO` 就 `hci_register_dev()` 并**立刻**跑它自己的 HCI
初始化序列（几十条命令：Reset / Read_Local_Version / Read_BD_ADDR /
Set_Event_Mask …），而 `hdev->setup` 是有**超时**的。如果此时桥还没
`initialize` HAL、主循环还没在 `poll` pty，那些命令就堆在 pty 缓冲里没人转发
→ 内核 setup 超时 → **`HCI_SETUP` 这个 dev_flag 清不掉** → 内核 mgmt 的索引表
（`read_index_list()` 会 `if (test_bit(HCI_SETUP, &d->dev_flags)) continue;`）
里**永远不会有这个设备**。

症状极具误导性：

* `hciconfig -a hci0` **一切正常**（`Bus: UART`、BD_ADDR 非零、`UP RUNNING`、
  `errors:0`）—— 因为 `hciconfig` 自己另发 HCI 命令读版本/特性，跟内核 setup 无关；
* `/sys/class/bluetooth/hci0` 也在；
* 但容器里 `bluetoothctl` 报 `No default controller available`、
  `btmgmt info` 报 `Index list with 0 items`。

实测耗时：HAL 的 `initialize()`（上电 + 固件下载）要 **1.6 秒**，正好够把内核
setup 等超时。

⚠️ **重启容器里的 `bluetoothd` 不能解决这个问题**（实测过，重启完照样
`No default controller available`）—— 内核 mgmt 索引里压根没有这个设备，
跟 bluetoothd 什么时候启动无关。别在这个方向上浪费时间。

顺带排除了一个看似合理的方向：**network namespace**。`/proc/<pid>/ns/net` 两边
inode 都是 `net:[4026531840]`，容器和安卓**是同一个 netns**，所以跟 netns 无关。

### 5. 线程模型

```
binder 池线程 ×N  ：收 HAL 的**同步**回调 → 只入队（绝不在这里做 pty IO）
写线程 ×1        ：出队 → 有界写 pty master
主线程           ：poll pty master → H4 切帧 → 同步调 sendHciCommand/Acl/Sco
```

回调是同步的，所以在回调里做阻塞 IO 就等于卡住 HAL 的事件泵。队列有界
（2048 包），溢出丢**最老**的一包并记账，绝不让 binder 线程阻塞。

写 pty 的铁律：**要么整包写完，要么一个字节都不写**。写到一半放弃会让内核
H4 解析器永久跑偏（`h4framing.h` 的 `may_drop()` 就是这条规则的代码化）。
已经写了一半却卡住超过 30 秒 ⇒ 判定桥不可用、主动退场，绝不留下半包。

### 6. 熔断

桥与安卓蓝牙栈**不能同时存在**：两个 `IBluetoothHci` 客户端抢同一颗 WiFi+BT
combo 芯片的电源协调（btpower/cnss），历史实测会把安卓 WiFi 打进
`is_driver_recovering 1 / Driver Loading Timed-out!!` 死循环，只能整机重启。

所以桥每 10 秒查一次 `init.svc.surfaceflinger`，一旦变成 `running` 立刻退场。
`bt-bridge-up.sh` 起桥前也硬门禁这条（不是建议，是拒绝启动）。

## 编译

```sh
sh bt/build.sh                              # NDK 自动探测
NDK=/opt/android-ndk-r27c sh bt/build.sh    # 显式指定
BT_OUT=/tmp/o sh bt/build.sh                # 换输出目录
```

* **必须用 NDK**：桥跑在安卓侧（要访问 hwservicemanager 和 vendor HAL），
  安卓用户态是 bionic；仓库根目录的 `Makefile` 出的是跑在容器里的 glibc 工具，
  两者不能混。所以 `bt/build.sh` 是独立的，**不动根 Makefile**。
* 不写死 API level：从可用的最高开始试（`36 35 34 33 32 31 30`），
  runner 镜像换代时写死的 API 会直接找不到编译器。
* `-static-libstdc++` ⇒ NEEDED 只有 `libdl/libm/libc`；CI 会断言这一点。
* `-Wl,-z,max-page-size=16384` ⇒ 安卓 15+ 的 16K 页设备上段对齐才够。

CI 在 `.github/workflows/build.yml` 的 `btbridge` job（第 4 个 job），
产物 artifact `btbridge-aarch64`。

## 命令行

```
--keep <秒>          运行时长，0=不限（默认 3600）
--no-kick            不调 hciconfig hci0 up
--no-close           退出时不调 HAL close()（让 binder 死亡通知回收）
--no-fuse            关闭框架熔断（**危险**，只用于调试）
--send-with-type     send* 给 HAL 的 payload 带 H4 类型字节（默认不带）
--cb-with-type       强制认为回调 payload 自带类型字节（默认自动判定）
--w-timeout <ms>     一包写 pty：一个字节都没写出去时最多等多久（默认 1000）
--status-every <秒>  状态打印间隔（默认 10）
--codes              打印槽位表后退出
```

`bt-bridge-up.sh` 的环境变量：`DS`（droidspaces 路径）、`CN`（容器名，默认
`DEBIAN`）、`BTBIN`、`BTLOG`、`WAIT_INIT`、`WAIT_HCI`、`BT_SCAN`（=0 跳过扫描）、
`BT_SCAN_SEC`。

## 红线（违反会砖/断网）

* 不重启容器、不改 `container.config`、不碰 `/data/a2lrootfs`
* 不 `setenforce 0`、不写 `/sys/class/rfkill/*`、不打任何 btpower/geni 电源 ioctl
* 桥只在 `init.svc.surfaceflinger = stopped` 期间存在
* 收桥只用**精确匹配**（`pkill -x` 或 `/proc/*/comm` 比对），**绝不用 `-f`**
* 回安卓要整机 `reboot`，本目录的脚本**不**做这件事
* 不做 systemd/KernelSU 自启

## 已知边界

* 只用 HAL 1.0 的 `initialize` + 4 个 `send*`。1.1 的 `initialize_1_1` /
  `sendIsoData` 没走（ISO/LE Audio 用不到）；`isoDataReceived` 回调不会到达。
* `linkToDeath` 是空实现（返回 OK），不真的注册死亡通知 —— HAL 挂了靠
  事务失败发现，不靠 death recipient。
* 桥不实现 `--send-with-type` 的自动判定（发送方向无法自校验），
  默认按 AOSP 契约"不带"；万一换设备后命令方向全哑，先试这个开关。
* `--stay` 只是"把桥留着不主动收"，**不是守护进程**：桥自己退了（比如上面那个
  还没查清的自退场），`--stay` 不会把它拉起来。要长时间用，自己套一层
  `while :; do ...; done` 或写个 systemd unit（注意红线：不做开机自启）。
  想知道它还在不在：`sh bt/deploy.sh --down` 会报残留，或者直接看
  `/sys/class/bluetooth`（**两边**）和 `bthci-bridge` 进程。

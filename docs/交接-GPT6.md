# droid-drm-takeover 交接文档（给 GPT-6）

> 交接时间：2026-10-13 02:5x
> 设备：Lenovo TB710FU（adb 序列号 `HA2HZAW2`），Android 17 / SDK 37 / arm64-v8a，KernelSU，SELinux Enforcing
> 本地仓库：`C:\Users\bai\Downloads\drm\work`（远端 `https://github.com/limingerf/droid-drm-takeover`）
> 最新提交：本地 `d49fa2c`，远端 `9b5483bf`（内容一致，推送方式见第 9 节）
> 上一份交接：`C:\Users\bai\Downloads\drm\HANDOFF.md`（468 行，仍然有效，本文件只写**新增/更正**的部分）

---

## 0. 一分钟看懂现状

这个项目让一台安卓平板**停掉安卓、在容器里跑 KDE Plasma Wayland 桌面**，并且让显示/触摸/输入回到 Linux 手里。

现在能用的：

| 功能 | 状态 |
|---|---|
| 桌面显示（3200×2000@144Hz，KWin GPU 加速） | ✅ 可用，但有 4 条横向噪声带（见 §4.1） |
| 触摸（四角定位正确） | ✅ 用户已确认「四角都正确」 |
| 锁屏（`kscreenlocker_greet` + Qt 虚拟键盘） | ✅ 可用 |
| 亮度面板 + 自动亮度 | ✅ **本次修好**（§3.1） |
| WiFi 连接 | ✅ 可用；密码保存需跑一次 `wifi-save-password`（§3.2） |
| 蓝牙（HIDL bridge） | ✅ **已完成并提交**，4/4 验收通过（§3.4） |
| 桌面「返回安卓」图标 | ✅ **本次新增**（§3.3） |
| 声音 / 音量键 | ❌ 声卡 PCM 是空壳（§4.3） |
| 电源键熄面板 | ⚠️ 机制已找对（CRTC ACTIVE=0），但唤醒会破坏左侧 DSI 链路（§4.2） |

### ⚠️⚠️ 接手第一件事：`env` 的选项顺序（2026-10-13 补）

**症状：整屏全黑、只有光标；触摸"没反应"。**

根因在 `core/lib/display.sh` 启动 plasmashell 的那条 `env` 命令：
`-u QT_IM_MODULE …` 被放在了 `WAYLAND_DISPLAY=… HOME=…` **后面**，
而 coreutils 的 `env` **要求选项全部在第一个 `NAME=VALUE` 之前**
⇒ `env` 把 `-u` 当程序名 ⇒ `env: '-u': No such file or directory`
⇒ **plasmashell 从来没启动**（KWin 在跑，但没有 shell ⇒ 黑屏）。

触摸"丢失"是**次生现象**，不是独立 bug —— KWin 日志说得很清楚：

```
kwin_core: Could not touch down, there's no window under QPointF(52.4774,404.956)
kwin_core: Detected a touch move that never has been down, discarding
```

**⇒ 黑屏时没有窗口，触摸按下无处可去，于是整串 touch 序列被丢弃。**
桌面一起来触摸就正常。**别再花时间查触摸驱动/校准矩阵。**

详见 §3.5。**任何往 `env` 行里加东西的改动，先读那一节。**

---

## 1. 硬件与平台事实（不要再重新推导这些）

### 1.1 面板与 DRM 拓扑

- 面板 `NT36532`，**双 DSI + DSC**，3200×2000@144Hz
- connector **67**，encoder **66**，CRTC **200**，topology id=59（`sde_quadpipe_dscmerge`，IMMUTABLE）
- 6 个 SDE CRTC，20 个 plane，其中 4 个 Primary：**92 / 123 / 127 / 131**
- 帧缓冲是 **10-bit**：`fourcc=0x30335241` = `AR30`，pitch **12800**（= 3200×4）
  → **绝对不能退回 8-bit**，否则颜色/带宽都不对
- `ro.board.platform=pineapple`（SM8650Q）；props 里写的是 OPPO `OPD2511`/`OP6546L1`（联想刷的 OPPO 固件）

### 1.2 为什么必须做「4 平面分屏」hack

**SDE 每个 CRTC 的最大水平显示宽度是 1600，不是 3200。**
直接把 3200 宽的帧缓冲交给一个 CRTC，内核会报：

```
[sde error] invalid horizontal destination x:0 w:3200 hdisp:1600
ret=-7 (E2BIG)
```

所以 `kwinwrap.c` 拦截原子提交，把**同一个全宽帧缓冲**拆给 4 个 plane，每个 plane 用
`SRC_X = i * SPLIT_W` 裁一段：

```
plane 131  crtc=200  dst=0,0    800x2000   src=0,0     800x2000   z=3
plane 127  crtc=200  dst=800,0  800x2000   src=800,0   800x2000   z=2
plane 123  crtc=200  dst=0,0    800x2000   src=1600,0  800x2000   z=1
plane 92   crtc=200  dst=800,0  800x2000   src=2400,0  800x2000   z=0
```

dst 坐标是**链路相对**的：驱动会先把 `crtc_x >= 1600` 的 plane 归到右侧 DSI，
再减去 1600，所以右边两条的 dst 看起来和左边重叠。这是对的，不要「修」。

相关环境变量（`core/device/opd2511.sh`）：

```
KWINWRAP_SPLIT_CONN=67  KWINWRAP_SPLIT_CRTC=200
KWINWRAP_SPLIT_W=800    KWINWRAP_SPLIT_W_FULL=3200   KWINWRAP_SPLIT_H=2000
KWINWRAP_SPLIT_PLANES=131   KWINWRAP_SPLIT_DST_INTERLEAVE=0
KWINWRAP_SPLIT_ZPOS=5
```

`KWINWRAP_NO_SPLIT=1` 是逃生开关（在 `kwinwrap.c` 约 1342 行），关掉分屏会直接 E2BIG，只用来验证假设。

### 1.3 触摸（已修好，别动）

原始 `ABS_MT_POSITION_X` 范围是 0..20000，但面板逻辑宽度是 3200。
`touchabs.so` 用 `EVIOCGABS` shim 把范围**上报成 `[20000,40000]`**，
这样 libinput 算出 `U = u - 1`，再配 2×2 矩阵 `0 -1 0 1 0 0` 就完全正确。
（`TOUCHABS_X_MIN=20000` / `TOUCHABS_X_MAX=40000`）

### 1.4 输入设备节点

| 节点 | 名字 | 关键键 |
|---|---|---|
| event0 | `gpio-keys` | 115 `KEY_VOLUMEUP` |
| event1 | `pmic_pwrkey` | 116 `KEY_POWER` |
| event2 | `pmic_resin` | 114 `KEY_VOLUMEDOWN` |
| event5 | `NVTCapacitiveTouchScreen` | 触摸 |

90 秒裸抓 `/dev/input/event1`、按一次电源键 = **恰好 4 个事件**，没有 PMIC 鬼影。

---

## 2. 本次会话（2026-10-13）做了什么

1. 修好了**亮度面板 + 自动亮度**（根因是 KAuth 背光助手没在跑）
2. 定位了 **WiFi 密码保存失效**的根因（KWallet 崩溃），并给出不依赖它的保存路径
3. 新增**桌面「返回安卓」快捷方式**（自绘经典安卓机器人图标）
4. 修正了 `net-takeover.sh` 里**会把 WiFi 密码保存永久弄坏**的那段逻辑
5. 把「电源键熄面板」的正式路径定为 `drmbl crtc-off/crtc-on`（新增 `drmbl.c`）
6. 修掉了 `crtc-on` 的 **DRM property blob 生命周期**坑（这是「只亮半边」的根因）
7. 确认了声音修不好的**具体**原因（PCM 写入 EINVAL）
8. 确认了 4 条横向噪声带**不在渲染里**（帧缓冲是干净的）
9. 提交并推送（`d49fa2c` / `9b5483bf`）

**关于蓝牙**：本轮**没有**改蓝牙代码 —— 它在更早的 `1088ff0` / `00d2568` 里就已经
完成、验收、提交并推送了（CI `btbridge` job 通过）。
本轮只是**核对确认它在远端**，并把完整细节补进本文档 §3.4（原来的交接文档
只写了「4/4 验收通过」一行，太薄，接手的人看不出关键坑在哪）。

### 2.1 第二轮（用户报「一启用接管就丢触摸、同步仓库后黑屏」）

10. **修好了整屏黑屏** —— 根因是 `env` 的选项顺序（§3.5），plasmashell 从来没启动
11. **确认触摸"丢失"是黑屏的次生现象**，触摸链路本身完好（§3.5 末）
12. **补回 `bin/drmbl`** —— 被我用 Windows tar 整体替换 `bin/` 时弄丢的（§3.5 末）
13. **提交了漏提交的 385 行**：多容器支持 + watch 守护的两个单例误判
    （`f7ceb0f`，`core/lib/{common,container,device,request}.sh` + `core/switch.sh`）
14. 把 `bin-new/` 合并进 `bin/`（37 个，两边互补）

**⚠️ 这两条是我（上一轮）造成的，已修复并写进 §3.5 末尾的教训里：**
用 Windows 的 tar 整体替换容器仓库目录 ⇒ 丢了 Unix 权限位 + 覆盖了
gitignore 的 `bin/`。

---

## 3. 已完成并验证的功能（含证据）

### 3.1 亮度面板与自动亮度消失 ✅ 已修

**症状**：托盘里的亮度滑块没了，自动亮度也没了。
`busctl --user tree org.kde.Solid.PowerManagement` 里**没有** `Actions/BrightnessControl`；
`org.kde.ScreenBrightness DisplaysDBusNames` = `as 0`。

**根因链**（不是亮度属性写不进去）：

```
PowerDevil → KAuth org.kde.powerdevil.backlighthelper → BacklightDetector
                     ↑
        这个名字由 dbus-daemon 按需激活，
        而本容器 rootfs 是 nosuid 挂载 ⇒ dbus-daemon-launch-helper 的
        setuid 位不生效 ⇒ 任何 User= 的 system D-Bus service 都激活不了
        ⇒ 探测器失败 ⇒ 没有可调屏 ⇒ 亮度面板和自动亮度一起消失
```

**修法**：让 systemd（PID 1，本来就是 root）常驻把 helper 拉起来抢住总线名。
文件：`display/powerdevil-backlight-helper.service`（装到 `/etc/systemd/system/droidspaces-backlight-helper.service`）

**实测自证**（2026-10-13 02:41）：

```
起 unit 前：DisplaysDBusNames = as 0
起 unit 后：DisplaysDBusNames = as 1 "display0"
           Actions/BrightnessControl        出现
           Actions/ScreenBrightnessControl  出现
           brightness = 5001
           brightnessMax = 10000
```

**⚠️ 一个坑**：`backlighthelper` 手动跑完全正常（`timeout` 杀掉时 rc=124），
但通过 systemd 起来时 `restart counter` 会涨到 6。**只要它最终 active 且总线名被持有就没问题**，
判断依据是 `busctl --system list | grep backlight` 里那一行**没有 `(activatable)` 后缀**。

**另外两个断点也一起补了**（都是「绕过 `startplasma-wayland` 手工起桌面」导致的）：

- `plasma-powerdevil.service` 是 static unit，没人拉 → `display/powerdevil-enable.sh`
- 缺 `WAYLAND_DISPLAY` 会直接 SIGABRT（`Failed to create wl_display`）
  → `display/powerdevil-wayland-env.conf` drop-in（`WAYLAND_DISPLAY=taketest`）
- 空闲熄屏会把背光打到 **1** → `display/powerdevilrc` 关掉
  `TurnOffDisplayWhenIdle` / `DimDisplayWhenIdle`

**⚠️ `powerdevil-enable.sh --check` 会报「✗ 没有可调屏」—— 这条判据是错的**，
按上游设计，非 KWin 的探测器（BacklightDetector）探到的屏**不进** `m_displaysById`，
而是通过 `kde_external_brightness_v1` 导出给 KWin。**不要照这条去"修"**。

### 3.2 WiFi 密码保存失效 ✅ 已定位 + 给了可用路径

**根因**：连接文件里 `psk-flags=1`（密钥交给代理保管），但**本容器的 KWallet 是坏的**：

```
· kwallet6 装了（6.13.0-1），但 ~/.local/share/kwalletd/ 里一个钱包文件都没有
· 任何 busctl --user call org.kde.kwalletd6 … 都让它 SIGABRT：
    Call failed: Process org.kde.kwalletd6 received signal 6
· 钱包目录权限已经是 0700，仍然崩（原因未定位）
```

⇒ plasma-nm 把密码拿到手、连上了，**然后丢掉**。重启桌面后连接因缺密钥连不上，用户每次都要重输。

**⚠️ 仓库里原来那段逻辑在固化这个病**：
`network/net-takeover.sh` 的 `nt_fix_secrets` 原来**无条件把 `psk-flags` 归位到 1**。
本次改成按**文件里到底有没有 `psk=` 字面值**做一致性纠正：

```
有 psk=   → flags=0（NM 自己保管，重启不丢）
没有 psk= → flags=1，并提示跑 wifi-save-password
```

**新增**：`network/wifi-save-password.sh` → `/usr/local/bin/wifi-save-password`
+ 桌面图标「保存 WiFi 密码」（konsole 里跑）。

**★ 使用注意**：只改 `psk-flags` 不改文件会把连接**彻底弄坏**
（NM 既不去问代理、文件里又找不到密钥 ⇒ 永远连不上，而且图形界面也不再提示输密码）。
脚本强制两步一起做，并且**读回文件自证**（不是看命令返回 0）。

**⇒ 下一步建议**：要么让用户点一次「保存 WiFi 密码」把 psk 落到文件里；
要么去查 `kwalletd6` 为什么 SIGABRT（`kwallet6` 包里似乎没有 backend 插件，
`dpkg -L kwallet6 | grep -i backend` 是空的，这可能是原因）。

### 3.3 桌面「返回安卓」快捷方式 ✅ 新增

三个新文件：

- `display/android-robot.svg` —— 自绘的经典安卓机器人（品牌绿 `#A4C639`）。
  主题里**没有**机器人本体（只有 `android-file-transfer` / `android-studio` / `folder-android`），
  所以按官方形状重画。
- `display/return-to-android.sh` —— **用户级**启动器。关键点：
  会合目录 `/var/lib/droid-drm-takeover` 权限是 **`drwxrwxrwt`（1777）**，
  所以桌面用户 **Gold 直接写得进 `exit.request`，不需要提权**。
  整机重启由安卓侧守护做。带 `kdialog --yesno` 二次确认防误触。
- `display/android-return-icon.sh` —— 安装器（幂等，带 `--check` / `--remove`）。

装出来的东西：

```
/usr/share/icons/hicolor/scalable/apps/android-robot.svg
/usr/local/bin/return-to-android
/usr/share/applications/android-return.desktop
/home/Gold/Desktop/返回安卓.desktop          ← 755 + Gold:Gold（否则 KDE 显示"未信任"）
```

**当前桌面图标**：`usb-manager` / `wifi-connect` / `wifi-save-password` / `返回安卓`

**自证结果**：守护在听（心跳新鲜）、会合目录可写、桌面图标权限 `755 Gold:Gold` ✅

---

### 3.4 蓝牙 HCI 桥 ✅ 已完成、已提交、已验收

**提交记录**（两个都在远端）：

```
1088ff0  bt: 蓝牙桥从 AIDL 移植成 HIDL 客户端 —— 容器里出现可用的 hci0（4 条验收实测通过）
00d2568  bt: 修掉三处会把人带偏的观测缺陷（假时间戳 / 假"看不见设备" / 静默退场）
```

`00d2568` 就是本文档对应那次推送的 base ⇒ **确定已经在远端 `main` 上**。
CI 的 `btbridge` job 通过，产物 artifact `btbridge-aarch64`。
详细文档在仓库里：`work/bt/README.md`（310 行）、`work/bt/HIDL-探针结论.md`。

### 它解决什么问题

DRM 接管期安卓框架已停、桌面跑在容器里，此时容器里的 BlueZ **看不到任何控制器**。
桥让容器拿到一颗真正可用的 `hci0`：能上电、能扫描、能配对。

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
                        │ glink / IBS（★ 不是 UART）
                     蓝牙芯片（上电、固件、射频全归 HAL 管）
```

**桥只做一件事**：在 pty 的 H4 字节流和 HAL 的 HIDL 调用之间双向搬运。
芯片上电、固件下载、时序、射频控制**全部仍由 vendor HAL 负责** ——
桥不碰电源、不碰 `/dev/ttyHS0`、不碰 `/dev/btpower`、不碰 rfkill。

### 验收结果（实测输出，不是"看起来对"）

在 Lenovo TB710FU（`ro.board.platform=pineapple`，Android 17/SDK 37）上：

| # | 判据 | 实测值 |
|---|---|---|
| ① | 桥日志出现 `initializationComplete(status=0 SUCCESS)` | ✅ HAL 收下了我们的回调节点 |
| ② | 容器 `hciconfig -a hci0` 有 `Bus: UART` 且 BD_ADDR 非全零 | ✅ `Bus: UART` / `BD Address: 14:38:FA:15:E0:5D` / `UP RUNNING` / `errors:0` |
| ③ | 容器 `bluetoothctl show` 列出 Controller | ✅ `Powered: yes` / `PowerState: on` / 13 个 UUID / `Roles: central peripheral` |
| ④ | 收桥后 `/sys/class/bluetooth` 为空、rfkill 回基线、模块仍在 | ✅ **两边**都空 / `bt_power soft=0 hard=0` / 5 个模块 |

④ 必须**两边都查**（安卓侧 + 容器侧）：hci0 在共享内核里，只查一边会漏掉"另一边还留着"。

外加一条**信息性**验证（不进退出码）：容器里 `bluetoothctl --timeout 12 scan on`
实测**扫到 7~13 个真实设备**（midea 家电、LAPTOP-… 等）
⇒ 证明这不是"注册了个空壳设备节点"，而是射频真的在收发。

### ★★★ 最值钱的发现：初始化顺序

**这条写错会让整件事"看起来成功但完全没用"。**

```
openPty  →  initialize(HAL)  →  起 pty 泵  →  ★ 最后才挂 N_HCI
```

内核一收到 `HCIUARTSETPROTO` 就 `hci_register_dev()` 并**立刻**跑自己的 HCI 初始化序列
（Reset / Read_Local_Version / Read_BD_ADDR / Set_Event_Mask …），而 `hdev->setup`
是**有超时**的。如果此时桥还没 `initialize` HAL、主循环还没在 `poll` pty，
那些命令就堆在 pty 缓冲里没人转发 → 内核 setup 超时 → **`HCI_SETUP` 这个 dev_flag 清不掉**
→ 内核 mgmt 的索引表里（`read_index_list()` 会
`if (test_bit(HCI_SETUP, &d->dev_flags)) continue;`）**永远不会有这个设备**。

症状极具误导性：

```
hciconfig -a hci0   →  一切正常（Bus: UART、BD_ADDR 非零、UP RUNNING、errors:0）
/sys/class/bluetooth/hci0  →  也在
但 bluetoothctl     →  No default controller available
   btmgmt info      →  Index list with 0 items
```

（`hciconfig` 自己另发 HCI 命令读版本/特性，跟内核 setup 无关，所以它看着正常。）

实测耗时：HAL 的 `initialize()`（上电 + 固件下载）要 **1.6 秒**，正好够把内核 setup 等超时。

⚠️ **重启容器里的 `bluetoothd` 解决不了**（实测过）—— 内核 mgmt 索引里压根没这个设备，
跟 bluetoothd 什么时候启动无关。**别在这个方向上浪费时间。**

顺带排除：**不是 network namespace**。`/proc/<pid>/ns/net` 两边 inode 都是
`net:[4026531840]`，容器和安卓是同一个 netns。

### 其他关键实现点

**① 为什么是 HIDL 不是 AIDL**：本机 BT HAL 注册在 **hwservicemanager**
（`/dev/hwbinder`），`lshal` 里是 `android.hardware.bluetooth@1.0::IBluetoothHci/default`
和 `@1.1`。`service check` 在 framework servicemanager 里查不到
⇒ 走 `binder_ndk` 的 AIDL 桥在这个设备上**从根上就连不上**。

**② 回调节点：用 vendor 自己的 `Bs` 构造器 + 就地改 vtable**
手写 `IBluetoothHciCallbacks` 实现类要踩虚继承 + vbase offset + RefBase 布局，必错。
改用 vendor `.so` 导出的构造器：

```
_ZN7android8hardware9bluetooth4V1_023BsBluetoothHciCallbacksC1ENS_2spINS2_22IBluetoothHciCallbacksEEE
ABI: void ctor(void* self, const sp<IBluetoothHciCallbacks>* impl)
```

对象布局（实测）：`+0x00` 主 vptr、`+0x08` HidlInstrumentor、`+0x60`
`sp<IBluetoothHciCallbacks> mImpl`、`+0x68` TaskRunner、`+0x78` RefBase。
`Bs` 每个方法都 `ldr x21,[x21,#0x60]` 转发给 `mImpl` ⇒ 把 `mImpl` 指向自己，
再补丁主 vtable 就全部接管。主 vtable 槽位（实测）：
`13 initializationComplete`、`14 hciEventReceived`、`15 aclDataReceived`、`16 scoDataReceived`。

- **⚠️ 坑 A —— CFI。** 平台带 `-fsanitize=cfi-vcall`，把 vptr 换成我们自己二进制里的表
  会被 `__cfi_slowpath` 判失败 ⇒ **必须 `mprotect` vendor 的 `.data.rel.ro` 就地改那张表**，
  vptr 保持原值。退出路径（含错误分支）把页权限改回 `PROT_READ`。
- **⚠️ 坑 B —— ABI。** 回调 handler 必须返回**非平凡类型**（`ReturnVoid`）。
  返回 `void` 的话编译器不设 x8 传 sret，参数整体错位一格 → 段错误。
  同时 sret 的 offset 32（`mCheckedStatus`）要置 1。

**③ `HciPacket` 带不带 H4 类型字节：不带**（依据 AOSP `h4_protocol.cc` 参考实现）。
类型是**单独参数**，payload 只有包体。不过 vendor 是 QTI 自己的实现，
所以回调方向做了**长度自校验的自动判定**（`cbHasTypeByte()`）——
拿"包内声明的长度是否等于实际长度"来判，**不拿首字节猜**
（事件码 / ACL handle 低位与 `0x01..0x05` 重叠，首字节启发式必错）。
本机实测判定结果：**不带**。

**④ 线程模型**

```
binder 池线程 ×N ：收 HAL 的**同步**回调 → 只入队（绝不在这里做 pty IO）
写线程 ×1        ：出队 → 有界写 pty master
主线程           ：poll pty master → H4 切帧 → 同步调 sendHciCommand/Acl/Sco
```

回调是同步的，所以在回调里做阻塞 IO 就等于卡住 HAL 的事件泵。
队列有界（2048 包），溢出丢**最老**的一包并记账。
写 pty 的铁律：**要么整包写完，要么一个字节都不写** ——
写到一半放弃会让内核 H4 解析器永久跑偏。已经写了一半却卡住超 30 秒
⇒ 判定桥不可用、主动退场，绝不留下半包。

**⑤ 熔断（安全关键）**
桥与安卓蓝牙栈**不能同时存在**：两个 `IBluetoothHci` 客户端抢同一颗 WiFi+BT
combo 芯片的电源协调（btpower/cnss），历史实测会把安卓 WiFi 打进
`is_driver_recovering 1 / Driver Loading Timed-out!!` 死循环，**只能整机重启**。
所以桥每 10 秒查一次 `init.svc.surfaceflinger`，一旦变成 `running` 立刻退场；
`bt-bridge-up.sh` 起桥前也硬门禁这条（**不是建议，是拒绝启动**）。

### 用法

```sh
sh bt/deploy.sh            # 构建 + 推送 + 跑完整验收（跑完自动收桥）
sh bt/deploy.sh --stay     # 跑完把桥留着，容器里可以直接用蓝牙
sh bt/deploy.sh --down     # 只收桥并验残留
```

收桥（**只用精确匹配**）：

```sh
adb shell su -c 'pkill -x bthci-bridge'      # ★ -x 必须，绝不用 -f
```

编译：`sh bt/build.sh`（**必须用 NDK** —— 桥跑在安卓侧 bionic，
和仓库根 `Makefile` 出的容器 glibc 工具不能混，所以 `bt/build.sh` 是独立的，
**不动根 Makefile**）。`-static-libstdc++` ⇒ NEEDED 只有 `libdl/libm/libc`；
`-Wl,-z,max-page-size=16384` ⇒ 安卓 15+ 的 16K 页设备上段对齐才够。

### 已知边界

- 只用 HAL 1.0 的 `initialize` + 4 个 `send*`。1.1 的 `initialize_1_1` /
  `sendIsoData` 没走（ISO/LE Audio 用不到）；`isoDataReceived` 回调不会到达。
- `linkToDeath` 是空实现（返回 OK），不真的注册死亡通知。
- `--send-with-type` 的自动判定没实现（发送方向无法自校验），默认按 AOSP 契约"不带"。
- `--stay` 只是"把桥留着不主动收"，**不是守护进程**：桥自己退了不会自动拉起。
- **有一次跑了几分钟后自行退场**，当时日志什么都没说。插桩后跑了三轮
  （207 秒 / 391 秒 / 444 秒）**没有复现**，全程 pid 不变、hci0 一直在。
  最可疑的是 pty/ldisc 被内核侧拆掉导致 master 收到 `POLLHUP`，
  但**没有证据，不下结论**。现在每条退出路径都会记原因，下次出现日志会自己说出来。
  顺带排除：**不是 adb 会话回收**（断开 adb 静置 200 秒桥照样活着）。

### 三条会把人带偏的观测缺陷（已在 `00d2568` 修掉）

留在这里是因为每一条都**看起来像别的问题**：

1. **`hci0/flags` 不存在，但被当成了"设备不存在"的判据**
   本机 `/sys/class/bluetooth/hci0/` 里只有 `power` / `rfkill9` / `subsystem` / `uevent`
   —— **没有 `flags`**。早先写 `cat .../flags 2>/dev/null || echo NO-SYSFS-ON-ANDROID`
   于是**永远**打 `NO-SYSFS-ON-ANDROID`，把"其实好着呢"写成"看不见设备"。
   现在判据是**目录在不在**（`access(path, F_OK)`）。
2. **日志时间戳是假的** —— 早先 `logmsg()` 拿 `CLOCK_MONOTONIC` 的秒数喂 `localtime_r`，
   得到"开机秒数当成 epoch 秒"的假时间（设备 `00:44`，日志写 `17:24`）。
   墙钟必须用 `CLOCK_REALTIME`；差值才用单调钟。
3. **静默退场** —— `g_run = 0` 的三条路径里两条完全静默（`--keep` 到期、`poll` 出错），
   信号处理连是哪个信号都不记。现在每条都记。

### 3.5 🔴 整屏黑屏 + 触摸"丢失" —— `env` 选项顺序（2026-10-13 修复）

**用户报告**：「gpt6 一启用接管，就是丢触摸，同步一下仓库，面板就直接黑屏了」

**两个症状，一个根因。**

#### 根因

`core/lib/display.sh` 启动 plasmashell 的那条命令：

```sh
setsid nohup runuser -u "$DESKTOP_USER" -- \
    env -u DISPLAY $_unset_env \
        WAYLAND_DISPLAY="$_sock" HOME="$DESKTOP_HOME" \      ← 从这里起已经是 NAME=VALUE
        ...
        $_qtqb \
        $_im_env \        ← ★ 展开成 "-u QT_IM_MODULE -u GTK_IM_MODULE …"
    plasmashell --replace
```

**coreutils 的 `env.c` 用的是 `getopt_long(..., "+i0v", ...)`，那个 `+` 就是
关闭 GNU 的参数重排** ⇒ 选项必须全部出现在第一个 `NAME=VALUE` 之前。
一旦顺序错了，`env` 把 `-u` 当成**程序名**：

```
env: '-u': No such file or directory
```

⇒ **plasmashell 从来没启动过。** KWin / kwinwrap 都在跑，但没有 shell
⇒ 黑屏 + 只有光标。

#### 为什么以前"看起来是好的"

这个 bug 从 `03de65e` 就在，但设了 `DEV_IM_FCITX=1` 时走的是另一条分支，
那条分支产出的是**赋值**（`QT_IM_MODULE=fcitx …`），恰好合法 ⇒ 能起来。
**默认路径（不设 `DEV_IM_FCITX`）一直是坏的**，只是以前没人在纯默认配置下
重启过桌面。

#### 修法

拆成「选项」和「赋值」两个变量（不能简单地把 `$_im_env` 挪到前面 ——
它随分支变化，可能是选项也可能是赋值）：

```sh
_im_unset=""
_im_set=""
if [ "${DEV_IM_FCITX:-0}" = 1 ]; then
    _im_set="QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx …"
else
    _im_unset="-u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS -u SDL_IM_MODULE -u GLFW_IM_MODULE"
fi

env -u DISPLAY $_unset_env $_im_unset \      ← 选项全在这里
    WAYLAND_DISPLAY=… HOME=… … \
    $_kde_env $_qtqb $_im_set ${DEV_PLASMA_ENV:-} \   ← 赋值全在这里
    plasmashell --replace
```

判定实验（一字不差地复现了日志）：

```sh
env A=1 -u B sh -c 'echo x'   →  env: '-u': No such file or directory
env -u B A=1 sh -c 'echo x'   →  x
```

#### ⚠️ 规则：往 `env` 行里加东西之前先分类

| 加的东西 | 只能放哪 |
|---|---|
| `-u NAME` / `-i` / `--` 等**选项** | 紧跟 `env` 的那一段（`$_unset_env` / `$_im_unset`） |
| `NAME=VALUE` **赋值** | 第一个赋值之后的任意位置 |

**全仓库已扫描过一遍**（`env` 块里"选项出现在赋值之后"），
除本条外没有第二处。`core/lib/display.sh:1169` 的 kwinwrap 那条是安全的
（`-u` 全在赋值前，后面 `$_loc_env` / `$_fmt_preload` / `$_fmt_hz` /
`$_kwin_env` 都只含赋值）。

#### 触摸"丢失"是次生现象，**不是**独立 bug

修好之前 KWin 日志的原文：

```
kwin_core: Could not touch down, there's no window under QPointF(52.4774,404.956)
kwin_core: Detected a touch move that never has been down, discarding
kwin_core: Detected a touch that never started, discarding
```

**触摸事件其实送到了，坐标也换算对了**（`52.5, 405.0` 落在 1600×1000 的
逻辑空间里，符合 §1.3 的校准）—— 但 KWin 在**那个位置找不到窗口**
⇒ 拒绝建立触摸序列 ⇒ 后续 move 全被判成 "never been down"。

**⇒ 黑屏时没有窗口，触摸自然"没反应"。桌面一起来就正常。**
排查时已确认触摸链路本身完好，别去动它：

```
udev 规则      /etc/udev/rules.d/79-droid-drm-takeover-touch.rules ✓
              ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 0 1 0 0"
udev 数据库    LIBINPUT_CALIBRATION_MATRIX=0 -1 0 1 0 0 ✓
              LIBINPUT_DEVICE_GROUP=1c/0/0:input/ts ✓
KWin 进程      LD_PRELOAD 里有 touchabs.so ✓
              TOUCHABS_X_MIN=20000 / TOUCHABS_X_MAX=40000 ✓
已加载         /proc/<kwin>/maps 里两个 .so 都在 ✓
```

#### ⚠️⚠️ 附带教训：**不要用 Windows 的 tar 整体替换容器里的仓库目录**

我上一轮为了同步源码，在 Windows 上 `tar -cf` 了整个 `work/` 再解到容器里、
用 `mv` 整体换掉 `droid-drm-takeover/`。两个后果：

1. **Windows 文件系统没有 Unix 权限位**，tar 把所有文件记成 `0666`
   ⇒ 容器里所有 `.sh` 丢掉 `+x`。（后来用 git 重新同步才恢复。）
2. **`bin/` 是 gitignore 的构建产物目录**，本地只有子集
   ⇒ 整体替换把容器里完整的 `bin/` 覆盖成子集，
     **`bin/drmbl` 丢了** ⇒ 现象：
     ```
     警告：找不到 bin/drmbl（先跑 make runtime）⇒ 面板无法真正熄灭
     ```
     电源键熄屏退化成"只调最暗"。

**正确姿势**：只同步 git 跟踪的文件（`git archive` / 逐个 push），
或者**根本别碰 `bin/`**。要同步源码就 `git -C work archive HEAD | tar -x -C <目标>`。

修复后的 `bin/` 是 **37 个**（本地 `bin/` 36 个含 `fbdump` 缺 `drmbl`，
GPT-6 新建的 `bin-new/` 36 个含 `drmbl` 缺 `fbdump`，**两者互补**，合并才完整）。

---

## 4. 未解决的问题（按优先级）

### 4.1 🔴 桌面有 4 条横向噪声带（本次实验的副作用）

**用户原话**：「你刚刚实验性的做了几个操作，现在桌面多了几个横纹」→ 干净重启后「还有横纹」

**已经排除的**（不要重复做）：

| 做过的尝试 | 结果 |
|---|---|
| 完整杀掉并重启 KWin / kwinwrap / plasmashell / PowerDevil | ✗ 横纹还在 |
| 把动过的属性全部复位（`bl_scale=1024`、`sv_bl_scale=65535`、`dimming_min_bl=0`、`dim_layer_v1=0`、`dpms on`、`crtc-on`、`set 2048`） | ✗ |
| 逐项比对 connector 属性表 vs 已知基线 | **完全一致**，没有异常项 |
| 逐项比对 plane 状态（healthy vs 出问题后） | **除了 FB id 完全一致** |
| 回退 FB-FALLBACK / `KWINWRAP_TRACE` | ✗ |

**关键判据（本次新做的）**：用 `fbdump` 把当前帧缓冲导成 PPM 拉回本地分析：

```
size (3200, 2000) RGB
逐行水平梯度 > 120 的像素占比，最大 0.030（就是任务栏/顶栏边缘）
中位噪声比 0.0000，均值 0.0009
噪声带检测：[]  ← 一条都没有
```

**⇒ 帧缓冲是干净的。噪声不在渲染里，在 SDE → DSI → DSC → 面板这段管线里。**

而 KWin 重启 = 一次**完整 modeset**，它都清不掉 ⇒ 不是软件状态问题。

**⇒ 结论：需要一次整机重启才能干净恢复。** 走 `display/drm-stop.sh`（写 `exit.request`）
→ 安卓侧守护 → `/system/bin/reboot`。桌面上的「返回安卓」图标就是干这个的。

**如果重启后横纹仍在**，那说明不是本次实验造成的，要去查：
- DSC 的 slice 配置（`dsc_mode` / `bpp_mode` / `mode_properties` blob）
- 4 条横纹的位置是否对应 DSC slice 边界
- `SDE_DSPP_*` 系列 LUT blob（当前 `PCC=315`、`MEMCOL_PROT=316`、`IGC=0`）

### 4.2 🟡 电源键熄面板：机制对了，但唤醒会破坏左侧 DSI 链路

**用户需求**：「不能把电源键改成锁屏并熄灭面板吗?」

**已查清的关键事实**：

- connector 的 `DPMS` 属性 flags = `0x00000008` = **ENUM，没有 `DRM_MODE_PROP_ATOMIC`**
  ⇒ KWin 的原子提交必然 `EINVAL` ⇒ `kwin_wayland_drm: Setting dpms mode failed!`
  ⇒ `kscreen-doctor --dpms off` **返回 rc=0 但什么都没发生**。
  **这是"电源键只闪一下"的根因。**
- 安卓侧真正的熄屏方式是 HWC/sde 把 **CRTC `ACTIVE` 置 0** ⇒ 整个 CRTC 停 ⇒ DSI 面板睡眠。
- CRTC 200 的 `ACTIVE`（prop 22，flags `0x80000002`，**有 ATOMIC**）和
  `MODE_ID`（prop 23，flags `0x80000010`，blob）都可以用**非原子** ioctl 写成功。

**已实现**：`drmbl` 新增 `crtc-off` / `crtc-on` / `crtcprop`；
`input/drm-keys.py` 和 `input/lockscreen.sh` 默认走 `PANEL_OFF_MODE=crtc`。

**★ 一个必须知道的坑（本次修掉）**：
DRM property blob 的生命周期**跟着创建它的 fd**。短命进程建的 blob 一退出就失效，
之后写 `MODE_ID=<旧 id>` 会 `Invalid argument`。
⇒ `crtc-on` 必须**每次都从 connector 的 `DRM_MODE_TYPE_PREFERRED` 现场新建 blob**，
先写 `MODE_ID` 再写 `ACTIVE=1`。**这正是此前"只亮半边"的根因。**

**仍未解决**：`crtc-off` 之后 `crtc-on` 唤醒时，**左侧 DSI 链路有时不恢复**（左半屏黑）。
已排除的方向（全部失败）：

```
crtc-on 带全新 MODE_ID            ✗
connector CRTC_ID=0 解绑           ✗  写 CRTC_ID=0 直接 Invalid argument
crtc-off/on 连做两次               ✗
kscreen-doctor scale 3 再回 2      ✗
dim_layer_v1 各种值                ✗  写了不报错但「完全没变化」
SDE_DSPP_LTM_V1=1                  ✗  flags 含 IMMUTABLE，本来就写不进
```

**唯一能恢复的**：重启 KWin。而 plane 层在健康态和坏态下**逐项完全一致**
⇒ 问题在 DSI link / encoder 层，不在 plane 层。

### 4.3 🟡 声音 / 音量键：PCM 是空壳

**本次确认的具体原因**：

```
aplay -l          → card 0: pineapplemtpsnd，50 个 playback PCM
aplay -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 1 /dev/zero
  → Playing raw data ... Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
  → aplay: pcm_write:2178: write error: Invalid argument
```

**能打开、能设参数（可用格式 S16_LE / S24_LE），但一写数据就 EINVAL。**
⇒ 这些 PCM 是**空壳**，背后需要 **AGM/PAL 会话**才真正接上 DSP。
和之前记录的 AGM 阻塞点是**同一个病**，不是配置问题。

PipeWire 侧：`wpctl status` 只有 `Dummy Output`，一张真声卡都没有。
`kglobalshortcutsrc` 里**没有任何音量快捷键条目**（因为 plasma-pa 看不到音频设备）。
`plasma-pa` 4:6.3.4-1 已装，`pipewire` / `pipewire-pulse` / `wireplumber` 都在跑。

**⇒ 音量键修不好的原因不是键没绑，是根本没有可控制的音频设备。**

**已知的 AGM 事实**（来自上一轮调查）：
- HIDL 栈，**不是 AIDL** ⇒ 上游仓库的 A 路线不可移植
- `vendor.qti.hardware.AGMIPC@1.0::IAGM/default` 可达，`agm_init rc=0`，
  `agm_get_aif_info_list rc=0`（54 个 AIF），`agm_session_aif_connect rc=0`
- ABI：`agm_session_open(uint32_t session_id, uint32_t mode, agm_session_t *handle)`；
  `agm_session_aif_connect(uint32_t session_id, uint32_t aif_id, uint32_t enable)`；
  `agm_session_set_config(uint64_t session_id, session_config*, media_config*, buffer_config*)`
- 调用顺序：先 `aif_connect` 再 `session_open`
- **阻塞点**：media config 是 `0/0/0` ⇒ `cannot set hw params: Invalid argument rate 48000 ch 0 fmt 0`
- AAudio 被挡（`AAUDIO_ERROR_NO_SERVICE`）
- 推荐路线 P1：AGM `set_config(48000/2ch/16bit)` → `prepare` → `start` → `write`

### 4.4 🟢 其他遗留

- **Qt 虚拟键盘焦点 bug**：「锁屏界面还能触发弹出，多点两下就把键盘弄没了，
  然后再点输入框触发不了，必须点其它地方再点回输入框才能再弹出」
- `lockscreen.sh` 的 usage 文本和 `drm-keys.py` 里还有几处**过时注释**
  仍在说 `kscreen-doctor` 是 DPMS 机制（实际已改成 `drmbl`）
- `display/keepbright.sh` 的 sysfs/`bl_power` 理由对 opd2511 是**错的**，不要让它和 `drmbl` 抢
- `core/device/` 里 `generic.sh:51` / `opd2413.sh:50` / `piano.sh:54` 还有 `--no-lockscreen`
- 上游有、我们没有的：`ade/*`、`audio/*`、`gpu/*`、`input/{99-drm-pogo-input.rules,
  drm-pogo-fixup,drm-powerkey.py,drm-touchpad-guard.sh,input-node-sync.sh,
  libinput-touchpanel.quirks,src/*}`、`network/*`、`display/{kwin_wayland-wrapper.sh,src/*.c}`
- KWin 日志里 `fd_acc_get_query_result … BO stalled`（269 次）→ 可试 `KWIN_NO_TIMER_QUERY=1`
- KWin 日志里 `failed to import dmabuf`（18 次，和 Chrome 相关）→ 可试 `KWIN_DRM_USE_MODIFIERS=0`
- 任务栏出现「未知应用程序文件夹」（`org.kde.plasma.folder` / `org.kde.plasma.icontasks`）
- `ksystemstats_plugin_kgslgpu.so` 没接上
- **重复的 `plasmashell` 进程**（未解决）
- 容器和 `/usr/local/bin` 里有一堆本次实验留下的脚本垃圾（`c_*.sh`、`blz*.sh`、`pdt*.sh`），
  以及 `/root/` 下几十个 `.ppm` 帧缓冲转储（每个 19 MB），建议清理

---

## 5. 🔴 红线（绝对不要做）

### 5.1 通用

- **绝不要碰 `/data/a2lrootfs`**
- **绝不要用 `bind_mounts=`**
- **回复用中文**
- **回安卓只能走整机重启**（`/system/bin/reboot`，由安卓侧守护执行），不要原地恢复
- **黑屏红线：绝不要把面板弄成永久砖**（兜底恢复 = 长按电源键）
- **调试原则：定位根因，不要绕过它**
- Droidspaces 前端**不要**自动挂载 card0 / input

### 5.2 网络

- 绝不 `ip link set wlan0 up/down`
- 绝不 `ip rule flush`
- 绝不删 netd 的 rule/table（只能加）
- 绝不用 `ip route show default` 当健康检查
- 绝不把 `net_mode` 改成非 `host`
- 绝不改 `container.config`、绝不重启容器
- 绝不写 `persist.*` / `settings`

### 5.3 蓝牙

- bridge **只能在 `init.svc.surfaceflinger = stopped` 时存活**
- 退出用 `pkill -x bthci-bridge`（**`-x` 必须**）
- 绝不手动驱动 BT power ioctl
- 绝不写 `/sys/class/rfkill/rfkill0`
- 绝不碰 BtTpi
- 绝不 `setenforce 0`
- 不做 systemd / KernelSU 自启
- 如果安卓的 `/dev/snd/*` 被删了，**不要手工 `mknod`**，
  用 `echo add > /sys/class/sound/<node>/uevent`

### 5.4 锁屏测试

- 调 `Lock()` 之前**永远先设好兜底**
- **绝不**让 `kscreenlocker_greet` 无人值守地跑着
- 优先用受管的 `run_in_background` 作业，或手工 `pkill -9 -f kscreenlocker_greet`

### 5.5 显示

- **绝不退回 8-bit**（帧缓冲必须是 AR30）
- **不要**去追 `actual_brightness=0`（那个 sysfs 节点是装饰性的）
- **`WL_DISPLAY=taketest` 是必须的**（KWin 的 socket 就叫 `/run/user/1000/taketest`，
  **没有 `wayland-` 前缀**）
- `drmbl` **必须以 root 跑**

---

## 6. 显示与亮度：实测出来的模型（不要再猜）

### 6.1 唯一真正有效的亮度控制

connector 属性 **`brightness`（prop 82，flags `0x02`，范围 [0..4095]，基线 2048）**
是**唯一**活的控制点：

```
set 4095  →  用户：「明显变亮了」
set 0     →  用户：「很暗但看得见」
阶梯 4095 → 2048 → 200 → 0 → 用户：「亮 中 很暗 好像没看见最暗」
```

### 6.2 装饰性的东西（别在上面浪费时间）

- `/sys/class/backlight/panel0-backlight` 的 `actual_brightness` **永远是 0**，
  `type=raw`。dmesg 里**每一次**调用（包括成功的）都会打
  `[msm-dsi-info]: bypass bl 0` —— 那是 debug print，**不是失败**。
- 单独试过**全都无效**：`bl_scale=0`、`sv_bl_scale=0`、`dimming_min_bl=4095`、
  `dimming_dyn_ctrl=1`、`LP=1`、`EPT=1`、`autorefresh=6`、`link-status=1`、
  `dim_layer_v1`（0 / 255 / 65535 / 0xFFFFFFFF —— 用户：「完全没变化」）

### 6.3 `bypass` 卡死状态

`brightness` 写下去**报成功但读回是 0** —— 这是 `bypass` 卡住了。
**只有 KWin 重启能可靠清掉它。**

### 6.4 外部写面板电源的已知副作用

任何绕过 KWin 的面板电源写入都会让 KWin 的内部状态发散。
恢复流程：

```sh
sh display/kwin-restart.sh
# 然后手工：
pkill -9 -f plasmashell
systemctl --user start kactivitymanagerd
plasmashell --replace &
systemctl --user start plasma-powerdevil.service
```

（`drm_start_desktop` 自己会失败并报 `ERROR PLASMA-FAIL：plasmashell 15s 内没起来`）

---

## 7. 工具与调试方法

### 7.1 `drmbl`（`tools/runtime/drmbl.c`，1025 行，零警告）

子命令：

```
show                          当前 connector 亮度 + DPMS
set <0..4095>                 写 brightness
blank / unblank               熄/亮（blank 拒绝把 0 存成原亮度）
dpms on|off                   connector DPMS（KWin 那边会 EINVAL，谨慎）
props                         列 connector 全部属性
prop <name> <value>           写 connector 属性
probe                         自证：借 master fd 并回写当前值
planes [all]                  列每个 plane 的 crtc/fb/dst/src/zpos
crtcprops                     列 CRTC 全部属性
crtcprop <name> <value>       写 CRTC 属性
crtc-off / crtc-on            ★ 正式的面板电源路径
```

- master fd 是从 `kwin_wayland` **借**的（`pidfd_getfd`，实测是 **fd 17**；
  kwinwrap 的 fd 250 已经被 `DRM_DROP_MASTER` 了，不能用）。
  候选列表 `CAND_COMMS[] = { "kwin_wayland", "kwinwrap", NULL }`，
  用「把当前值写回去」做自赋值探针确认。
- 环境变量：`DRMBL_CONN`、`DRMBL_VERBOSE`、`DRMBL_DEFAULT_BL`（2048）
- 状态文件：`/run/drmbl.saved`、`/run/drmbl.crtc`

**★ blob 生命周期铁律**：任何短命进程创建的 DRM property blob 都会随它一起失效，
**绝不要指望 blob id 跨 `drmbl` 调用存活**。

### 7.2 帧缓冲导出（本次用来证明"噪声不在渲染里"）

```sh
cd /root/droid-drm-takeover/bin
FB=$(/usr/local/bin/drmbl planes | awk '/plane 131/{for(i=1;i<=NF;i++) if($i ~ /^fb=/){sub("fb=","",$i); print $i; exit}}')
./fbdump /dev/dri/card0 "$FB" /root/shot.ppm     # 必须带 card + fb_id + 输出路径
./fbinfo /dev/dri/card0 "$FB"
```

`fbdump` 的参数是 `<card> <fb_id> [输出路径]`，默认写 `/tmp/fb.ppm`。
（`fbdump` 的源码**不在** `tools/runtime` 里，只有二进制，是上游带的。）

### 7.3 编译 `drmbl` / `kwinwrap`

容器里**没有** gcc / pkg-config / libdrm 头文件。用 WSL：

```powershell
wsl -u root -e bash -c "aarch64-linux-gnu-gcc -O2 -g -Wall -Wno-unused-parameter \
  -I/usr/include/libdrm -L/usr/lib/aarch64-linux-gnu -ldrm -o /tmp/drmbl drmbl.c"
```

WSL Ubuntu 的 `aarch64-linux-gnu-gcc` 是 13.3.0，libdrm 头在 `/usr/include/libdrm`。

**坑**：不要把 gcc 输出 pipe 给 `head` —— SIGPIPE 会静默杀掉编译。
重定向到文件再读。

### 7.4 在容器里执行命令

```powershell
$adb='C:\Program Files (x86)\platform-tools\adb.exe'
$RF='/data/local/Droidspaces/Containers/DEBIAN/rootfs'
$DS='/data/local/Droidspaces/bin/droidspaces'
# 1) 推到安卓侧
& $adb push .\x.sh /data/local/tmp/x.sh
# 2) 拷进容器 rootfs
& $adb shell "su -c 'cp -f /data/local/tmp/x.sh $RF/root/x.sh'"
# 3) 在容器里跑
& $adb shell "su -c '$DS --name=DEBIAN run `"sh /root/x.sh`"'"
```

**★ 绝不要把复合命令（`;` / `|` / 通配符）放进 `droidspaces run "…"`** ——
它们会在**两边都**执行。永远写脚本文件 → 推 → 执行。

**★ 容器里的 `sh` 是 dash**，没有 bash 的进程替换。

### 7.5 标准 `runuser` 咒语

```sh
runuser -u Gold -- env HOME=/home/Gold \
  XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland \
  WAYLAND_DISPLAY=taketest QT_QPA_PLATFORM=wayland \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  <cmd>
```

### 7.6 日志

在 `$RF/root/droid-drm-takeover-logs/`：

```
kwin.log          kwinatomic.log ★（KWINWRAP_TRACE 的输出在这里，不在 kwin.log）
plasma.log        plasmashell.log      journal.log
kwin-restart.sh.log  connprops.log     crtcstate.log
keepbright.log（0 B）  chrome.log      wayland-info.log
kactivitymanagerd.log  kded6.log
```

**★ `journalctl --user` 在容器里读不到东西**（"No journal files were found"），
所以**不要靠 journal 排查 PowerDevil** —— 手动跑它并抓 stderr。
（本次已经把 Gold 加进 `systemd-journal` 和 `adm` 组，但 journal 本身不是持久的。）

---

## 8. 关键路径与环境变量

### 8.1 路径

```
DS   = /data/local/Droidspaces/bin/droidspaces
RF   = /data/local/Droidspaces/Containers/DEBIAN/rootfs
仓库  = $RF/root/droid-drm-takeover          （容器内）
日志  = $RF/root/droid-drm-takeover-logs/
lib   = $RF/usr/local/lib/droid-drm-takeover/
会合  = /var/lib/droid-drm-takeover          （drwxrwxrwt 1777）
adb  = C:\Program Files (x86)\platform-tools\adb.exe
```

容器是 **Debian 13 (trixie) arm64**，sudo 密码 `1234`。

### 8.2 KWin 的实际环境（`/proc/<pid>/environ`）

```
MESA_LOADER_DRIVER_OVERRIDE=msm
DRM_DEVICE=opd2511
QT_QPA_PLATFORM=wayland
KWINWRAP_HIJACK=1  KWINWRAP_FILTER=1  KWINWRAP_SECCOMP=1
KWINWRAP_UID=1000  KWINWRAP_GID=1000  KWINWRAP_USER=Gold
KWINWRAP_GROUPS=1000,5,27,42,44,996,1023,3003,3004,786
KWINWRAP_BRIGHTNESS=2048
KWINWRAP_SPLIT_CONN=67  KWINWRAP_SPLIT_CRTC=200
KWINWRAP_SPLIT_W=800  KWINWRAP_SPLIT_W_FULL=3200  KWINWRAP_SPLIT_H=2000
KWINWRAP_SPLIT_PLANES=131  KWINWRAP_SPLIT_DST_INTERLEAVE=0  KWINWRAP_SPLIT_ZPOS=5
QT_IM_MODULES=qtvirtualkeyboard
QT_LOGGING_RULES=kwin_scene_opengl.debug=true;kwin_drm.debug=true
KWIN_DRM_DEVICES=/dev/dri/card0
KWIN_WAYLAND_NO_PERMISSION_CHECKS=1
DRM_MODE_KEEP_HZ=144
LD_PRELOAD=drmfmt.so:touchabs.so
TOUCHABS_X_MIN=20000  TOUCHABS_X_MAX=40000
LANG=en_US.UTF-8  LC_ALL=zh_CN.UTF-8
```

**没有 `KWINWRAP_DPMS_INJECT`。`KWINWRAP_TRACE` 现在是未设置（默认关）。**

KWin 命令行：`kwin_wayland --drm --socket=taketest --xwayland`

### 8.3 Gold 身份

```
uid=1000(Gold) gid=1000(Gold)
groups=1000(Gold),5(tty),27(sudo),42(shadow),44(video),996(input),
       1023(ntfsusb),3003(aid_inet),3004(aid_net_raw),786(droidspaces-gpu),
       adm,systemd-journal
```

（`42(shadow)` 是必须的：rootfs 是 **nosuid**，`unix_chkpwd` 只有 setgid 位，
不在 shadow 组就没法给 `kscreenlocker_greet` 验密码。）

---

## 9. 推送代码到 GitHub（`git push` 走不通）

**`git push` 在 TLS 层被网络拦掉**，所有 SSL backend / HTTP 版本组合都失败：

```
schannel: failed to receive handshake, SSL/TLS connection failed
TLS connect error: error:0A000126:SSL routines::unexpected eof while reading
```

**必须走 GitHub REST API**。脚本：`C:\Users\bai\Downloads\drm\probe\push-api.ps1`

流程：`GET ref` → `GET commit` → 对每个改动文件 `POST /git/blobs`（base64）
→ `POST /git/trees`（带 `base_tree`）→ `POST /git/commits` → `PATCH /git/refs/heads/main`

**★ 踩过的两个坑，务必注意**：

1. **`cmd /c "git cat-file …"` 不继承工作目录** —— 曾经因此把 **22 个 blob 全写成 0 字节**
   并且推送成功。现在脚本里所有 git 调用都显式带 `-C $WORK`，
   而且**推之前检查每个 blob 非空、推之后逐个回读远端校验非空**。
2. **`$args` 是 PowerShell 的自动变量** —— 拿它当函数参数名会被吞掉，
   导致 `git` 收到空参数、打印 help 文本。用 `$argline` 之类别的名字。

其他 PowerShell 注意事项：

- `Invoke-RestMethod -Body <string>` 会用 Latin-1 编码，**会毁掉中文** ⇒
  必须传 `[System.Text.Encoding]::UTF8.GetBytes($json)`
- `ConvertTo-Json` 会把单元素数组解包 ⇒ 手搓 JSON
- Windows PowerShell 5.1 按 ANSI 读 `.ps1` ⇒ 推送脚本保持**纯 ASCII**
- `git diff --name-only` 会把非 ASCII 路径转义成八进制 ⇒ 用 `-c core.quotepath=false`
- PowerShell 脚本执行被拦 ⇒ `powershell -NoProfile -ExecutionPolicy Bypass -File <path>`
  （`pwsh` 不在 PATH 上）
- `raw.githubusercontent.com` **不可达**；`api.github.com` 和 `github.com` 可达
- Token：`[Environment]::GetEnvironmentVariable('GITHUB_PAT_TOKEN','User')`（长度 93）

---

## 10. 建议的下一步（优先级排序）

1. **整机重启一次，把 4 条横纹清掉**（走桌面「返回安卓」图标或 `display/drm-stop.sh`）。
   重启后如果横纹还在，按 §4.1 末尾列的方向查 DSC。
2. **让用户点一次「保存 WiFi 密码」**，然后 `wifi-save-password --check` 确认落盘。
   想彻底修的话，去查 `kwalletd6` 为什么 SIGABRT
   （怀疑 `kwallet6` 包里缺 backend 插件）。
3. **验证亮度面板真的在托盘里出现了**，并确认自动亮度能跟着环境光变化。
4. **声音**：按 P1 路线推进 AGM `set_config(48000/2ch/16bit)` → `prepare` → `start` → `write`。
   这是唯一能让 `pcm_write` 不再 EINVAL 的路。
5. **电源键熄面板**：现在的痛点是 `crtc-on` 唤醒会破坏左侧 DSI 链路。
   建议去查 `sde_encoder` 的双 DSI 使能顺序，或者试 `dpms` + `crtc` 的组合顺序。
6. **修 Qt 虚拟键盘的焦点 bug**（§4.4 第一条）。
7. **清理实验垃圾**（容器 `/root/*.ppm`、`/root/c_*.sh`、`/usr/local/bin/blz*.sh` 等）。

---

## 11. 参考文档

仓库内 `work/docs/`：

```
架构.md                              适配新设备.md
环境变量污染-掉帧与拖影.md            故障排查.md
亮度-PowerDevil与自动亮度.md          ★ 本次相关
2026-10-12-WiFi图形面板与Chrome与键盘.md
掉帧-sycoca无限重建.md               键盘一闪一闪-输入法冲突.md
音频-本机HIDL路线与上游A路不可移植.md
音频根因更正-AGM是用户态.md          音频诊断-2026-10-12.md
```

**蓝牙**（§3.4 的完整版在这里，本文档只是摘要）：

```
work/bt/README.md            310 行，架构 + 4 条验收 + 全部踩坑 + 红线 + 已知边界
work/bt/HIDL-探针结论.md       HIDL/AIDL 选型与回调节点的反汇编依据
work/bt/bthci-bridge.cpp      桥本体
work/bt/h4framing.h/.cpp       H4 分包（纯函数，可宿主机单测，21 条断言）
work/bt/build.sh              NDK 交叉编译（CI 的 btbridge job 用同一个脚本）
work/bt/bt-bridge-up.sh       设备侧：起桥 + 4 条端到端验收 + 收桥
work/bt/deploy.sh             主机侧：构建 → push → 跑验收
```

仓库内 `work/network/README.md`
上一份交接：`C:\Users\bai\Downloads\drm\HANDOFF.md`

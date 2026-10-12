# 亮度：为什么原来调不了，现在怎么调的；以及自动亮度到底有没有

设备：Lenovo TB710FU（SM8650 / 双 DSI + DSC 面板 3200×2000）
容器：Droidspaces / Debian 13 trixie arm64 / KDE Plasma 6.3.6 / KWin 6.3.6 (Wayland)
日期：2026-10-12

---

## 一、结论

### 1. 亮度现在能调了，而且走的是**真背光**（不是软件调光）

链路：

```
KDE 亮度滑块 / Fn 亮度键 / 托盘图标
   ↓  (会话总线)
org.kde.Solid.PowerManagement  (plasma-powerdevil)
   ↓  KWinDisplayDetector → KScreen Output::setBrightness()
kwin_wayland  (DSI-1 的 brightness 属性)
   ↓  DrmOutput::updateBrightness() → BrightnessDevice::setBrightness()
kde_external_brightness_v1  (ExternalBrightnessDeviceV1)
   ↓  (系统总线, KAuth)
org.kde.powerdevil.backlighthelper  (root)
   ↓
/sys/class/backlight/panel0-backlight/brightness
```

实测自证（每一步都读过回值，见第四节）：

| PowerDevil 值 (0–10000) | sysfs 读回 (0–4095) | 公式 `round(1+4094·kde/10000)` |
|---|---|---|
| 512  | 211  | 210.6 |
| 1024 | 420  | 420.2 |
| 3072 | 1259 | 1258.7 |
| 4095 | 1677 | 1677.5 |
| 5001 | 2048 | 2048.4 |
| 10000 | 4095 | 4095 |

⇒ 全落在公式上，说明链路是真的接到了 sysfs，不是 KWin 的软件调光。

### 2. 原来调不了，是**三个互相独立的断点**叠在一起

| # | 断点 | 一句话原因 |
|---|---|---|
| ① | `plasma-powerdevil.service` 从来没启动 | 它是 `static`，靠 `graphical-session.target` 拉起；而本项目绕过 `startplasma-wayland` 手工起 KWin ⇒ 那个 target 从没激活 |
| ② | 手工拉起会 SIGABRT | `systemd --user` 环境里没有 `WAYLAND_DISPLAY`（同样是绕过 startplasma 的后果），PowerDevil 是 Qt Wayland 客户端，直接 abort |
| ③ | 就算起来了，背光探测器也永远失败 | 容器 rootfs 是 **nosuid** ⇒ setuid 的 `dbus-daemon-launch-helper` 失效 ⇒ 任何 `User=` 的 D-Bus system service 都激活不了，包括 KAuth 的 `backlighthelper` |

### 3. 自动亮度：**本设备没有环境光传感器**，做不了

不是"没接进 KDE"，是**硬件/内核层面就没有这个数据源**。证据见第五节。
不要硬造 —— 用摄像头/时间表猜亮度只会更糟。

---

## 二、断点 ① 的完整依赖链

```
plasma-powerdevil.service   (Loaded: static; Active: inactive)
   ↑ 靠什么被拉起
graphical-session.target    (inactive)
   ↑ 由谁启动
plasma-workspace.target / plasma-core.target   (inactive)
   ↑ 由谁启动
startplasma-wayland         (从没跑过)
   ↑ 本项目实际怎么起的桌面
core/lib/display.sh → kwin_wayland --drm --socket=taketest --no-lockscreen --xwayland
```

实测：

```
$ systemctl --user is-active plasma-powerdevil.service
inactive
$ systemctl --user is-system-running
degraded
$ systemctl --user list-units --type=target --state=active
# 只有 basic.target / default.target / sockets.target / timers.target / paths.target
# 没有 graphical-session.target，也没有 plasma-*.target
```

⇒ **正统做法是补 `graphical-session.target` 的拉起方式**（用户原话），
`display/powerdevil-enable.sh` 走的就是这条：不自己发明新机制，只是把
上游那条 `graphical-session.target → plasma-powerdevil.service` 的**缺失环境**
补上，然后显式 `start` 它。

> 之所以不直接去 `systemctl --user start graphical-session.target`：
> 那个 target 一旦激活，会顺着 `Wants=` 把 plasmashell / kded / kscreen 等
> **一整套**再拉一遍，而本项目的 plasmashell 是手工起的、且用户正在用。
> 重复拉起会把桌面的状态搅乱。所以只补 PowerDevil 这一个 unit 需要的两样东西
> （Wayland 环境 + KAuth 助手），不动别的。

---

## 三、断点 ②：SIGABRT 的原文

```
$ systemctl --user start plasma-powerdevil.service
Job for plasma-powerdevil.service failed because a fatal signal was delivered.
code=killed, signal=ABRT

$ journalctl --user -u plasma-powerdevil
Failed to create wl_display (No such file or directory)
qt.qpa.plugin: Could not load the Qt platform plugin "wayland" in ""
   even though it was found.
This application failed to start because no Qt platform plugin could be initialized.
```

对照实验（同一个二进制，只补环境）：

```
$ runuser -u Gold -- env XDG_RUNTIME_DIR=/run/user/1000 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
      WAYLAND_DISPLAY=taketest QT_QPA_PLATFORM=wayland \
      /usr/lib/aarch64-linux-gnu/libexec/org_kde_powerdevil
# 一直活着，只有 timeout 能杀掉它
```

⇒ 原因确定是缺 `WAYLAND_DISPLAY`，不是别的。

> ★ socket 名是 **`taketest`**，不是 `wayland-0` —— KWin 是
> `--socket=taketest` 起的。`/run/user/1000/wayland-0` 是个残留死 socket，
> 写死它同样会 abort。

---

## 四、断点 ③：KAuth / nosuid

### 报错原文

```
org.kde.powerdevil: org.kde.powerdevil.backlighthelper.brightness failed
org.kde.powerdevil: org.kde.powerdevil.chargethresholdhelper.getthreshold failed
  "DBus Backend error: service start org.kde.powerdevil.chargethresholdhelper failed:
   The permission of the setuid helper is not correct"
```

### 根因（**不是** helper 自己的权限）

```
$ ls -l /usr/lib/dbus-1.0/dbus-daemon-launch-helper
-rwsr-xr--. 1 root messagebus ...     ← setuid 位**在**

$ ls -l /usr/lib/kf6/kauth/libexec/backlighthelper
-rwxr-xr-x. 1 root root ...           ← 这个本来就不需要 setuid
      （/usr/share/dbus-1/system-services/org.kde.powerdevil.backlighthelper.service
        里是 `User=root`，由 dbus-daemon 提权拉起）
```

但容器 rootfs 是 **nosuid** 挂载的，`-rws` 的 setuid 位**不生效**：

```
$ mount | grep ' / '
... nosuid ...
```

⇒ `dbus-daemon`（以 `messagebus` 身份跑）无法通过 launch-helper 提权到 root，
于是**任何**带 `User=` 的 D-Bus system service 都起不来。
受影响的正是 KAuth 那三个 helper：`backlighthelper` / `chargethresholdhelper` /
`discretegpuhelper`。

### 修法（display/powerdevil-backlight-helper.service）

让 systemd（PID 1，本来就是 root）**常驻**把 helper 拉起来。helper 自己抢到
总线名之后，dbus-daemon 就不需要走 launch-helper 了。

```
$ busctl --system list | grep backlight
org.kde.powerdevil.backlighthelper   2262 backlighthelper root  :1.214  droidspaces-backlight-helper.service
```

### ★ 为什么"屏幕列表"不会因此多出一项（重要，避免双滑块）

这是上游设计（`daemon/controllers/screenbrightnesscontroller.cpp`）：

```cpp
const bool shouldUseExternalControl =
    m_externalBrightnessController->isActive()
    && !dynamic_cast<KWinDisplayDetector *>(detector);
```

非 KWin 的探测器（`BacklightDetector`）探测到的屏**不**进 `m_displaysById`，
而是通过 `kde_external_brightness_v1` 导出给 KWin，由 KWin 当作 DSI-1
自己的亮度设备（`src/core/brightnessdevice.h`）。

实测：`DisplaysDBusNames` 始终是 `as 1 "display0"`，`display0` 的
`Label="Built-in Screen"`、`MaxBrightness=10000`（= KWin 侧量程）。

### ★ 排除掉的假设：为什么不用 `kscreen-doctor output.DSI-1.brightness.N`

因为那条路是 **KWin 的软件调光**，不是背光：

```
$ kscreen-doctor output.DSI-1.brightness.50
$ cat /sys/class/backlight/panel0-backlight/brightness
2048          ← 一点没动
```

KWin 在 `m_brightnessDevice == nullptr` 且 `allowSdrSoftwareBrightness` 时，
走的是合成管线里的 `brightnessFactor`（`drm_output.cpp`），只改像素，不改背光。
**而且** `kscreen-doctor` 的 brightness 只收 0–100 的**整数百分比**
（`Allowed range for brightness is 0 to 100`），小数会被截断成 0 ——
本次排查中我踩过这个坑，把 `0.2048` 写成了 `0`（见第六节复盘）。

---

## 五、自动亮度：本设备**没有**环境光传感器

### 5.1 设备树里没有

```
$ find /sys/firmware/devicetree/base -iname '*light*' -o -iname '*als*' \
      -o -iname '*tmd*' -o -iname '*ltr*'
（只有 csiphy*/rgltr-* 这类误命中，没有 ALS 节点）

$ grep -i 'light\|als' probe/kern_sm8650-lenovo-tb710fu.dts
（无）
```

DTS 里 i2c 上只有：`sy7758` 背光主/从、`aw37504` LCD bias、`aw882xx` smartpa、
`sn-nci` NFC、`wcd939x` codec、`rtc6226`、PMIC。**没有光感。**

### 5.2 内核 i2c / iio 里没有

```
$ for d in /sys/bus/i2c/devices/*/name; do echo "$d: $(cat $d)"; done
1-0034 aw882xx_smartpa      5-000e wcd939x-i2c
1-0035 aw882xx_smartpa      6-002e sy7758-i2c-master
1-0036 aw882xx_smartpa      6-003e aw37504-i2c
1-0037 aw882xx_smartpa      6-0064 rtc6226
3-0028 sn-nci               8-003b/0068/0069 i2c-pmic
4-002e sy7758-i2c-salve
（没有 tmd2755 / sx932x / cm36xxx / stk3xxx 之类的光感/接近）

$ ls /sys/bus/iio/devices/; for d in /sys/bus/iio/devices/*/name; do cat $d; done
iio:device0  qcom,pmk8550@0:vadc@9000      ← PMIC ADC（温度/电压）
iio:device1  qcom,pmic_glink_log:qcom,glink-adc
（没有 als / illuminance 通道）
```

### 5.3 Android 侧也没有

QTI sensor HAL 是在跑的：

```
$ ps -A | grep -i -E 'sensor|sns'
system 1941 android.hardware.sensors-service.multihal
system 2047 vendor.qti.hardware.sensorscalibrate-service
system 2153 qsap_sensors
system 2159 sensors.qti

$ dumpsys android.hardware.sensors.ISensors/default
# of non-dynamic sensors across all subhals: 32
SubHals (2): QTI-SubHAL, Dynamic-SubHAL
```

但是：

```
$ grep -a -i -c 'als' /vendor/etc/sensors/sns_reg_config
0
```

⇒ 传感器的注册表里**一个 als 条目都没有**。

> ⚠️ 容易误判的一点：`/vendor/etc/sensors/config/` 下面**确实有**
> `palawan_tmd2755_0.json`（tmd2755 是 ams 的光感/接近芯片），
> 以及 `palawan_sx932x_*`（SAR）。但那些是 vendor 镜像给**参考平台
> （palawan = SM8650 MTP）**带的通用配置文件，文件头写着
> `"hw_platform": ["MTP","Surf","RCM","HDK"]`，**不等于**本机有这些芯片。
> 判据只能是"i2c 上有没有枚举到" + "sns_reg_config 里有没有注册" —— 两条都是否。

> 另一个坑：`dumpsys sensorservice` 在本机报 `Can't find service: sensorservice`
> （system_server 的 services 没注册全，`settings` 也一样）。
> 别把"dumpsys 报错"当成"没有传感器"—— 要问 vendor HAL
> （`dumpsys android.hardware.sensors.ISensors/default`），那个是通的。

### 5.4 结论

**本设备拿不到环境光数据。** 如果以后要做"自动亮度"，只能：
* 外接 USB 光感（能进 iio 的那种），再写一个把 illuminance 喂给
  `org.kde.ScreenBrightness` 的小守护；或
* 用时间表（白天/夜晚）近似 —— 但那是"定时"，不是"自动亮度"，别混称。

---

## 六、改动清单

| 文件 | 作用 |
|---|---|
| `display/powerdevil-backlight-helper.service` | 修断点 ③：systemd 常驻拉起 KAuth 背光助手 |
| `display/powerdevil-wayland-env.conf` | 修断点 ②：给 `systemd --user` 的 PowerDevil 补 `WAYLAND_DISPLAY` 等 |
| `display/powerdevilrc` | 关掉 PowerDevil 的空闲变暗/熄屏（**新引入的副作用**，见下） |
| `display/powerdevil-enable.sh` | 一键安装 + 自证 + `--revert` |
| `display/brightness.sh` | 两条刻度（sysfs 0–4095 ↔ KDE 0–10000）的换算与调光 CLI |
| `display/keepbright.sh` | 改：PowerDevil 在管背光时**不再钉 brightness**，只钉 `bl_power` |

### ⚠️ 关于"关掉空闲熄屏"：这是让 PowerDevil 跑起来**新引入**的行为

PowerDevil 没跑的时候，桌面上没有任何东西会按空闲时间熄屏。它一跑起来，
默认策略就是空闲 5 分钟变暗、10 分钟熄屏。

实测 A/B（判据：`sysfs == 1` 只可能来自 PowerDevil，因为
`ExternalBrightnessDeviceV1` 对内置屏 `minBrightness = 1`，写 0 会被 clamp 成 1；
而另一个会写背光的 `input/drm-keys.py` 只写 0 或 2048）：

```
正对照 [AC][Display] TurnOffDisplayWhenIdle=true / ...Sec=30
  t=45s brightness=2048
  t=50s brightness=1800      ← KWin 开始淡出
  t=55s brightness=1         ← PowerDevil 打到最低，稳定保持
  ...  t=75s brightness=1
  t=80s brightness=2048      ← 被唤醒

本仓库配置 TurnOffDisplayWhenIdle=false / DimDisplayWhenIdle=false
  t=5s … t=125s brightness=2048   ← 全程没有出现 1
  t=130s…t=165s brightness=0      ← 这是用户按了电源键（drm-keys），属预期
  t=170s…t=180s brightness=2048
```

> ⚠️ 判据的**边界**（后来才搞清楚，记下来免得误判）：
> `sysfs == 1` 还有两个来源 —— **PowerDevil 的唤醒淡入**，以及
> **电源键熄屏时的 clamp**。所以只看"是不是 1"是不够的：
>
> | 现象 | 含义 |
> |---|---|
> | `1` **稳定保持**几十秒，且 `screenoff=0` | 空闲熄屏 ← 要关掉的就是它 |
> | `1` 一闪而过（下一拍回原值） | PowerDevil 唤醒淡入，正常 |
> | `1` 且 `screenoff=1` | 电源键熄屏；drm-keys 写的 0 被 KWin clamp 成 1 |
>
> 淡入的证据（PowerDevil 日志，全程约 1 秒）：
> ```
> [BacklightBrightness]: Udev device changed brightness to: 161 … 195 … 232 …
>                       474 … 598 … 737 … 892 … 976 … 1064 … 1352 … 1679 …
>                       1918 … 2044 … 2048
> [BacklightBrightness]: External brightness change observed: 2048 / 4095
> ```
>
> ⇒ 于是做了**第二轮 A/B**，把 `screenoff` 一起记下来当过滤器：
>
> ```
> 阶段1 正对照 TurnOffDisplayWhenIdle=true / 30s（每 3s 采样，共 120s）
>   23:35:30 … 23:36:33  sysfs=2048 screenoff=0
>   23:36:36 … 23:36:39  sysfs=0    screenoff=0    ← 淡出
>   23:36:42 … 23:37:16  sysfs=1501 screenoff=0    ← 被唤醒，回到用户亮度
>   23:37:19             sysfs=1    screenoff=0    ← ★ PowerDevil 自己打黑
>   23:37:22 … 23:37:28  sysfs=0    screenoff=0
>   ⇒ 命中 1 次
>
> 阶段2 最终配置 TurnOffDisplayWhenIdle=false（每 3s 采样，共 120s）
>   全程只有 sysfs=2048 / 1501 / 0，以及 screenoff=1 的那段（电源键）
>   ⇒ 命中 0 次
> ```
>
> 这一轮 `systemctl --user restart` 其实是**失败**的（脚本以 root 跑，
> `systemctl --user` 连不上会话总线：`Failed to connect to user scope bus
> via local transport: Operation not permitted`）。也就是说两个阶段都没有
> 重启 PowerDevil —— 行为变化**只**来自 powerdevilrc 的内容变化
> （PowerDevil 用 KConfigWatcher 监听这个文件）。⇒ 反而更干净：
> A/B 的变量只有那一个配置项。

配合上游源码语义（`daemon/actions/bundled/dpms.cpp`）：

```cpp
if (!profileSettings.turnOffDisplayWhenIdle() || m_idleTimeoutWhenUnlocked < 0ms) {
    onProfileUnload();
    return false;            // ← 根本不注册空闲定时器
}
```

⇒ `WhenIdle=false` 是**彻底不注册**，不是"注册一个很大的超时"。

**要恢复上游默认**：删掉 `~/.config/powerdevilrc` 里的 `[AC][Display]` 等段
（或把值改回 `true`），然后
`systemctl --user restart plasma-powerdevil.service`。

### 组名/键名是怎么确定的（别凭印象改）

* 键名从二进制里的 KConfigXT 符号挖出来：
  `TurnOffDisplayWhenIdle` / `TurnOffDisplayIdleTimeoutSec` /
  `DimDisplayWhenIdle` / `DimDisplayIdleTimeoutSec` /
  `LockBeforeTurnOffDisplay` / `TurnOffDisplayIdleTimeoutWhenLockedSec`
  ```
  $ grep -a -o -E '[A-Za-z]{0,30}(TurnOffDisplay|DimDisplay)[A-Za-z]{0,30}' \
        /usr/lib/aarch64-linux-gnu/libpowerdevilcore.so.6.3.6 | sort -u
  ```
* 组名 `[<profile>][Display]`：PowerDevil 自己报当前 profile 是 `AC`
  ```
  $ busctl --user call org.kde.Solid.PowerManagement \
      /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement currentProfile
  s "AC"
  ```
  且把正对照写进 `[AC][Display]` 后行为立刻改变 ⇒ 组名正确。

---

## 七、顺带发现（**不是**这次改动引起的，没动它）

### `input/drm-keys.py` 的 `kscreen-doctor --dpms` 会间歇性 SIGABRT

排查过程中在 `/run/drm-keys.log` 里看到电源键的 DPMS 半截失败：

```
23:21:46 !! 亮屏：dpms on 失败 rc=134
23:21:46 亮屏：dpms on rc=134 背光→2048 | Failed to create wl_display (No such file or directory)
         qt.qpa.plugin: Could not load the Qt platform plugin "wayland" ...
23:26:44 !! 亮屏：dpms on 失败 rc=134
23:30:49 亮屏：dpms on rc=134 背光→2048 | ...
```

**结论：与本仓库这次亮度改动无关**，证据：

* 同一个日志里 **22:52:53 / 22:53:01 / 22:53:49 / 22:53:56** 就有完全一样的
  rc=134（那时我还没碰过这台设备上的任何东西；PowerDevil 是 23:19 之后才起的）。
* 它会**自己恢复**：23:32:39 / 23:32:42 的同一操作 rc=0，全程没有重启 drm-keys。
* `drm-keys.py` 自己的 docstring（`detect_wayland_display()`，文件第 165-185 行）
  已经把这个坑写得清清楚楚，并且已经带了修法。

失败时的现象（该文件第 486-488 行也写了）：**只有背光灭了，显示管线还在扫** ——
也就是本文件反复强调的"黑屏 ≠ 熄屏"。背光那半是成功的，所以屏幕看起来正常，
只有省电/管线那半没做到。

⇒ 没有改 `input/drm-keys.py`。原因：现象是**间歇且自愈**的，机制没能证死
（`Failed to create wl_display` 是 `connect()` 的 ENOENT，意味着那一刻
`WAYLAND_DISPLAY` 没有被传给 `kscreen-doctor`；但 `as_user()` 里
`if WAYLAND_DISPLAY:` 才注入，所以只能是那个模块级全局在那一刻是空的），
而这是**电源键守护**（用户唯一的兜底手段），不该在机制没证死时去动它。

如果要动，最小且可证明正确的改法是给缓存加一次校验（`detect_wayland_display()`
第 187-188 行现在无条件相信缓存的 socket 名）：

```python
    global WAYLAND_DISPLAY
    # 缓存的名字可能已经失效（socket 被重建/删除）——校验一次，别盲信
    if WAYLAND_DISPLAY and os.path.exists(os.path.join(RUNDIR, WAYLAND_DISPLAY)):
        return WAYLAND_DISPLAY
    WAYLAND_DISPLAY = ''
```

**要不要改、什么时候改，请用户定**（改完要重启 drm-keys，那会短暂失去电源键处理）。

---

## 八、复盘：这次排查里我自己踩的坑（写下来免得再犯）

1. **`kscreen-doctor output.DSI-1.brightness.0.5` 把配置写成了 0。**
   它只收整数百分比，`0.5` 被截断成 `0`，于是 `kwinoutputconfig.json` 里
   `"brightness": 0`（软件调光全黑）。而且这个值**用 kscreen-doctor 回不去**
   原来的 `0.2048`。最后是用 PowerDevil 的 `setBrightness 2048` 写回去的
   （PowerDevil 的 KWin 屏量程是 0–10000，2048 → 0.2048）。
   ⇒ **教训：改亮度前先记下原值，并且知道回退用哪条路。**

2. **`sysfs == 0` 一度被我误判成"PowerDevil 把屏幕搞黑了"。**
   实际是用户按了电源键（`input/drm-keys.py` 的熄屏功能，写 0 + DPMS off）。
   `/run/drm-keys.log` 里 22:59–23:11 有几十条"电源键短按 ⇒ 切换熄屏"。
   ⇒ **教训：本机有两个写背光的东西，判据必须能区分它们。**
   区分方法：`1` = PowerDevil（clamp 下限），`0`/`2048` = 电源键。

3. **`systemd --user` 的 `Environment=` 改了 drop-in 之后必须 `daemon-reload`。**
   我漏了一次，于是 `QT_LOGGING_RULES` 没生效，白白多花了一轮去猜
   "为什么 debug 日志不出现"。

4. **`/root` 是 0700，探针脚本放那里 Gold 读不到。**
   要放 `/usr/local/bin/`（world-readable）。

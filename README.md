# Droid DRM Takeover

在安卓设备上直接接管它的 DRM/KMS 显示，让一个**原生 Linux 桌面（KWin + Plasma）跑在平板的真实面板上**——
3200x2000@120、触摸可用、不改内核、**不魔改一行 Mesa**。

设备可以在这两套系统之间来回切换：

| 方向 | 怎么切 | 代价 |
|---|---|---|
| 安卓 → Linux | 打开 **DRM 切换器** APK，点「进入 Linux 桌面」 | 约 20–40 秒 |
| Linux → 安卓 | 桌面里点 **返回安卓** 图标 | **整机重启**（约 60–90 秒） |

> ⚠️ **返回安卓必须整机重启，这不是偷懒。** 详见 [为什么回安卓只能重启](#为什么回安卓只能重启)。
> 长按电源键强重启永远是兜底逃生口。

## 支持的设备

| codename | 机型 | 状态 |
|---|---|---|
| `opd2511` | OnePlus Pad 3（OP6546L1 / SM8650Q / 3200x2000） | **主要目标**，常量已按本机实测填写 |
| `opd2413` | OnePlus Pad 2 Pro（sun / sm8750 / 3392x2400） | 参考实现（上游仓库验证过） |
| `piano` | Xiaomi Pad 8 Pro（3200x2136） | 原仓库目标，保留常量 |
| `generic` | 任意 | 全运行时发现，无设备常量；能用但性能/正确性不保证 |

换设备**不要改代码**，改 `core/device/<codename>.sh` 一个文件。
最短路径见 **[docs/适配新设备.md](docs/适配新设备.md)**。

## 两个应用

### 1. Linux 应用：`drm-switch`

零依赖（POSIX shell + `kdialog`/`zenity` + `.desktop` 菜单项，没有 Python/Qt/GTK）：

```
返回安卓（重启设备）    ← 主操作
查看状态                ← 读状态机，显示当前处于哪个阶段
环境体检                ← 逐项检查 DRM 节点 / 触摸 / 合成器 / 网络
重启桌面                ← 只重启 KWin，秒级恢复，不动安卓
打开日志目录
```

安装：`sudo sh linux/install.sh`（真的会装进应用菜单——上游那个 `.desktop` 从来没被部署过）。
不装也能跑：`sh linux/drm-switch.sh --text`。

### 2. 安卓应用：`DRM 切换器`（APK）

`android/` 下是一个不依赖 Gradle、不依赖 AndroidX 的纯 Java 应用：

- 程序化 UI（无 XML 布局），minSdk 26 / targetSdk 35
- 把整套 payload（`core/`、`linux/`、`display/`、`tools/`、编译好的 `bin/`）打进 `assets/payload/`
- 首次运行解压到 `/data/local/drm-takeover/`，然后用 KernelSU/Magisk 的 `su` 驱动
  （**不是** `/data/local/tmp` —— 那个目录 `shell` 可写，而脚本以 root 跑，等于开放 root 代码执行）
- 一个前台服务常驻轮询 `/root/.drm-exit-request`，看到就停容器 + 重启整机

构建：`sh android/build.sh`（手工走 `aapt2 → javac → d8 → zipalign → apksigner`）。

## 它解决什么问题

在安卓上跑 Linux 图形（Termux/容器方案）通常只有一条路：把帧**转发**回安卓 SurfaceFlinger 合成上屏
（Anland、Droidspaces 都是这个架构，Droidspaces 甚至刻意剪掉了 card 节点来防止绕过）。

本项目证明了另一条路：**Linux 侧合成器直接从 KMS 手里抢到面板的所有权**，安卓整套图形栈原地退场，
帧路径零拷贝零转发，延迟只取决于 KMS 提交本身。

## 核心原理（为什么不需要动 Mesa）

难点从来不在 GPU 用户态驱动，而在**谁能往屏上提交**：

1. **master 的真相** —— `DRM master` 并不在内核或 surfaceflinger 手里，而是被安卓侧
   `vendor.qti.hardware.display.composer` HAL 进程持有。`stop` + 显式
   `setprop ctl.stop vendor.qti.hardware.display.composer`（注意：`stop` 不动 `class hal`，必须点名）
   → master 自然空闲。
   **判据不是 `init.svc` 状态，而是 composer 从 `/proc/*/fd` 的 card0 持有者列表里消失。**
2. **藏了节点而已** —— 厂商只是把 `/dev/dri/card0` 从文件系统里删了，驱动仍在内核里活着。
   主设备号从 sysfs 读出后 `mknod` 重建即可，无需任何驱动改动。
3. **kwinwrap 交接仪式** —— 自制的 setuid 桥（`tools/runtime/kwinwrap.c`）以 root 完成：
   拿 master → **预清理安卓遗留 atomic 状态**（释放它占用的 plane/CRTC、把 connector DPMS 拉回 On）
   → `DROP_MASTER` → `initgroups` + setuid/setgid 降权 → `exec kwin_wayland`。
   之后 kwin 用 **stock GBM + EGL + atomic commit** 驱动面板，全程普通用户权限。
4. **GPU 走现成路** —— `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 让 EGL/drm 拿不到 wl_drm fd 时直接开
   `/dev/kgsl-3d0`。**输出链（card0，KMS）与渲染链（kgsl-3d0，Mesa Freedreno）是两条独立的链**，
   只要输出链拿到 master，渲染链用哪条路都行。

一句话：**把"递交上屏的权力"（master + atomic 状态）从安卓手里合法接过来，渲染链路一个字都不改。**

## 为什么回安卓只能重启

接管时容器启动会破坏安卓 `ueventd` 的 netlink，**停容器 ≠ 恢复**。原地恢复后典型症状：

- 卡开机界面约 1 分钟
- 进系统后不定时重启（watchdog 杀 vendor HAL，SELinux 拒绝 `signal` 到 `oplus_hal_displaypanelfeature`）
- U 盘 / pogo 键盘等热插拔节点永远建不出来

这些都只有整机重启能彻底恢复。所以正常路径是**重启**，
`display/desk-stop.sh` 的原地恢复只作为"你明确接受半死状态"的退路保留，脚本里写清了代价。

重启链路的实现要点（三条，缺一条就静默失效）：

1. Linux 侧 `touch /root/.drm-exit-request`，然后杀 plasmashell/kwin
2. 安卓侧轮询进程**必须先删掉请求文件再停容器**，否则重启后残留的请求会立刻再触发一次
3. 只有 `/system/bin/reboot` 有效 —— `svc power reboot` 和 `setprop sys.powerctl reboot` 都是**静默 no-op**

## 快速开始

```sh
# 1) 编译 aarch64 工具 —— ★ 必须先做，APK 要把 bin/ 打进 payload
#    （需要交叉工具链；也可以直接在目标容器里原生 make）
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
make -j"$(nproc)" CC=aarch64-linux-gnu-gcc
ls bin/          # 应有 24 个 aarch64 产物，其中 bin/kwinwrap 是必需的

# 2) 打 APK（会把 bin/ 一起打进 assets/payload/）
sh android/build.sh

# 3) 装到设备，用「DRM 切换器」进入 Linux
adb install -r android/build/drmswitch.apk
```

> ⚠️ **顺序不能反。** `android/build.sh` 在 `bin/` 不存在时只**警告**、不失败，
> 于是你会得到一个"脚本齐全、但一个二进制都没有"的 APK —— 装上去点「进入 Linux」
> 会在拉起会话那一步失败。构建后确认一下：
>
> ```sh
> unzip -l android/build/drmswitch.apk | grep -c 'assets/payload/bin/'   # 应为 24
> ```

Linux 侧应用（在容器里装）：

```sh
sudo sh linux/install.sh          # 装进应用菜单
sudo sh linux/install.sh --uninstall
```

首次上新设备请先跑取证与试跑，别直接常驻：

```sh
sudo sh display/drm-diag-once.sh                  # 抓 KMS 拓扑
sudo DRM_TRIAL_SECS=150 sh display/drm-takeover.sh  # 试跑 150s 后自动回滚
```

## 目录结构

```
core/
  switch.sh               统一状态机 CLI：enter / exit / rollback / status / doctor / watch
  lib/common.sh           日志、状态文件、超时、锁、脱钩
  lib/device.sh           设备适配加载器
  lib/android.sh          安卓侧操作（本地 sh 或 adb，单出口）
  lib/container.sh        Droidspaces 容器
  lib/display.sh          DRM 节点/触摸节点/udev/合成器/桌面会话
  lib/net.sh              WiFi 接管（尽力而为，绝不连坐）
  lib/enter.sh            ★ 唯一的进入时序，两个前端共用
  device/opd2511.sh       本机常量（已实测）
  device/opd2413.sh       参考设备常量
  device/piano.sh         原仓库目标常量
  device/generic.sh       全运行时发现兜底
linux/
  drm-switch.sh           ★ Linux 应用（零依赖，kdialog/zenity/终端）
  drm-switch.desktop      应用菜单项
  install.sh              安装/卸载（真的写进菜单）
  session-up.sh           容器侧会话拉起（被 enter.sh 调用）
android/
  build.sh                打 APK（无 Gradle）
  app/                    Java 源码 + manifest + 资源
  enter.sh                安卓侧进入包装
  exit-watch.sh           退出请求轮询守护
  boot-install.sh         开机自启安装（KernelSU/Magisk service.d）
display/
  drm-takeover.sh         一次性试跑（带自动回滚保险丝）
  desk-takeover.sh        常驻接管（容器侧入口）
  desk-stop.sh            原地返回安卓（半死状态，慎用）
  drm-stop.sh             兼容入口，转发到 desk-stop.sh
  kwin-restart.sh         只重启 KWin
  keepbright.sh           背光钉住
  dmesg-harvester.sh      周期收割安卓 dmesg
  drm-diag-once.sh        新设备适配取证
tools/
  runtime/                脚本硬依赖的最小集（kwinwrap/setbright/setprop/crtcstate/connprops/atomicspy.so）
  probe/                  设备适配期探针，不参与日常流程
  protocol/               wayland 协议桩（随仓库分发，免 wayland-scanner）
configs/                  desk-wifi.conf.example
docs/                     适配新设备 / 架构 / 故障排查 / 工具手册
Makefile                  make（全部）/ make runtime（最小集）
```

## 踩坑精华（每条都值一天时间）

- **composer 不放 master 就是 `ret=-13 (EACCES)`**：`stop` 不动 `class hal`，必须点名
  `setprop ctl.stop vendor.qti.hardware.display.composer`。判据是 composer 从 `/proc/*/fd`
  的 card0 持有者里消失，**不是** `init.svc` 状态。
- **彻底断网根因**：接管后 SF 停 ~120s，安卓 system_server watchdog 会杀 system_server，init 级联
  SIGKILL wpa_supplicant/netd/zygote → WiFi 掉线且 UI 不可用，只能强重启。对策：接管前解除
  watchdog（`watchdog_timeout`/`nativehang`/`stay_on`）+ wake_lock 钉住。
- **接管与回滚脚本都必须与将被它们杀掉的 GUI 栈脱钩**（`setsid` 后台 + 重试 + `fuser -k` 兜底）。
  我们被这事咬了两次：desk-stop 和 desk-takeover 从桌面终端启动时，杀掉 kwin 的瞬间终端连带
  脚本一起死，安卓又已 stop → 两头全黑。
- **`ip link set wlan0 up` 是红线**：接管后对 wlan0 做 up 会触发
  `cnss: Failed to start MHI err=-110` → `Recovery is already in progress` → `ASSERT 2436`
  → **adbd 死掉 → 黑屏**。只能 add-only，永远不 up。
- **plasmashell 硬依赖 kactivitymanagerd，别赌 dbus 自动激活**：激活超时 → shell 直接
  `Aborting shell load`，现象是"kwin 活着、触摸在收、面板有模式，但整屏纯黑"。必须显式拉起
  kactivitymanagerd（记得给 `QT_QPA_PLATFORM=wayland`）并等 `org.kde.ActivityManager` 上总线。
- **wlroots 系合成器（sway/cage/labwc）在这条路上走不通**：它们依赖
  `VK_EXT_physical_device_drm`，而 KGSL 不提供，所以 KWin 是务实之选。
- **KWin 的 Hardware 白名单只认 i915/amdgpu/nouveau/vmwgfx**，`msm_drm` 会被拒 →
  udev 记录里伪造 `E:DRIVER=vmwgfx`。
- **触摸验证禁旁听**：对触摸节点跑 `getevent` 会触发厂商安全联动直接断网（多次实锤）。
  触摸链路一律只让 kwin 一个读者，用 `bin/touchtest` 打点日志验证。
- **双桌面共享 HOME，全局环境改动必须两边回归**：DRM 桌面的虚拟键盘要求 Qt 直连合成器 text-input，
  为此删了全局 `/etc/environment` 的 `QT_IM_MODULE=fcitx5` —— 结果 anland（帧转发方案）的安卓 IME
  桥恰恰依赖 Qt 走 fcitx5 桥，中文选词后只剩前缀字母。修复 = 在 anland launcher 里**会话级**注入。
- **任务栏打不开应用**：`xdg-desktop-portal` 必须带 `XDG_CURRENT_DESKTOP=KDE` 起来才有 KDE 后端。
- **换网零配置**：接管前先从安卓动态读取当前 SSID/PSK 自动生成 wpa 配置；dhcpcd 拿到租约后动态
  探测网关/网段，注入安卓遗留的路由表。网络段是**纯尽力而为**：失败只打警告，绝不回滚连坐已上屏的桌面。
- **`stop` 之后 android 的原子状态是脏的**：kwin 的第一次 commit 会撞 `-22`，所以 kwinwrap 在
  交接前要预清理（释放 plane/CRTC、DPMS 拉回 On）。
- **容器与安卓只有一个目录可靠共享**：容器 `/root` ↔ 安卓 `/mnt/Droidspaces/drm/root`。
  容器里的 `/data/local/tmp` 是**另一个**目录（inode 都不同）。

## 风险提示

接管期间安卓整套 UI/网络栈是停摆的，脚本有回滚逻辑但**不承诺所有异常路径都能自愈**；
最坏情况是长按电源强制重启（数据不会丢，但当前未保存工作会丢）。首次上机请保证：
电量 >50%、有人在现场、且你不介意重启一次。

## 与上游的关系

本项目以 [Goldzxcbug/droid-drm-takeover](https://github.com/Goldzxcbug/droid-drm-takeover)
为架构参考重构。主要差异见 [docs/架构.md](docs/架构.md#与参考实现的关键差异)。

## License

GPLv3（GNU General Public License v3，全文见 [LICENSE](LICENSE)）。

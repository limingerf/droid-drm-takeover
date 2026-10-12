# audio/ —— 音频（容器出声）

> 状态（2026-10-12，Lenovo TB710FU / pineapple / SM8650Q，容器 DEBIAN）：
> **未出声。** 三层问题里第 1 层已修好并实测通过；第 2、3 层是硬阻塞，
> 需要安卓 NDK + 上游 A 路代码才能继续。详见 `docs/音频诊断-2026-10-12.md`。

## 1. 本目录内容

| 文件 | 说明 | 状态 |
|---|---|---|
| `ct-snd-nodes.sh` | **容器内**补出 `/dev/snd/*` 节点 + 自检。解决"ALSA 连声卡都看不到" | ✅ 实测通过 |

## 2. 三层问题模型（别把它们混成一层）

容器里放不出声，是**三个互相独立**的问题叠在一起。修好第 1 层**不会**让第 2 层变好：

| 层 | 症状 | 本机状态 | 谁能修 |
|---|---|---|---|
| **① 设备节点** | 容器 `/dev/snd/` 里只有一个 `timer`；`aplay -l` 报 no soundcards | ✅ **已修**（`ct-snd-nodes.sh`） | 容器内 `mknod` |
| **② 后端音频图** | 节点齐了、`hw_params` 也设成功了，但 **`write()` 一律返回 `EINVAL`** | ❌ 容器侧**修不了** | 只有安卓侧（AudioReach/AGM）能建 |
| **③ 框架/HAL 可用性** | 安卓 `system_server` 卡在 Watchdog 重启循环，`media.audio_flinger` / `media.audio_policy` / `android.hardware.audio.core.IModule/default` **从未注册** | ❌ 当前是死的 | 见 §4 |

### 第 ① 层：为什么容器里没有节点

**devtmpfs 在开机时从未被挂载过**，所以内核从来没往里面建过 snd 节点：

* 节点自动创建走 `drivers/base/devtmpfs.c: devtmpfs_create_node()`，它第一句是
  `if (!devtmpfs_mount) return 0;` —— `devtmpfs_mount` 只在**有人 mount devtmpfs** 时才置位。
* 安卓不用 devtmpfs：它把 **tmpfs** 挂在 `/dev`（实测 `grep ' /dev ' /proc/self/mountinfo`
  → `tmpfs tmpfs`），再由 ueventd 按 `ueventd.rc` 建节点。
  ⇒ 整个开机过程 `devtmpfs_mount == 0` ⇒ 一个节点都没建。
* 容器起来时 droidspaces 把 devtmpfs **新挂**到 `/dev`（实测容器 mountinfo
  `0:5 / /dev ... - devtmpfs devtmpfs`）。devtmpfs 是全局单例，但**只包含"挂载之后才被创建"的节点**
  ⇒ `/dev/dri`、`/dev/input`、`/dev/binder` 都在，**snd 的 pcm/control 永远补不上**
  （声卡在开机早期就注册完了）。
* 佐证：droidspaces 二进制的 `/dev` 白名单里**没有 `/dev/snd`**
  （`strings droidspaces | grep '^/dev'`）⇒ 它不负责这件事；
  `enable_pulseaudio` 那条路是 **Termux 专属**（它 exec
  `/data/data/com.termux/files/usr/bin/pulseaudio`，sink 名 `AAudio_sink`），
  本机**没装 Termux**，且改 `container.config` 要重启容器（红线）。

⇒ **正解 = 容器内 `mknod`**。节点号从 `/proc/asound/devices` 读（第一列就是 116 上的 minor），
**不能硬编码**：本机 `controlC0` 的 minor 是 **56**，不是教科书上的 0。

```sh
# 容器内（root）
sh audio/ct-snd-nodes.sh            # 建 + 自检
sh audio/ct-snd-nodes.sh --check    # 只看缺什么
```

实测效果：`/dev/snd` 1 → 54 个节点，`aplay -l` 从 "no soundcards found"
变成列出 **27 个播放设备**。

⚠️ 顺带一个坑：**`amixer -c0 sget "<控件名>"` 一律报
`Mixer sysdefault:0 load error: Operation not permitted`**（走 default/sysdefault 插件的假错误），
但同一张卡用 **numid** 读完全正常：`amixer -D hw:0 cget numid=251` → `values=0`。
⇒ 读控件一律走 numid，别按名字读，也别把这个 EPERM 当成权限/节点问题。

### 第 ② 层：节点齐了也写不进去（AudioReach 后端图）

本机 `ro.board.platform=pineapple`（SM8650Q）走 **AudioReach**，FE PCM 只是"前端"，
**后端（BE）到功放的图必须由安卓侧的 DSP/AGM 建**。容器里对 FE `write()` 的结果：

```
$ aplay -D hw:0,0 -f S16_LE -r 48000 -c 2 tone48k.wav
Playing WAVE ... Rate 48000 Hz, Mono
aplay: pcm_write:2178: write error: Invalid argument      ← EINVAL
```

**10 个 FE 设备（0,1,2,3,4,5,8,14,19,37）全部 EINVAL**，单声道/44.1k/16k/8k 也一样。
`speaker-test` 同款：`Write error: -22,Invalid argument`。

**安卓侧也一样**（所以不是容器特有的权限/SELinux 问题）：

```
$ tinyplay /data/local/tmp/tone48k.wav -D 0 -d 0
Error playing sample
```

⇒ 容器侧 ALSA 是**死路**，与上游结论一致（`ref-upstream/audio/aa-feeder.sh` 注释：
"声音掉进那条**死路**（后端只有安卓侧能建，在容器里写进去永远不出声）"）。

### 第 ③ 层：功放不是原因（纠正上一轮的错误假设）

`aw882xx`（4 颗 AW smart PA，I2C 1-0034..1-0037）当前值：

| 控件 | 值 | 含义 |
|---|---|---|
| `aw_dev_0..3_switch` | `Enable` | 已使能 |
| `aw882xx_rx_switch` / `_tx_switch` / `_copp_switch` | `Enable` | 已使能 |
| `aw_dev_0..3_prof` | `Music` | 场景 |
| `aw_dev_0..3_monitor` | `Disable` | 正常 |
| **`aw_dev_0..3_volume`** | **0**（范围 0..1023） | **空闲值，不是故障** |

内核日志给出了判据：
`[Awinic][1-0034]aw882xx_get_rx_en: no stream, use record value` ——
**从来没有过一条流**，所以 HAL 没写过音量。上游修好时的日志正好反过来：
`aw882xx_start_pa: start success` 出现在该流 `configure` 的同一毫秒。

⇒ **`aw_dev_*_volume == 0` 是"没有流"的*症状*，不是"没声音"的*原因*。**
把它调大不会出声（第 ② 层的 write 就失败了，根本到不了功放）。

## 3. 方案对比

| 方案 | 原理 | 本机可行性 |
|---|---|---|
| **C 容器直写 ALSA** | 容器 → `/dev/snd/pcmC0D*x` | ❌ 第 ② 层 EINVAL，**死路** |
| **B anland / PulseAudio(AAudio) 桥** | sink = 安卓 OpenSL ES / AAudio，要 `audioserver` 活着 | ❌ `media.audio_flinger` 未注册（第 ③ 层）；本机也没 Termux |
| **A 直连 vendor HAL**（上游主线） | 容器 PipeWire → `aa-feeder.sh` → socket → 安卓侧 `argsloop` → vendor AIDL HAL → AudioPatch → speaker | ⚠️ **架构上唯一可行**，但本机缺构建工具链 + 端口号要重抓（见 §5） |
| **D 厂商 AGM/PAL 工具直连** | 安卓侧 `/vendor/bin/agmplay`（AGM metadata + 写 FE PCM）或 `PalTest`/`mm-audio-ftm`，**不需要 audioserver/AudioFlinger** | ⭐ **最有希望**，但本机卡在 AGM 的 `<intf> rate ch fmt` mixer 控件没暴露（见 `docs/音频诊断-2026-10-12.md` §8） |

A 路链路（上游原文）：

```
容器应用 → Pulse/PipeWire → aa-feeder.sh → socket
        → argsloop SINK（写 dataMQ）
        → vendor AIDL HAL deep_buffer_out → AudioPatch → speaker
        → PAL → AGM → 功放
```

它的价值在于 **`audioserver` / `system_server` / `AudioFlinger` 全可以是死的**
（argsloop 直驱 init class `hal` 的 `android.hardware.audio.service_64`）。

## 4. 当前真正的阻塞（第 ③ 层，安卓侧）

安卓框架卡在 **Watchdog 重启循环**里，周期约 79 秒。ANR 里的主线程栈是铁证：

```
"main" prio=10 tid=1 Native
  ...
  native: #07  libgui.so  android::ComposerServiceAIDL::connectLocked+80
  native: #06  libbinder.so android::CppBackendShim::waitForService+904
  at android.view.SurfaceSession.nativeCreate(Native method)
  at com.android.server.wm.FlexibleAppInnerSplitScreenAnimationMgr.<init>
  at com.android.server.wm.FlexibleWindowManagerService.init
  at com.android.server.wm.ActivityTaskManagerService.<init>
  at com.android.server.SystemServer.startBootstrapServices(SystemServer.java:1416)
```

`init.svc.surfaceflinger = stopped`（DRM 接管的前提），但 `system_server` 还活着
⇒ `startBootstrapServices` 里建 `SurfaceSession` 时**无限等 SurfaceFlinger**
（`AServiceManager_waitForService` 没有超时）
⇒ 主线程卡死 66 秒 ⇒ Watchdog 杀 system_server ⇒ 重启 ⇒ 再卡死。

后果：
* `activity` / `package` / `window` / `settings` / `media.audio_flinger` / `media.audio_policy`
  **全部未注册**；`cmd` 报 `Can't find service settings`。
* `AudioFlinger` 自己打：
  `W FactoryHal: hasAidlHalService android.hardware.audio.core.IModule/default: false`
* 每轮重启连坐：camera provider 收到 `binderDied` 直接 abort
  （`/data/tombstones/tombstone_00..13`，全是 `vendor.qti.camera.provider-service_64`）。

⇒ **这不是容器的问题，是"停了 SurfaceFlinger 但没停 framework"这个组合的必然后果。**
`core/lib/android.sh` 现在默认**不** stop framework（注释说是为了保护 audioserver），
但在 DRM 接管下这恰恰制造了死循环。两条出路二选一：

1. **彻底停 framework**（`stop`），再走 A 路 —— 上游的选择（`ref-upstream/ade/ade.sh` P1）。
2. 或者不停 SurfaceFlinger（放弃 DRM 接管，改回 anland 帧转发）。

## 5. A 路移植清单（本机 delta，**还没做**）

参考实现就在本工作区：`ref-upstream/audio/`
（`argsloop.c`、`hal-direct-up.sh`、`aa-feeder.sh`、`vol-zero.sh`、`templates/*.bin`、
`src/aasilent.c`）＋ `ref-upstream/docs/音频-直连HAL.md`、`docs/移植到其他设备.md`。

| # | 上游（OPD2413 / sun / sm8750） | **本机（TB710FU / pineapple / SM8650Q）** |
|---|---|---|
| 1 | `LIB=/system/lib64/android.hardware.audio.core-**V3**-ndk.so` | **`...core-V4-ndk.so`**（实测存在于 `/system/lib64/`，还有 `-V4-ndk.so` 的 sounddose 变体） |
| 2 | `SVC=android.hardware.audio.core.IModule/default` | 同名；但 `service check` 当前是 `not found`（懒服务，要客户端 `waitForService` 才拉起） |
| 3 | `setprop ctl.restart vendor.audio-hal-aidl` | 本机 init 服务名是 **`vendor.audio-hal`**（`init.svc.vendor.audio-hal`） |
| 4 | `deep_buffer_out = portId 3`，`speaker = portId 21` | **必须重抓**。用 `DUMP=<svc> TR=11`（`getAudioPorts`，只读不出声）拿端口表；解析规则见上游文档 §3（**跨步 = 4 + 元素size**，漏掉那个长度字只会解析出第 1 个端口） |
| 5 | `templates/mix3.bin`(120B) `dev21.bin`(152B) `patch0.bin`(29B) | **上游模板对本机无效**，必须用 `TR=10`（`getAudioPortConfigs`）重抓；抓取前提是 **`audioserver` 活着**（接管轮里返回 0 条） |
| 6 | NDK: `aarch64-linux-android33-clang ... -Wl,--export-dynamic` | **本机没有 NDK**：`C:\Users\bai` 下搜不到 `clang.exe`/`aarch64-linux-android*`；容器里 `gcc/clang/ld/make` 全无，`apt-get install clang` 只是本地索引能解析、**网络不通**（`getent hosts deb.debian.org` 无输出） |
| 7 | `AUTOFD=1`：按尺寸从 fd 表认领 cmd/rpy/dataMQ（**不用 GOT 挂钩**，与 core 版本无关） | 可照抄，是上游最关键的移植成果 |
| 8 | 合规：先 `vol-zero.sh` 归零再起 argsloop；`NOAUDG=1` 关掉进程内 audioserver 守卫 | 照抄。**别用每 3 秒 `ctl.stop audioserver` 的守卫**——会触发 rc 链无限振荡并最终重启整机 |
| 9 | 共享目录 `安卓 /mnt/Droidspaces/drm/root` ↔ `容器 /root` | ⚠️ **本机 `/mnt/Droidspaces` 根本不存在**。安卓侧路径是 **`/data/local/Droidspaces/Containers/DEBIAN/rootfs/root`**（容器名是 `DEBIAN` 不是 `drm`）。`aa-feeder.sh`/`hal-direct-up.sh` 里写死的 `HAL_SOCK_ANDROID` 必须改 |
| 10 | 容器侧 `pw-cat --record --target=droid_out` 抓 monitor | 本机 PipeWire/WirePlumber/pipewire-pulse **已在跑**（uid 1000=Gold，安卓 `ps` 里显示成 `system`），`pactl`/`pw-cat`/`pw-record`/`wpctl` 都在；但容器**没有 `socat`、没有 `nc`** ⇒ 上游的 Unix socket 传输在本机缺依赖，要么装 socat，要么改用 PipeWire 原生模块 |

## 6. 复现/自检

```sh
# 安卓侧（PowerShell，注意引号：一律"写脚本 → push → 执行"）
$adb='C:\Program Files (x86)\platform-tools\adb.exe'
$RF='/data/local/Droidspaces/Containers/DEBIAN/rootfs'
& $adb push audio/ct-snd-nodes.sh /data/local/tmp/ct-snd-nodes.sh
& $adb shell "su -c `"cp -f /data/local/tmp/ct-snd-nodes.sh $RF/root/ct-snd-nodes.sh`""
& $adb shell 'su -c "/data/local/Droidspaces/bin/droidspaces --name=DEBIAN run \"sh /root/ct-snd-nodes.sh\""'
```

⚠️ 诊断期间踩过的两个操作坑，写下来免得再犯：

1. **`droidspaces run` 里别塞复合命令**（`;` / `|` / 通配符）。
   实测 `run "rm -f /dev/snd/pcmC0D* ...; ls ...; aplay ... | head -3"` 的 `rm` 落到了
   **容器**（把 53 个节点全删了），而 `aplay` 的错误前缀却是 `/system/bin/sh`
   —— 说明这条串被两侧各执行了一部分。**一律"写脚本文件 → push → 执行"**。
2. 安卓侧 `/dev/snd/*` 是 **tmpfs + ueventd** 管的，误删后**不要**手工 mknod，
   用 uevent 让 ueventd 按 `ueventd.rc` 重建（属主/权限才对）：
   ```sh
   echo add > /sys/class/sound/pcmC0D0p/uevent     # → system:audio 660 自动回来
   ```

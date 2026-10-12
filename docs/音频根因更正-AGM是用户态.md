# 音频：根因更正 —— AGM/GSL 是用户态库，不是内核模块

> ⚠️ **本文取代前一版《音频根因-内核缺AGM》的结论。前一版是错的，已撤回。**
> 采集时间：2026-10-12 23:29–23:40 CST ｜ 设备：OnePlus Pad 3（OP6546L1 / OPD2511 / SM8650Q）

## 0. 撤回声明（先说错在哪）

前一版我写下"运行内核里没有 AGM 驱动，所以设备级损坏、用户态无法修复"。
**这个结论是错的**，两条支撑证据都不成立：

| 前一版用的"证据" | 为什么不成立 |
|---|---|
| `/proc/kallsyms` 里 0 个 `agm_*` / `gsl_*` 符号 | **AGM/GSL 本来就是用户态库**（`/vendor/lib64/libagm.so` 188KB、`libgsl.so` 2.2MB、`libar-pal.so` 4.0MB、`libagm_mixer_plugin.so`、`libagm_pcm_plugin.so` 全在）。它们**不应该**是内核符号 |
| 289 个内核模块里没有 AGM | 同上，**本来就不该有**。内核侧只需要传输层：`gpr_dlkm` + `spf_core_dlkm`（本机都在，`initstate=live`） |
| `tinymix` 里 0 条 `rate ch fmt` 控件 | 那些控件属于 **AGM 用户态虚拟卡 100**，不属于内核 card 0。`tinymix` 只看内核卡，**本来就看不到** |
| `/dev/snd/controlC100` 不存在 | 上游明确写过：`card100 是 AGM 用户态虚拟卡，不该手工 mknod` —— **ENOENT 是正常的** |
| `service list` 里没有 `IAGM`/`IPAL` | **假阴性**：我查的是 framework 的 binder 域。HAL 自己的日志写着 `successfully registered PAL service` / `successfully registered AGM service`，`vndservicemanager`(pid 905) 在跑。上游有专文记录这个坑（`音频-addService-false-negative.md`） |

**上游还专门警告过这个思维陷阱**：`docs/音频-SPF共享内存边界与固件路径污染.md` §4 标题就是
「更正：此前"安卓侧也失败"的结论」—— 他们也曾从"安卓侧也失败"推出"设备级故障"，
后来停掉容器、重启安卓音频栈，`aaudio-probe` 给出 `VERDICT: AAUDIO-OK`，
证明**安卓侧音频是正常的**，真正原因是**容器 HAL 与安卓 HAL 争用 DSP**
（同时持有 `aud_pasthru_adsp`、注册相同 GPR 端口 8195/8194/8197）。

## 1. 本机实测：音频栈是活的，能开流、能起图

```
10-12 23:36:55.228 22088 D AHAL: AudioExtn: audio_extn_hidl_init: 974: successfully registered PAL service
10-12 23:36:55.258 22088 D AHAL: AudioExtn: audio_extn_hidl_init: 987: successfully registered AGM service
10-12 23:36:55.324 22088 D AGM: graph: graph_open: 745 exit, ret 0
10-12 23:36:55.329 22088 D AGM: graph: graph_prepare: 885 exit, ret 0
10-12 23:36:55.329 22088 D AGM: graph: graph_start: 912 exit, ret 0
10-12 23:36:55.329 22088 I PAL: SessionAlsaPcm: start: 1895: set degree
10-12 23:36:55.355 22079 I AudioFlinger: openOutput() ... Device AUDIO_DEVICE_OUT_SPEAKER,
                     SamplingRate 48000, Format 0x000001, Channels 0x3, flags 0x6
```

`graph_open` / `graph_prepare` / `graph_start` **全部 ret 0**，AudioFlinger 成功开出
SPEAKER 输出。⇒ **不存在"设备级音频损坏"。**

同时刻的其它状态：

| 项 | 值 | 说明 |
|---|---|---|
| `system_server` | pid 22445 | 活着（在 79s 看门狗循环里，但活着） |
| `audioserver` | running (pid 22079) | 活着 |
| `surfaceflinger` | stopped | 接管前提 |
| ADSP `remoteproc1` | **running** | DSP 正常 |
| `aud_pasthru_adsp` 持有者 | **无** | 没有 GPR 争用 |
| 内核固件路径 | `/vendor/firmware_mnt/image,...` | **正常，没有 droidspaces 污染** |
| `/proc/oplusManifest` | 不存在 | 但 `/odm/etc/vintf/manifest/network_manifest.xml` 是**普通文件**，不是断链 ⇒ VINTF 正常 |
| `/dev/snd` 真实号（`stat -c '%t:%T'`，十六进制） | `controlC0=116:56` `pcmC0D0p=116:2` `timer=116:33` | 与容器 `ct-snd-nodes.sh` 建的节点**一致** ✓ |

（注：`stat -c '%t:%T'` 输出的是**十六进制**：`74:38` = major 116 / minor 56。
上游提醒过 `/proc/asound/devices` 的编号不等于 minor 号，control/timer 必须 `stat`。
本机两种取法结果一致，节点是对的。）

## 2. 那么 `agmplay` / `mm-audio-ftm` 为什么失败？—— 上游有答案

本机安卓侧：

```
Backend CODEC_DMA-LPAIF-WSA-RX-0 rate ch bit fmt : 48000, 2, 16 0
Invalid mixer control: CODEC_DMA-LPAIF-WSA-RX-0 rate ch fmt
Failed to set device media config
```

上游 §8「补后实测：AGM 客户端从未连上服务」给出的解释：

- 他们的 HAL 注册了 15 个服务，但 **15 个线程全是 `Binder:linker64`（空闲等待）**，
  日志里没有 `agm_init` / `session_obj_init` —— **AGM 的服务端逻辑根本没跑起来**，
  因为**从未被任何客户端调用过**。
- `agmplay` 在容器里 strace 显示「**打开 wav 之后立即退出，从未碰 binder**」；
  `aplay -D agm`、`libagm_pcm_plugin.so` 的 ctypes 调用全部静默失败/崩溃。
- 结论原文：**「正确客户端必须走 AIDL」**
  （`AServiceManager_waitForService("vendor.qti.hardware.agm.IAGM/default")` + `IAGM::fromBinder`），
  「**`agmplay` / ALSA 插件那条路在容器里不成立**」。

⇒ **D 路（`agmplay` / `mm-audio-ftm`）是死路，上游已经走过并放弃。**
`mm-audio-ftm` 走的是同一个 `agm_mixer_plugin`，所以报错一字不差。
`PalTest` 更是超声接近检测（UPD）工具，与播放无关。

## 3. 上游的可行路线（A 路）

```
容器应用 → Pulse/PipeWire → aa-feeder.sh → TCP 127.0.0.1:44777
        → argsloop SINK（写 dataMQ）
        → vendor AIDL HAL deep_buffer_out → AudioPatch → speaker
        → PAL → AGM → 功放
```

- **audioserver / system_server / AudioFlinger 全可以是死的** —— 正合"彻底走直连"。
- 关键实现是 `audio/argsloop.c` 的 `autofd_claim()`：`openOutputStream` 成功后，
  HAL 建的三块共享内存 fd **会自动出现在客户端进程的 fd 表里**，按尺寸认领即可
  （最小两块 = cmdMQ/rpyMQ，最大一块 = dataMQ）。比 piano 的 GOT 挂钩可靠。
- 上游是在**容器里**跑 vendor HAL（`agm-stack.sh`：`ds-logd` + `ds-sm@binder/vndbinder/hwbinder`
  + `ds-audiohal`），因为接管轮里安卓侧 HAL 会被 framework 带走。
  **本机安卓侧 HAL 活着且握着 DSP**，所以更省的变体是：
  **在安卓侧跑一个 AIDL 客户端**（root 身份），完全绕开容器 bionic 那一大套。

### 本机移植增量（相对上游 OPD2413）

| 项 | 上游 OPD2413 | 本机 OP6546L1 |
|---|---|---|
| HAL 库 | `android.hardware.audio.core-V3-ndk.so` | **`-V4-ndk.so`** |
| init 服务名 | `vendor.audio-hal-aidl` | **`vendor.audio-hal`** |
| 共享目录 | `/mnt/Droidspaces/drm/root` | 该路径**不存在**，用容器 rootfs 的 `/root` |
| 端口表 | deep_buffer_out=3 / speaker=21 | **必须重新抓**（`DUMP=... TR=11`） |
| 模板 | `mix3.bin`/`dev21.bin`/`patch0.bin` | **必须重新抓**（`TR=10`；且需 audioserver 活着） |

## 4. 唯一硬门槛：交叉编译工具链

上游 §9 原文：

```
容器里没有编译器，所以在宿主机用 Android NDK 29 交叉编译
NDK=/opt/android-sdk/ndk/29.0.13113456
CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang
```

本机（Windows）**没有 NDK**，设备上也没有编译器，容器里也没有（无 gcc/clang/ld）。
所以 A 路目前卡在**工具链**上，而不是卡在原理上。

## 5. 建议的下一步（按性价比排序）

1. **先验证"安卓侧音频到底能不能出声"**（成本最低）。
   既然 `graph_start ret 0` + `openOutput(SPEAKER, 48000)` 都成功，
   就应该在 framework 活着的窗口里放一段音频、**用耳朵确认**。
   若出声 ⇒ 问题被重新定义为"接管后 audioserver 随 system_server 死"，而不是"音频坏"。
2. **若走 A 路**：搞到 Android NDK（或上游编好的 `argsloop`），在**安卓侧**跑 AIDL 客户端。
   上游用的开关集：`NOAUDG=1 DBG=1 APC=1 APCPORT=3 LOAD=mix3.bin LOAD2=dev21.bin DEVPORT=21
   ROT=1 PP=1 LOADP=patch0.bin PAUTO=1 SENDP=1 POKE=0:0 AUTO=1 TRANSACT=1 STREAM=1 AUTOFD=1
   SVC=android.hardware.audio.core.IModule/default`（本机 `LOAD`/`DEVPORT` 需重抓）。
3. **不要**再碰 `agmplay` / `mm-audio-ftm` / `PalTest` —— 上游已证伪。

## 6. 本次仍未做的事

- **没有**执行 `stop`（framework 全停）。
- **没有**重启容器、**没有**改 `persist.*`/`settings`、**没有** `setenforce 0`、
  **没有**动 `wlan0`/`ip rule`、**没有**碰键盘/网络配置。
- 唯一设备侧改动：`aw_dev_0..3_volume` 从 `0` 设为 `300`（≈29%），未复原。

## 7. 附录：仍然成立的原始证据

以下观测本身没错（错的是我对它们的解读）：

- 三条用户态路径（`agmplay`、`mm-audio-ftm`、容器 `aplay`/`tinyplay`）**确实**全部失败。
- `tinymix | grep -c 'rate ch fmt'` = 0，控件总数 344。（**但这条不能用来证明缺 AGM**）
- 停掉 `audioserver` 后重测，控件数与报错不变 ⇒ **"停 framework 就能修好"不成立**（这条仍成立）。
- `/proc/asound/cards` 只有 card 0。（正常，AGM 卡是用户态的）
- 289 个模块的 `vermagic=6.1.128-android14-11-g09833785ec0f`，运行内核
  `6.1.177-android14-11-g4056c236e4c84`，无一同版本。**这是一条真实的异常观测**，
  但**没有证据**表明它与音频有关（音频相关模块全部 `live`），暂列为待查项，不作为根因。
- 复现脚本仍在诊断工作区 `probe/diag/`（`and-agmscan.sh`、`and-vermagic.sh`、
  `and-ftmplay.sh`、`and-halstop.sh`、`and-svclist.sh`、`and-halreg.sh`、`and-now.sh`、
  `and-fw.sh`、`and-tools.sh` 等）。

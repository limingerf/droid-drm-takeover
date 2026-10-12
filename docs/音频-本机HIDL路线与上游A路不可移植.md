# 音频：本机是 HIDL 音频栈 —— 上游 argsloop（A 路）不可移植

> 采集时间：2026-10-12 23:43–23:55 CST ｜ 设备：OnePlus Pad 3（OP6546L1 / OPD2511 / SM8650Q）
> 本文回答"能参考上游修音频吗"：**能参考思路，但上游的 `argsloop` 方案在本机不成立**，
> 因为本机根本没有 AIDL 音频 HAL。下面是逐条证据。

## 1. 结论（三句话）

1. **本机音频栈是活的**：AudioFlinger 能开 SPEAKER 输出，AGM `graph_open/prepare/start` 全 `ret 0`。
2. **本机音频 HAL 是 HIDL，不是 AIDL**：`android.hardware.audio@7.1::IDevicesFactory/default` +
   `vendor.qti.hardware.AGMIPC@1.0::IAGM/default` + `vendor.qti.hardware.pal@1.0::IPAL/default`。
   上游 OPD2413 用的是 AIDL `android.hardware.audio.core.IModule`，本机**不存在**该服务。
   ⇒ **`argsloop` 那套（A 路）在本机无对象可打。**
3. **本机等价的直连路线是 HIDL 客户端**：`libpalclient.so`（PAL）/ `libagmclient.so`（AGM）/
   `android.hardware.audio@7.1`（和 AudioFlinger 走同一条）。上游 §9 已经在这条路上
   走到 `agm_init rc=0`，卡在 `agm_session_open rc=-32`（未解）。

## 2. 证据

### 2.1 `lshal`：音频服务全是 HIDL（pid 26730 = 音频 HAL 进程）

```
DM,FC  Y android.hardware.audio@7.0::IDevicesFactory/default                 0/14  26730
DM,FC  Y android.hardware.audio@7.1::IDevicesFactory/default                 0/14  26730
DM,FC  Y android.hardware.audio.effect@7.0::IEffectsFactory/default          0/14  26730
DM,FC  Y vendor.qti.hardware.AGMIPC@1.0::IAGM/default                        0/14  26730
DM,FC  Y vendor.qti.hardware.pal@1.0::IPAL/default                           0/14  26730
DM,FC  Y vendor.qti.hardware.bluetooth_audio@2.1::IBluetoothAudioProvidersFactory/default  26730
```

**`0/14` 那一列是"当前客户端数 / 最大"** ⇒ AGM/PAL **从没被任何客户端调用过**
（与上游 §8「AGM 服务端逻辑根本没跑起来，因为从未被任何客户端调用过」完全一致）。

### 2.2 三个 AIDL 域里都没有音频服务

```
service list   | grep -iE 'agm|pal|audio|IModule'
   5  android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
  42  android.media.audio.IHalAdapterVendorExtension/default
 132  vendor.qti.hardware.qxr.IQXRAudioService/default
vndservice list          → Found 7 services，无一个音频相关
lshal --types=a | grep -i audio → 只有上面那批 HIDL 条目
```

### 2.3 `argsloop` 编译成功但找不到任何服务

在 WSL 用 **NDK r27c**（`aarch64-linux-android33-clang`，clang 18.0.3）编译：
```
out/argsloop: ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64
NEEDED: libm.so libdl.so libc.so        ← libbinder_ndk 是 dlopen，不参与链接
```
推到设备跑（`DUMP=<svc>`，只读不发事务）：
```
android.hardware.audio.core.IModule/default          -> getService 空
android.hardware.audio.core.IModule/r_submix         -> getService 空
android.hardware.audio.core.IModule/bluetooth        -> getService 空
vendor.qti.hardware.agm.IAGM/default                 -> getService 空
vendor.qti.hardware.pal.IPAL/default                 -> getService 空
```
⇒ 不是"名字猜错"，而是**这些 AIDL 服务在本机不存在**。

### 2.4 顺带查清：`/data/local/tmp` 不是 vendor 命名空间

`/linkerconfig/ld.config.txt`：
```
dir.system   = /system/bin/ ...
dir.vendor   = /odm/bin/  /vendor/bin/  /data/nativetest64/vendor ...
dir.vendor   = /data/local/tests/vendor          ← 可写的 vendor 命名空间入口
dir.unrestricted = /data/local/tmp               ← argsloop 默认在这里，是 unrestricted
```
在 `/data/local/tests/vendor/` 里跑，命名空间确实变成 vendor
（`default_library_paths=/odm/lib64:/vendor/lib64:...`，`permitted_paths=/odm:/vendor:/system/vendor`），
但**随之无法 dlopen `/system/lib64/android.hardware.audio.core-V4-ndk.so`**（不在 vendor 许可路径内）。
⇒ 以后要写 vendor 域客户端，二进制放 `/data/local/tests/vendor/`，依赖只能来自 `/vendor`、`/odm`、
或放进 `LD_LIBRARY_PATH` 里**按名字**加载。

### 2.5 `agmplay` 为什么必然失败：它根本不是 AGM 客户端

```
$ ldd /vendor/bin/agmplay
   libagmmixer.so => /vendor/lib64/libagmmixer.so
   libtinyalsa.so => /apex/com.android.vndk.v34/lib64/libtinyalsa.so
```
**它没有链接 `libagmclient.so`** —— 它走的是 **tinyalsa + AGM ALSA 插件**
（`libagm_pcm_plugin.so` / `libagm_mixer_plugin.so`），即上游 §8 判定"不成立"的那条路。
所以报 `Invalid mixer control: <be> rate ch fmt` 是**工具选错了**，不是设备坏了。

上游同款结论（§8 原文）：
> **「正确客户端必须走 AIDL」**（`AServiceManager_waitForService(...)` + `IAGM::fromBinder`），
> 「`agmplay` / ALSA 插件那条路在容器里不成立」。

本机把 AIDL 换成 **HIDL** 即可：`libagmclient.so` 就是 `AGMIPC@1.0::IAGM` 的 HIDL 客户端。

### 2.6 AAudio（B 路）也走不通：缺 `IAudioManager`

```
$ /data/local/tmp/aaprobe            # NDK 编译，1.5s 440Hz 振幅 0.08
createStreamBuilder rc=0
openStream rc=-881  AAUDIO_ERROR_NO_SERVICE
E aaprobe : getAudioManager: cannot access IAudioManager
```
`IAudioManager` 属于 **system_server**；本机 system_server 在 79s 看门狗循环里。
另外 `service list` 里**也没有 `media.audio_flinger` / `media.audio_policy`**
⇒ 即使写原生 `AudioTrack` 客户端也够不到 audioserver。

### 2.7 上游在这条路上走到哪（§9，可直接接续）

```
agm_init          rc=0            ✓ 成功（libagmclient.so 已加载）
agm_session_open  rc=-32 handle=0x0   ← 服务端业务错误码，连接是通的
agm_session_prepare/start/write 符号都在
```
上游"下一步"原文：搞清 `agm_session_open` 的 `mode` 参数合法值（试过 0 得 -32），
或先 `agm_get_aif_info_list` 看服务端暴露了哪些 AIF。
⚠️ 上游坑：`ar_err_get_err_str` 直接调会**段错误**，别用它翻译错误码。

## 3. 本机可行路线（按性价比）

| 路线 | 内容 | 依赖 | 评估 |
|---|---|---|---|
| **P1** | `libagmclient.so` 的 C API：`agm_init` → `agm_session_open` → `set_config` → `start` → `write` | 只需 HIDL AGM 服务（已在跑） | **最接近"直连"**，与上游 §9 同路，卡在 `mode` 参数 |
| **P2** | `libpalclient.so` / `libar-pal.so` 的 PAL C API：`pal_stream_open(DEEP_BUFFER→SPEAKER)` → `start` → `write` | HIDL PAL 服务（已在跑） | PAL 在 AGM 之上，更"官方"，但 `stream_attr_t` 结构体大，无头文件需手工还原 |
| **P3** | HIDL `android.hardware.audio@7.1::IDevicesFactory` 客户端（和 AudioFlinger 同路） | HIDL audio HAL | 最贴近上游 A 路语义，但要写 HIDL C++ 客户端，工作量最大 |
| **P4** | 修 framework（让 `audioserver`/`IAudioManager` 可用）→ AAudio/Pulse 桥（上游 B 路） | 需解决看门狗链 | 与"接管释屏"前提冲突，只在需要快速出声时用 |

**建议先做 P1**：它是唯一"框架全死也能出声"且已有上游半成品可接的路线；
先写一个最小 C 探针（dlopen `libagmclient.so`，打印 `agm_get_aif_info_list` + 试 `agm_session_open` 的 `mode` 取值），
**不出声、只读**，把 `mode` 参数试出来再谈放音。

## 4. 工具链（已就绪，可复用）

```sh
# WSL Ubuntu 里有两套 NDK
/home/bai/android-ndk-r26d
/home/bai/android-ndk-r27c        # ← 本次用这套，clang 18.0.3
CC=/home/bai/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang
$CC -std=gnu11 -O2 -fPIE -pie foo.c -o foo -lm -ldl     # 需要 AAudio 就加 -laaudio
```
脚本：`probe/diag/wsl-build-argsloop.sh`、`probe/diag/wsl-build-aaprobe.sh`（在 Windows 侧写好、WSL 执行）。
注意：Windows PowerShell 5.1 往 WSL 传带嵌套引号的命令会被 bash 吃掉
（`unexpected EOF while looking for matching '"'`）——**一律写成 .sh 文件再 `wsl bash <file>`**。

## 5. 本轮产物（诊断工作区 `probe/diag/`）

- `argsloop`（NDK 编译产物）、`aaprobe` + `aaprobe.c`（AAudio 探针，含真实运行输出）
- `and-svclist.sh/out`、`and-halreg.sh/out`、`and-dom.sh/out`、`and-lib.sh/out`、
  `and-vnd.sh/out`、`and-ns.sh/out`、`and-vndsvc.sh/out`、`and-lshal.sh/out`、
  `and-final2.sh/out`、`and-ldcfg.sh/out`、`and-vns.sh/out`、`and-ports.sh/out`
- `wsl-build-argsloop.sh`、`wsl-build-aaprobe.sh`

## 6. 合规与未做的事

- 未执行 `stop`；未重启容器；未改 `persist.*`/`settings`；未 `setenforce 0`；
  未动 `wlan0`/`ip rule`；未碰键盘/网络配置。
- 唯一设备侧改动：`aw_dev_0..3_volume` 从 `0` 设为 `300`（≈29%），未复原。
- 在 `/data/local/tests/vendor/` 建了目录并放了一份 `argsloop`（未删除；如需清理告诉我）。
- 放过一次 1.5s / 440Hz / 振幅 0.08 的测试音（AAudio 探针），但它**在 openStream 就失败，
  没有真正出声** —— 所以**至今仍没有听到任何声音**，不能声称修好。

---

## 7. ★ P1 探针实测（2026-10-13 00:00）—— AGM 直连已推进到"配 PCM 参数"这一步

探针：`probe/diag/agmprobe.c`（NDK r27c 编译）→ 推到 `/data/local/tmp/agmprobe`，
**在默认命名空间就能跑通**（HIDL 走 `/dev/hwbinder`，与命名空间无关，不必进 vendor 域）。

### 7.1 已确认成功（真实输出）

```
=== agmprobe v3  lib=/vendor/lib64/libagmclient.so STEP=5 ===
  [1] dlopen ✓  init=0x76b8b9bc60 open=0x76b8b9bca0 close=0x76b8b9bd90 aif_list=0x76b8b9be60
  [2] agm_init()...          rc=0 ✓ HIDL AGM 服务已连上
  [3] agm_get_aif_info_list  rc=0 条数=54
      [ 0] aif_id=1  name="CODEC_DMA-LPAIF_RXTX-RX-0"
      [ 6] aif_id=2  name="CODEC_DMA-LPAIF_RXTX-TX-3"
      [16] aif_id=1  name="PCM_RT_PROXY-RX-1"
      [23] aif_id=1  name="MI2S-LPAIF-RX-PRIMARY"
      [33] aif_id=1  name="MI2S-LPAIF_WSA-RX-PRIMARY"
      [37] aif_id=1  name="TDM-LPAIF-RX-PRIMARY"
      [47] aif_id=1  name="TDM-LPAIF_WSA-RX-PRIMARY"
      ... 共 54 条（结构步长 36B = name[32] + u32 方向位，1=RX 2=TX）
  [5] aif_connect(sid=100, aif=1, enable=1) rc=0   ← ★ 成功
```

`lshal` 里 AGM 客户端数原本是 `0/14`，现在有客户端了 —— 即**上游 §8「AGM 从未被任何
客户端调用过」这个状态在本机被打破**（这是本机第一次真正调用 AGM 服务）。

### 7.2 反汇编读出的真实 ABI（关键，上游文档没有）

导出的 `agm_*` 只是 `bti c; b <实体>` 跳板，必须看实体：

| 函数 | 实体 | ABI（从寄存器用法读出） |
|---|---|---|
| `agm_session_open` | @0xab84 | `(uint32_t session_id, uint32_t mode, agm_session_t *handle)` —— **三个参数**；`mov w20,w0 / w19,w1 / ldr x5,[x2]` |
| `agm_session_aif_connect` | @0xaf0c | `(uint32_t session_id, uint32_t aif_id, uint32_t enable)` |
| `agm_session_set_config` | @0x9964 | `(uint64_t session_id, session_config*, media_config*, buffer_config*)`；内部 `new[](180)` ⇒ 三结构体序列化约 180B |
| `agm_get_aif_info_list` | @0xb99c | `(void *list, size_t *num)`（已知可用，做对照） |

**踩坑记录**：只传两个参数调 `agm_session_open` 会**段错误**（第三个参数被当指针解引用）。
这也是 v1 探针 `rc=139` 且一行日志都没留下的原因 —— stdout 块缓冲，崩溃时缓冲区全丢。
v2 改成 `setvbuf(_IONBF)` + `fork()` 隔离后才定位到崩溃点。

### 7.3 调用顺序（服务端日志实证）

**先 `aif_connect`，再 `session_open`**：

```
# 只调 session_open（没挂后端）：
E AGM: session: session_open_with_first_device: 889 No Audio interface(Backend) set on session(Frontend):3
E AGM: session: session_obj_open: 2192 Unable to open a session with Session ID:3
   ⇒ 注意 ":3" 正是我传的第一个参数 ⇒ **第一个参数是 session id（Frontend），不是 mode**

# 先 aif_connect 再 session_open：
I AGM: API: agm_session_aif_connect: 625 connecting aifid:1 with session id=100
D AGM: device: device_open: 358 Unsupported PCM rate 0 changing to default rate 48000
E AGM: device: device_open: 376 Unable to open PCM device 1 (cannot set hw params: Invalid argument) rate 48000 ch 0 fmt 0
E AGM: device: device_open: 377 Period Size 0
E AGM: session: session_connect_aif: 758 Error:-5 opening device object with id:1
E AGM: session: session_open_with_first_device: 898 Audio interface(Backend):1 <-> session(Frontend):100 Connect failed error:-5
   ⇒ "No Audio interface(Backend) set" 消失了 ⇒ **顺序对了**；
     现在卡在 PCM 参数是 0/0/0（media config 还没设）
```

### 7.4 当前精确卡点与下一步

**卡点**：`Unable to open PCM device 1 (cannot set hw params) rate 48000 ch 0 fmt 0`
—— 会话的 **media config 仍是 0**，而 `session_open` 会拿它去 `device_open` 真开 PCM。

**下一步（按序）**：
1. 从 `agm_session_set_config` @0x9964 的反汇编还原 `agm_session_config` /
   `agm_media_config` / `agm_buffer_config` 三个结构体的字段偏移；
2. 填 `rate=48000, channels=2, format=16bit`，在 `aif_connect` 之后、`session_open` 之前调用；
3. 然后才是 `prepare` → `start` → `write`（**到这一步才会出声**，届时振幅压到 0.08 级别）。

**仍未出声**：本探针只做 init / aif_list / aif_connect / session_open / close，
**没有 set_config 成功、没有 start、没有 write** ⇒ 依然不能声称修好。

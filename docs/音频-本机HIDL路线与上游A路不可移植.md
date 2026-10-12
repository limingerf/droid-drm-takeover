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

# 音频根因：内核缺 AGM —— 与容器/框架/DRM 接管无关

- 设备：OnePlus Pad 3（`ro.product.device=OP6546L1` / OPD2511 / SM8650Q）
- 采集时间：2026-10-12 23:29 CST（设备本地时间）
- 运行内核：`6.1.177-android14-11-g4056c236e4c84-ab10021739-4k`，编译于 **2024-12-01**
- 厂商镜像：`OPPO/OPD2511/OP6546L1:17/CP2A.260605.016/B.45accdb-…`，`ro.build.date=Sat Sep 19 2026`

## 1. 结论（一句话）

**这台平板的音频是在内核层坏掉的：运行中的内核里没有 AGM 驱动。**
AGM 是 AudioReach 架构里"把 FE PCM 接到 BE 后端"的那一层。它不在，就没有任何
`"<后端名> rate ch fmt"` mixer 控件、没有虚拟声卡 100、没有 `/dev/msm_agm`；
于是**所有**用户态音频路径（厂商 audio HAL、`agmplay`、`mm-audio-ftm`、容器里的
`aplay`/`tinyplay`）全部在同一个地方失败。

这跟 Droidspaces 容器、跟 framework、跟 DRM 接管**都没有关系**。
所以"彻底 stop framework 走直连"这条路**不可能修好音频**，只会额外赔上容器网络。

## 2. 证据（全部为真实命令输出）

### 2.1 用户态三条路，死在同一个地方

```
# 厂商工具 agmplay
Backend CODEC_DMA-LPAIF_WSA-RX-0 rate ch bit fmt : 48000, 2, 16 0
Invalid mixer control: CODEC_DMA-LPAIF_WSA-RX-0 rate ch fmt
Failed to set device media config

# 工厂测试工具 mm-audio-ftm -tc 1（走的是同一个 AGM mixer 插件）
mixer_plugin_open - agm_mixer_plugin_open
mixer_plugin_open: card = 100
mixer_plug_get_card_info: card = 100
FTM: set_device_media_config:244 - set_device_media_config - mixer -CODEC_DMA-LPAIF_WSA-RX-0 rate ch fmt-
FTM: set_device_media_config:247 - Invalid mixer control: CODEC_DMA-LPAIF_WSA-RX-0 rate ch fmt
FTM: audio_ftm_hw_open:2006 - Failed to set device media config
FTM: audio_ftm_toneplay_open:402 - audio_ftm_toneplay_open: failed 402

# 容器 / 安卓裸 ALSA（FE PCM 全部设备号都试过）
aplay: pcm_write:2178: write error: Invalid argument
tinyplay /data/local/tmp/tone48k.wav -D 0 -d {0..5}  →  Error playing sample
```

三条路的共同前提都是那条 mixer 控件。

### 2.2 那条控件确实不存在

```
$ tinymix | grep -icE 'rate ch fmt'
0
$ tinymix | wc -l
344
```

### 2.3 AGM 的虚拟声卡（card 100）不存在

```
$ cat /proc/asound/cards
 0 [pineapplemtpsnd]: pineapple-mtp-s - pineapple-mtp-snd-card
$ tinymix -D 100
Failed to open mixer
$ ls /dev/snd | grep -c C100
0
```

`mm-audio-ftm` 自己打印的 `mixer_plugin_open: card = 100` 就是这张卡 —— 它没被创建。

### 2.4 内核里没有 AGM 符号（决定性）

```
$ uname -r
6.1.177-android14-11-g4056c236e4c84-ab10021739-4k

$ grep -cE ' [tTdDbBrR] agm_' /proc/kallsyms
0
$ grep -cE ' [tTdDbBrR] gsl_' /proc/kallsyms
0
$ grep -cE 'msm_agm' /proc/kallsyms
0
```

注意：`grep -ic agm /proc/kallsyms` 会得到 47，那是 `fr**agm**entation_index`
之类的误命中；带前缀的精确匹配是 **0**。kallsyms 会列出内置函数符号
（同一份输出里有 `ip_fragment`、`fragmentation_index`），所以"没有 `agm_*`"
等价于"AGM 没编进内核"。

### 2.5 289 个厂商内核模块里也没有 AGM

```
$ ls /vendor/lib/modules/*.ko | wc -l
289
$ grep -rl 'rate ch fmt' /vendor/lib/modules /vendor_dlkm/lib/modules   # 无输出
$ grep -rl 'agm_mixer'   /vendor/lib/modules /vendor_dlkm/lib/modules   # 无输出
$ grep -rl 'agm_session' /vendor/lib/modules /vendor_dlkm/lib/modules   # 无输出
```

（`/vendor/lib/modules` 是 `/vendor_dlkm/lib/modules` 的软链，md5 相同。）

已加载的音频模块是 **SPF/GPR** 那一套，没有 AGM：
`spf_core_dlkm`、`gpr_dlkm`、`audio_prm_dlkm`、`audio_pkt_dlkm`、`q6_dlkm`、
`lpass_cdc_*_macro_dlkm`、`wcd9*_dlkm`、`wsa88*_dlkm`、`aw882xx_dlkm`。

### 2.6 没有 AGM 的 misc 设备

```
$ grep -ic agm /proc/misc
0
$ ls /dev/msm_agm
No such file or directory
```

`libagm.so` 就是靠 `/dev/msm_agm` 工作的。

### 2.7 内核与厂商模块版本不匹配（旁证）

```
$ uname -r
6.1.177-android14-11-g4056c236e4c84-ab10021739-4k      # 编译于 2024-12-01

$ grep -ah -o 'vermagic=6\.1\.[0-9]*-android14-11-g[0-9a-f]*' /vendor/lib/modules/*.ko | sort | uniq -c
     38 vermagic=6.1.128-android14-11-g09833785ec0f
$ grep -al 'vermagic=6.1.177' /vendor/lib/modules/*.ko | wc -l
0
$ grep -al 'vermagic=6.1.128' /vendor/lib/modules/*.ko | wc -l
285        # 共 289 个
```

**289 个模块没有一个是为运行中的内核编译的**，全部是 `6.1.128-g09833785ec0f`。
内核 `tainted=4612`（= 4096 OOT + 512 WARN + 4 CPU_OUT_OF_SPEC，**不含** 2
FORCED_MODULE，即这些模块不是被 `--force` 塞进去的，是内核放行的）。

## 3. 排除掉的假设

| 假设 | 判据 | 结论 |
|---|---|---|
| 容器 `/dev/snd` 节点不对 | 容器 54 节点、`aplay -l` 27 个播放设备，与安卓侧一致 | 排除 |
| SELinux / 权限 | `droidspacesd` permissive；安卓侧 root 跑 `tinyplay` 同样失败 | 排除 |
| 功放（AW882xx）没开 | `aw_dev_*_switch`=Enable、`aw882xx_rx/tx/copp_switch`=Enable、ASoC 组件 `aw882xx_smartpa_0..3` 已绑定 | 排除 |
| framework 抢着卡 / 要 stop framework | 停掉 `audioserver` 后重测：控件数仍 344、`rate ch fmt` 仍 0、`agmplay` 报错一字不差；audio HAL 还自动重启了 | **排除** |
| `PalTest` 能直连出声 | `strings` 显示它链 `libpalclient.so`，字符串全是 `UPD stream` / `Far event` / `Near event` —— 它是**超声接近检测**测试工具 | 排除 |
| FTM 配置不对（本机没 WSA 控件） | 确实不对（见下），但**不是**失败点：`mm-audio-ftm` 在 `audio_ftm_hw_open` 里就死了，比读配置里的 enable 段更早 | 排除为根因 |

### 附带发现：本机连工厂测试配方都不匹配

`/vendor/etc/ftm_test_config`（以及所有 `ftm_test_config_*` 变体）是 **WSA macro**
配方（`be_name_rx:CODEC_DMA-LPAIF_WSA-RX-0`、`WSA RX0 MUX:AIF1_PB`、
`SpkrLeft COMP Switch:1`、`SpkrLeft SWR DAC_Port Switch:1`），而本机 344 个控件里
**没有一条 `WSA*` / `Spkr*`**；本机喇叭是 4 颗 AW882xx（`aw_dev_0..3_*`）。
而且**没有** `ftm_test_config_pineapple-mtp-snd-card`（只有
`pineapple-qrd-snd-card` / `pineapple-qrd-sku2-snd-card`），
所以工具退回用通用那份，`soundCardName pineapple-mtp-snd-card` 时必然对不上。

即使我手写一份匹配 AW882xx 的配方也没用 —— `set_device_media_config` 发生在
读 enable 段之前，AGM 控件缺失这一关过不去。

## 4. 为什么"彻底 stop framework 走直连"不成立

上游那条 A 路（`argsloop` → vendor AIDL HAL）和 D 路（`agmplay`/`mm-audio-ftm`）
**都**要落到 AGM 上：

- A 路：`argsloop` 打开 HAL 的 `deep_buffer_out` → HAL 内部 `pal_stream_open` →
  PAL → `libagm.so` → `/dev/msm_agm`。**`/dev/msm_agm` 不存在。**
- D 路：`agmplay` / `mm-audio-ftm` → `libagmmixer.so` → mixer 控件
  `"<be> rate ch fmt"`。**控件 0/344。**

framework 在不在，跟这两条都不相干 —— 已用实测证伪（见 §3 第 4 行）。

## 5. 建议的修法（都在用户态之外）

按可能性排序：

1. **把内核/固件刷回与厂商镜像同一构建**。运行内核编译于 2024-12-01，而 `/vendor`
   与 289 个模块来自 2026-06/2026-10 的构建；且本机装了 KernelSU（内核被改过）。
   `boot_a`/`vendor_boot_a`/`vendor_dlkm` 三者必须来自同一版本。
   判据：刷完后 `/proc/kallsyms` 里应出现 `agm_*` 符号、`/dev/msm_agm` 应存在。
2. 刷完后复验：`tinymix | grep -c 'rate ch fmt'` 应 **> 0**，`/proc/asound/cards`
   应出现第二张卡（AGM 虚拟卡 100）。
3. 只有第 1 步成立，才谈得上 A 路/D 路；在那之前容器侧做任何事都是白费。

## 6. 复现步骤

```sh
adb='C:\Program Files (x86)\platform-tools\adb.exe'
$adb push probe/diag/and-agmscan.sh /data/local/tmp/
$adb shell 'su -c "sh /data/local/tmp/and-agmscan.sh"'
$adb pull /data/local/tmp/and-agmscan.out probe/diag/
```

相关脚本（本次新增，位于诊断工作区 `probe/diag/`，不在本仓库内）：
`and-agmscan.sh`（全模块扫 AGM）、`and-agmko.sh`（模块内容）、
`and-vermagic.sh`（vermagic 对比）、`and-agmcard.sh`（虚拟卡 100）、
`and-ftmplay.sh`（真跑 mm-audio-ftm + 内核日志判据）、
`and-halstop.sh`（证伪"停 framework 有用"）、`and-taint.sh`（taint/模块加载）、
`and-pstore.sh`（上一次启动的 console log）、`and-paltest.sh`（PalTest 真身）、
`and-crit.sh`（zygote 是否 critical）、`and-kern.sh`（内核/指纹）。

每个脚本的输出（`.out`）也一并留在 `probe/diag/`，本文件 §2 的引用即出自它们。

## 7. 本次**没有**做的事

- **没有**执行 `stop`（framework 全停）。理由：§3 已实测证伪"停 framework 有用"，
  而 `stop` 会连 `netd` 一起放倒（`netd` 是 `disabled` + `reboot_on_failure`），
  容器网络会断且要 `setprop ctl.start netd` 才能回来。为一个已被证伪的目标付这个代价
  不合理，等确认。
- **没有**重启容器、**没有**改 `persist.*`/`settings`、**没有** `setenforce 0`、
  **没有**动 `wlan0`/`ip rule`。
- 唯一改动：把 `aw_dev_0..3_volume` 从 0 设成 **300/1023（≈29%）** 做温和音量测试
  （现在仍是 300，未复原；因为功放本来就没收到流）。

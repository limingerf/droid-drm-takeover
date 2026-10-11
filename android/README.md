# DRM 切换器 — Android 侧控制面板

`dev.limingerf.drmswitch`：给 droid-drm-takeover 用的一个极简 Android GUI。
它把仓库里的 shell payload 装到设备上，并提供按钮去调用
`core/switch.sh` 和 `android/*.sh`。

**不依赖 Gradle、不依赖 AndroidX、不依赖任何第三方库**，全部用原始 SDK 工具链构建。

---

## 1. 这个 APK 做什么

| 按钮 | 实际执行 |
| --- | --- |
| 安装/更新 payload | 把 APK 内置的 `assets/payload/**` 释放到 `/data/local/drm-takeover/` |
| 进入 Linux（接管） | `su -c 'sh …/android/enter.sh'` |
| 启动返回守护 | `su -c 'sh …/android/exit-watch.sh start'` |
| 停止返回守护 | `su -c 'sh …/android/exit-watch.sh stop'` |
| 安装开机自启 | `su -c 'sh …/android/boot-install.sh install'` |
| 刷新状态 | `su -c 'sh …/core/switch.sh status'` |
| 环境体检 | `su -c 'sh …/core/switch.sh doctor'` |
| 查看日志 | 列出并 `tail` `/data/local/drm-takeover/run/logs/*.log`，外加托管守护的内存缓冲 |
| 托管守护（前台服务） | 用前台服务托管 `android/exit-watch.sh run`，作为 service.d 自启的替代方案 |

首次启动会自动装一次 payload（用 `SharedPreferences` 里的版本号判断）。
想强制重装就点「安装/更新 payload」。

所有命令输出都进同一个可滚动文本框；命令**串行**执行，避免并发把状态机踩坏。

---

## 2. 文件布局

```
work/android/
├── build.sh                     ← 一键构建脚本（自包含，POSIX sh）
├── README.md                    ← 本文件
├── app/
│   ├── AndroidManifest.xml
│   ├── res/values/strings.xml   ← 唯一的资源文件（应用名）
│   └── src/dev/limingerf/drmswitch/
│       ├── MainActivity.java    ← 全部 UI 用 Java 手搭，无 layout XML
│       ├── Shell.java           ← root 命令执行 + 行流式回调
│       ├── Payload.java         ← assets 解包 + 推送到 /data/local/drm-takeover
│       ├── Tar.java             ← 手写的最小 USTAR 打包器
│       └── WatchService.java    ← 托管返回守护的前台服务
└── build/                       ← 构建产物（生成物，非源码）
    ├── drmswitch.apk
    └── debug.keystore           ← 调试签名密钥，跨构建复用
```

图标不是仓库里的二进制文件：它以 base64 内嵌在 `build.sh` 里，
构建时解码成 `res/mipmap-xxhdpi/ic_launcher.png`。
这样仓库保持纯文本，构建也不需要任何图像库。

---

## 3. 构建

在 WSL（或任意 Linux）里：

```sh
sh /mnt/c/Users/bai/Downloads/drm/work/android/build.sh
```

成功时最后一行打印 APK 绝对路径，退出码 0。

清掉构建产物（**包含**调试密钥库）：

```sh
sh /mnt/c/Users/bai/Downloads/drm/work/android/build.sh clean
```

### 3.1 需要的工具

- `aapt2`、`apksigner`、`zipalign`（来自 Android build-tools，或 PATH）
- `javac` / `java` / `keytool` / `jar`（JDK）
- `zip`、`base64`、`find`、`sha256sum`（coreutils）

### 3.2 SDK 自动探测

按顺序找 `ANDROID_HOME` → `ANDROID_SDK_ROOT` → `/tmp/android-sdk` →
`/opt/android-sdk` → `$HOME/Android/Sdk` → `/usr/lib/android-sdk` → `/usr/local/android-sdk`。

平台优先取 `android-35`，否则取版本号最大的；build-tools 取含 `aapt2` 的那个。
找不到就**直接报错退出，不会联网下载**。

### 3.3 可覆盖的环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `BUILD_DIR` | `work/android/build` | 中间产物目录 |
| `OUT_APK` | `$BUILD_DIR/drmswitch.apk` | 最终 APK 路径 |
| `KEYSTORE` | `$BUILD_DIR/debug.keystore` | 签名密钥库 |
| `D8` | 自动 | 指定 d8 可执行文件 |
| `R8_JAR` | 自动 | 指定含 D8 的 r8.jar |

### 3.4 ⚠️ 本构建环境的两点实际情况

任务说明里写的环境和实际不完全一致，`build.sh` 对两者都做了兼容：

1. **build-tools 里没有 `d8`**（只有 `aapt2`、`apksigner`、`zipalign`）。
   `build.sh` 会依次尝试：`$D8` → `$BT_DIR/d8` → PATH 上的 `d8` →
   最后回落到 `java -cp <r8.jar> com.android.tools.r8.D8`。
   本机可用的 `r8.jar` 在 `/tmp/r8.jar`（D8 8.2.42）。
   注意 D8 8.x **不接受裸目录**作为输入，所以脚本先把 class 打成 jar 再喂给它。

2. **`platforms/android-35/android.jar` 实际是到 `android-34` 的符号链接**，
   所以真正的 compile classpath 是 API 34（`aapt2 dump badging` 会显示
   `compileSdkVersion='34'`）。manifest 里仍然按任务要求写
   `targetSdkVersion 35`。Java 代码刻意不使用任何 API 35 独有符号。

3. `/tmp` 是易失的。如果 `/tmp/android-sdk` 或 `/tmp/r8.jar` 不见了，
   构建会明确报错，不会尝试下载。

---

## 4. 安装

```sh
adb install -r work/android/build/drmswitch.apk
```

或者把 APK 拷到设备上手动点安装。

> 调试密钥库跨构建稳定（`build.sh` 只删中间产物、不删 `debug.keystore`），
> 所以可以用 `-r` 直接覆盖升级。如果你执行过 `build.sh clean`，
> 密钥库会重新生成，此时需要先卸载旧版本再装。

装完打开应用，点一次「安装/更新 payload」授予 root（首次会自动装）。
之后就可以用「刷新状态」确认环境。

---

## 5. payload 是怎么装进去的

分两步，这样能绕开 SELinux 上下文的问题：

1. **应用自己**把 `assets/payload/**` 解到应用私有目录
   `/data/data/dev.limingerf.drmswitch/files/payload`（不需要 root）。
2. **root** 把它搬到 `/data/local/drm-takeover/`。

第 2 步优先用 **tar 流**：应用把目录打成 USTAR 流，通过 stdin 喂给
`su -c 'tar -x -f - -C <目标>'`。这样写入端始终是 root、读取端始终是应用自己，
不存在"root 去读应用私有目录"的跨上下文访问。

如果 tar 方式失败，自动回落到 `cp -R`（root 直接读私有目录）。

最后收权限：目录 `700`，整棵树 `chmod -R go-w`，保证所有 `.sh` 和 `bin/` 下的东西
都可读可执行，但**非 root 一律不可写**（见第 8 节）。

`assets/payload/` 下带的是：`core/`、`linux/`、`display/`、`tools/`、`configs/`、
`bin/`（存在才带）以及 `android/` 下的三个 `.sh` 包装脚本。
**`app/` 和 `build.sh` 不会进 APK**。源目录缺失时构建只警告、不失败。

---

## 6. 前台服务说明

「托管守护（前台服务）」用 `WatchService` 托管 `android/exit-watch.sh run`。

- 需要 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE`（API 34 起）+
  `POST_NOTIFICATIONS`；低版本回落到 `dataSync` 类型。
- 它**只在 APK 进程存活期间有效**。设备重启后想自动拉起守护，
  还是得用「安装开机自启」（`boot-install.sh` 写 KernelSU/Magisk 的
  `/data/adb/service.d/99-drm-exit-watch.sh`），或者手动点「启动返回守护」。
- 守护的输出同时进 `logs/exit-watch.log` 和前台服务的内存缓冲，
  点「查看日志」两者都会显示。

---

## 7. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `找不到 /data/local/drm-takeover/core/switch.sh` | payload 没装。点「安装/更新 payload」 |
| 所有命令都 `exit 1`、无输出 | 没给 root。检查 KernelSU/Magisk 是否授权了本应用 |
| tar 方式失败但 cp 成功 | 正常，日志里会写明走了哪个方式；不影响使用 |
| `signatures do not match` | 之前执行过 `build.sh clean` 换了密钥。先卸载旧版 |
| 找不到 SDK / 找不到 d8 | 见 §3.4；`/tmp` 可能被清空了 |
| 状态里 `watch: not running` | 点「启动返回守护」，或确认 service.d 钩子已装 |

---

## 8. 安全边界

- 应用**只**通过 `su -c` 执行 payload 目录下那四个固定脚本，不接受任意命令输入。
- 没有 `INTERNET` 权限。
- **payload 落在 root 独占可写的目录**：`/data/local/drm-takeover`。
  `/data/local` 是 `0711 root:root`，只有 root 能写；落地后还会
  `chmod 700` + `chmod -R go-w` 收掉整棵树的写位。

  > 早期版本把 payload 放在 `/data/local/tmp/droid-drm-takeover`。
  > 那个目录是 `0771 shell:shell`，**adb shell（uid 2000）可写**；
  > 而这些脚本随后以 root 执行（应用已持有 su 授权，不会再弹提示）。
  > 两者相加 = 任何能写该目录的本地进程都能拿到 **root 代码执行**。
  > 这是个真实的提权路径，所以改掉了。

- **纵深防御**：脚本侧还有 `core/lib/common.sh` 的
  `drm_assert_payload_trusted()`。它在每次执行特权子命令（`enter`/`exit`/
  `rollback`/`watch`）之前检查 payload 树的所有者与权限位，命中
  `/data/local/tmp`、`/sdcard` 等位置或发现 group/other 可写就**拒绝运行**。
  这样即使将来路径又被改回可写目录，也不会静默地变成提权通道。
  （只读子命令 `status`/`doctor`/`help` 不拦，方便任何情况下都能查状态。）
  仅限自己的调试环境可用 `DRM_ALLOW_UNTRUSTED=1` 绕过。
- payload 对所有用户可读可执行（目录 700、文件可读）。里面不应放任何密钥；
  WiFi 凭据请按原仓库的方式由 `configs/` 或环境变量提供。

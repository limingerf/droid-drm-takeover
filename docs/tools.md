# 工具清单（bin/ 产物）

```sh
make              # 全部（24 个产物）
make runtime      # 只有脚本硬依赖的 6 个 —— 随 APK/容器分发的最小集
```

输出目录可以用 `BIN` / `BLD` 覆盖，用于隔离校验：

```sh
make runtime BIN=bin-rt BLD=build-rt    # 不动完整的 bin/
```

（CI 就是这样验证 runtime 子集的。早期版本直接 `make clean && make runtime`，
把完整的 `bin/` 覆盖成 6 个，结果上传给 APK job 的 artifact 里只剩 6 个文件。）

**日常使用不需要手动运行任何一个** —— 状态机和会话脚本会自动调用它们。
本文面向给新设备做适配、或排查问题的人。

所有需要 DRM master 的工具都以 root 运行。用法直接跑不带参数，一般会打印提示。

## ① runtime —— 脚本硬依赖，缺一个流程就跑不起来

源码在 `tools/runtime/`。

| 工具 | 作用 | 手动用法示例 |
|---|---|---|
| `kwinwrap` | **全项目心脏**：root 拿 DRM master → 预清理安卓遗留 atomic 状态 → 钉背光 → DROP_MASTER → 降权（`KWINWRAP_UID/GID`）→ exec 目标程序 | `kwinwrap --out /tmp/atomic.log -- env KWIN_DRM_DEVICES=/dev/dri/card0 kwin_wayland --socket=taketest` |
| `kwinwrap --probe-split` | **只做 split 几何发现**，把结果打印成可 `eval` 的形式，不 exec 任何东西 | `eval "$(bin/kwinwrap --probe-split)"` |
| `setbright` | 直写/打印背光亮度（安卓关机流程会把亮度拉 0，接管后必须自己点亮） | `setbright 2048`；不带参数 = 只打印范围 |
| `setprop` | 直写 connector 的 DRM 属性（默认 `dpms`；`0` = On） | `setprop 0 dpms`；不给 connector 就**运行时自动发现**面板 |
| `crtcstate` | dump CRTC 当前状态（上屏取证） | `crtcstate [card]` |
| `connprops` | 免 master 查找 connector 属性 ID | `connprops [card]` |
| `atomicspy.so` | LD_PRELOAD 钩子：记录目标进程每次 atomic commit 的对象/属性/errno，**不改行为** | `LD_PRELOAD=bin/atomicspy.so kwin_wayland ...` |

> **修掉的一个历史错配**：旧 Makefile 用 `src/atomic-spy.c`（ptrace 版）
> 生成 `atomicspy.so`，而真正的 LD_PRELOAD 版 `src/atomicspy.c` **从未被编译**。
> 于是文档教你 `LD_PRELOAD=bin/atomicspy.so`，实际加载的是一个带 `main()` 的
> ptrace 程序 —— 完全不是那个意思。现在 `atomicspy.so` 来自正确的源文件，
> ptrace 版单独作为 `atomic-spy` 编出来。

## ② probe —— 设备适配期用，不参与日常流程

源码在 `tools/probe/`。

### 设备无关（换设备先跑这三个）

它们全部运行时发现 conn/crtc/mode/plane，**不含任何设备常量**。

| 工具 | 作用 | 用法 |
|---|---|---|
| `kmsdump` | 枚举 connector/encoder/crtc/plane 及其全部属性 | `kmsdump [card]` |
| `kmsmatrix` | plane ↔ CRTC 的 `possible_crtcs` 矩阵（找可用 plane） | `kmsmatrix [card]` |
| `atomiccheck` | atomic 能力自检（caps / 属性 / TEST_ONLY 通路） | `atomiccheck [card]` |

> 这三个是 `display/drm-diag-once.sh` 首先跑的。旧文档没提它们，
> 反而推荐一堆写死 piano 对象 ID 的探针 —— 那是反的。

### 触摸验证（替代被厂商安全策略禁止的 getevent 旁听）

| 工具 | 作用 | 用法 |
|---|---|---|
| `touchtest` | 连进合成器的标准验证画板：每个触点画圆 + 打点日志。判断"手指→驱动→kwin→渲染"整条链 | `WAYLAND_DISPLAY=taketest touchtest 30` |
| `touchdraw` | 绕过合成器：裸 atomic 直接点亮 framebuffer 画触摸点，证明面板+触摸在无 kwin 时可用。**纯 libdrm**，但含 ARM64 内联汇编（缓存维护） | 需 DRM master；`TOUCH_EVENT=<节点> touchdraw` |
| `touchinj` | 用 KWin 的 fake-input 扩展注入假触摸，免真手指端到端测试。**绕开 libinput** | `WAYLAND_DISPLAY=taketest touchinj 30 [节点]` |
| `udevprobe` / `udevmatch` | 经 udev 枚举/匹配触摸事件节点（`eventN` 编号每次 boot 会变，**不要写死**） | 直跑打印 |

`touchinj` 的环境变量：

```sh
TOUCHINJ_W / TOUCHINJ_H     # 面板尺寸，不给就从 DRM 读
TOUCHINJ_ROT=xyy            # 坐标变换，见 docs/适配新设备.md 7.3
TOUCH_EVENT=/dev/input/eventN
```

> **旧版 `touchinj` 把面板写死成 3200x2136**（piano 的值），
> 而且用 `value / 100` 猜触摸控制器量程（那个 100 也是 piano 的巧合）。
> 换设备后注入坐标整体错位。现在面板尺寸从 DRM 读、量程从 `EVIOCGABS` 读。

### 旧探针（默认对象 ID 是 piano 的）

这些工具默认对着 piano 的 crtc 206 / conn 67 / plane 157,161。
**在别的设备上结果无意义**，所以 `drm-diag-once.sh` 默认不跑它们
（要跑加 `DIAG_LEGACY_PROBES=1`）。

| 工具 | 作用 |
|---|---|
| `drmatomic` | 通用 atomic 提交命令行（模式设置 + 色带上屏 + 双 pipe split 演示） |
| `planecrtc` | plane↔CRTC 关系（`kmsmatrix` 的旧版） |
| `informats` | 列卡支持的 FB 像素格式/modifier |
| `masterprobe` | 探测当前谁持有 DRM master |
| `rawprobe` | 逐属性打印原始 errno |
| `kwinprobe` | 借 kwin 已握住的 card fd（按 pid 附加）在真实上下文内测行为 |
| `atombisect` | TEST 返 `-22` 时二分定位是哪个属性被内核拒（全程 TEST_ONLY，非破坏性） |
| `stageprobe` | 分阶段提交验证 |
| `replicate` | 对接管期返回 `-ENOENT` 的属性做 TEST_ONLY 变体重放 |
| `atomic-spy` | ptrace 版 atomic 监视（`atomicspy.so` 的非 LD_PRELOAD 版本） |

## 新设备适配最短路径

完整流程见 **[适配新设备.md](适配新设备.md)**。最短版：

```sh
# ① 一键取证（设备无关的探针 + sysfs 拓扑 + debugfs + dmesg）
sh display/drm-diag-once.sh
#    输出在 run/logs/drmdiag/，照着填 core/device/<codename>.sh

# ② 体检（不碰任何东西）
sh core/switch.sh doctor

# ③ 裸 KMS：能不能点亮面板
bin/drmatomic /dev/dri/card0 10

# ④ split 几何
bin/kwinwrap --probe-split

# ⑤ 试跑：150 秒后自动回滚
DRM_TRIAL_SECS=150 sh display/drm-takeover.sh

# ⑥ 触摸（在 ⑤ 的窗口内，从另一个连接进去）
WAYLAND_DISPLAY=taketest bin/touchtest 30

# ⑦ 都通了才常驻
sh display/desk-takeover.sh
```

> 旧文档的第 4 步写"对象 ID 一律运行时解析，别抄 piano 的常量"，
> 但同一页推荐的 `rawprobe`/`drmatomic`/`atombisect` 本身就抄了 piano 的常量。
> 现在 `kwinwrap` 真的做运行时发现了，并且发现失败会**大声告警**而不是静默用错值。

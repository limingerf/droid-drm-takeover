# 工具清单（bin/ 产物）

`make` 会在 `bin/` 生成全部工具。**日常使用不需要手动运行任何一个**——
`desk-takeover.sh` / `drm-takeover.sh` 会自动调用它们；本文面向给新设备做适配或排查问题的人。

所有需要 DRM master 的工具都以 root 运行；用法均可直接 `bin/<工具>` 不带参数看报错提示。

## ① 接管核心（脚本自动调用）

| 工具 | 作用 | 手动用法示例 |
|---|---|---|
| `kwinwrap` | 全项目心脏：root 拿 DRM master → 预清理安卓遗留 atomic 状态 → DROP_MASTER → 降权（env `KWINWRAP_UID/GID`）→ exec 目标程序。亮度可由 `KWINWRAP_BRIGHTNESS` 钉住 | `kwinwrap --out /tmp/atomic.log -- env KWIN_DRM_DEVICES=/dev/dri/card0 kwin_wayland --socket=taketest` |
| `setbright` | 直写/打印背光亮度（安卓关机流程会把亮度拉 0，接管后必须自己点亮） | `setbright 2048`；不带参数 = 只打印范围 |
| `setprop` | 直写 connector 的 DRM 属性（默认 DPMS；`0` = On） | `setprop 0 DPMS`；属性名/connector id 可作第 2/3 参 |
| `atomicspy.so` | LD_PRELOAD 钩子：记录目标进程每一次 atomic commit 的对象/属性/errno，不改行为 | `LD_PRELOAD=bin/atomicspy.so kwin_wayland ... > atomic.log`；或 `atomicspy <pid> [秒]` 附加到已运行进程 |

## ② 触摸验证（替代 getevent 旁听，避免触发厂商安全联动）

| 工具 | 作用 | 用法 |
|---|---|---|
| `touchtest` | 连进合成器的标准验证画板：每个触点画圆 + 打点日志，判断"手指→驱动→kwin→渲染"链路 | `WAYLAND_DISPLAY=taketest touchtest [秒]` |
| `touchdraw` | 绕过合成器：裸 atomic 直接点亮 framebuffer 画触摸点，证明面板+触摸在无 kwin 时可用 | 需 DRM master（`touchdraw` 直跑） |
| `touchinj` | 用 kwin 的 fake-input 扩展注入假触摸，免真手指端到端测试 | `WAYLAND_DISPLAY=... touchinj [秒]` |
| `udevprobe` / `udevmatch` | 经 udev 枚举/匹配触摸事件节点（`eventN` 编号每次 boot 会变，不要写死） | 直跑打印 |

## ③ KMS 诊断探针（新设备适配第一步就用它们）

| 工具 | 作用 | 用法 |
|---|---|---|
| `rawprobe` | 新设备第一眼：枚举 connector/encoder/crtc/plane，逐属性打印原始 errno | `rawprobe [card=/dev/dri/card0]` |
| `drmatomic` | 通用 atomic 提交命令行（模式设置 + 色带上屏 + 双 pipe split 演示） | `drmatomic [card] [秒]` |
| `atombisect` | TEST 返 -22 时二分定位是哪个属性被内核拒（全程 TEST_ONLY，非破坏性） | `atombisect [card]` |
| `stageprobe` | 探针：与 drmatomic 同setup 的分阶段提交验证 | `stageprobe [card]` |
| `replicate` | 对接管期返回 -ENOENT 的属性做 TEST_ONLY 变体重放 | 直跑 |
| `connprops` | 免 master 查找 connector 属性 ID（DPMS/mode 等） | `connprops [card]` |
| `planecrtc` | plane↔CRTC possible_crtcs 矩阵（找虚拟/overlay 平面判据） | 直跑 |
| `informats` | 列卡支持的 FB 像素格式/modifier | `informats [card]` |
| `crtcstate` | dump CRTC 当前状态（"上屏取证"） | 直跑 |
| `masterprobe` | 探测当前谁持有 DRM master | 直跑 |
| `kwinprobe` | 借 kwin 已握住的 card fd（`pid` 附加）在真实上下文内测行为 | `kwinprobe <pid>` |

## 新设备适配最短路径

1. `rawprobe` + `planecrtc` + `informats` → 摸清面板资源拓扑；
2. `drmatomic` 手动点亮一次色带 → 证明 KMS 通路；
3. 若 TEST 报 -22/-ENOENT → `atombisect` / `replicate` 定位到具体属性；
4. `kwinwrap` + `kwin_wayland` 走通交接（对象 ID 一律运行时解析，别抄 piano 的常量）；
5. 触摸：`udevmatch` 找节点 → `touchdraw` 验裸链路 → `touchtest` 验合成器链路。

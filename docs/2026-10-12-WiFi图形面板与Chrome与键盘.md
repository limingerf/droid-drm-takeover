# 2026-10-12 排查记录：WiFi 图形面板 / Chrome / 键盘最后一行

这一批问题的共同特征是**现象都在上层，根因都在"绕过 startplasma-wayland
手工起桌面"这件事上**。逐条记下来，避免以后重复走弯路。

---

## 一、WiFi 图形界面连不上（密钥代理没注册）

### 症状

托盘里点 WiFi 选网络，连不上。NM 日志：

```
device (wlan0): Activation: (wifi) access point 'ImmortalWrt' has security,
                but secrets are required.
device (wlan0): state change: config -> need-auth
device (wlan0): no secrets: No agents were available for this request.
device (wlan0): state change: need-auth -> failed (reason 'no-secrets')
```

### 根因

连接文件里是 `psk-flags=1` —— **这是对的**，含义是"密钥交给密钥代理保管"，
正是"在图形界面里输密码"该有的模式。但 NM 问遍总线**没有任何代理应答**。

提供代理的是 plasma-nm 的 kded 模块：

```
/usr/lib/aarch64-linux-gnu/qt6/plugins/kf6/kded/networkmanagement.so
```

它的元数据**内嵌在 .so 里**（`X-KDE-Kded-autoload` / `SecretAgent` /
`org.kde.plasma.nm.kded`），所以**不需要** `/usr/share/kservices6/` 下的
`.desktop`。那个目录为空是正常的，不要往那儿补文件（我一开始就是这么
误判的）。

真正的原因：绕过 `startplasma-wayland` 手工起 plasmashell ⇒ **kded6 从来
没有被正常拉起并加载模块**。实测即使 `autoloaded=true` 也不会自动加载，
必须显式 `loadModule` 一次。

### 修法

```sh
qdbus6 org.kde.kded6 /kded org.kde.kded6.loadModule networkmanagement
```

脚本：`network/nm-agent-fix.sh`

### ★ 三个坑

1. **kded6 的 DBus 对象路径是 `/kded`，不是 `/kded6`。**
   用 `/kded6` 会报 `UnknownObject`，看起来像"kded6 没起来"，其实只是
   路径错了。我在这上面浪费了一轮。

2. **判据不是 `org.freedesktop.NetworkManager.SecretAgent` 有没有 owner。**
   那个名字**永远没有 owner**。NM 的代理协议走 `AgentManager.Register()`，
   代理用自己的唯一名（`:1.xxx`）注册。正确判据是 NM 日志出现：

   ```
   agent-manager: agent[...:1.239/org.kde.plasma.networkmanagement/1000]: agent registered
   ```

3. **不能用 `nmcli connection up` 是否成功来判断代理生效。**
   nmcli 不弹窗（除非加 `--ask`），所以它**必然**失败并报
   `Secrets were required, but not provided`。真正弹窗的是 plasmashell
   里的 plasma-nm 小程序，也就是用户点托盘图标那条路。
   我一度因为 nmcli 失败而误判"代理没生效"。

### 附带发现的坑

`/etc/apt/apt.conf.d/95proxy` 曾指向 `http://127.0.0.1:7897`（Windows 宿主上
的代理）。容器里的 `127.0.0.1` 是容器自己，连不上，会让 apt 全挂。
已改名 `.disabled-by-drm`。

---

## 二、WiFi 连上后 ping 不通（策略路由被 NM 挤掉）

### 症状

wlan0 明明连上了，地址、默认路由都有：

```
wlan0  UP  192.168.1.21/24
Connected to ImmortalWrt, signal -50 dBm
default via 192.168.1.2 dev wlan0 proto dhcp src 192.168.1.21 metric 600
```

但 `ping 任何地址` 都是 `Network is unreachable`，连**同一个子网的网关**
都 ping 不通，DNS 也解析不了。

### 根因

`ip rule show` 里有一条兜底规则：

```
32000:  from all unreachable
```

它**之前**必须有更靠前的规则把流量导向真正的表。但实测 WiFi 连上后：

```
0:     from all lookup local
11000: from all iif lo oif dummy0 uidrange 0-0 lookup 1002
16000: from all fwmark 0x10063/0x1ffff iif lo lookup 97
17000: from all iif lo oif dummy0 lookup 1002
20000: from all fwmark 0/0x10000 lookup 97
32000: from all unreachable          ← 全落到这里
```

★ **指向 `main`（254）的规则没了** ⇒ 连直连子网都不可达。
★ **指向 `1042` 的规则也没了** ⇒ 那是容器放 wlan0 默认路由的表。

原因：**NetworkManager 接管 wlan0 时会重建策略路由，把容器原先装好的
规则挤掉**。这是 NM 与容器网络共存的已知冲突（另见 `network/README.md`
§8.1）。

另外表 1042 里的默认路由网关可能是过期的（实测出现过 `via 192.168.1.1`，
而真实网关是 `192.168.1.2`）。

### 修法

**只加不删**（红线：绝不 `ip rule flush`，绝不删 netd 的 rule/table）：

```sh
ip rule add pref 31000 from all lookup main
ip rule add pref 31500 from all lookup 1042
# 用 main 表的真实网关纠正 1042
ip route replace default via <真实网关> dev wlan0 table 1042
```

脚本：`network/route-rule-fix.sh`

### 验证（分层，别一步到位）

```
ip route get 223.5.5.5        →  via 192.168.1.2 dev wlan0
ping 192.168.1.2              →  0% 丢包      （同子网）
ping 223.5.5.5                →  0% 丢包      （出网）
getent hosts www.baidu.com    →  解析成功
curl https://www.baidu.com    →  HTTP 200
curl http://deb.debian.org/…  →  HTTP 200
apt-get update                →  正常
```

---

## 三、Chrome 打不开

### 症状

点 Chrome 图标没反应。日志：

```
ERROR: '--ozone-platform=wayland' is not compatible with Vulkan.
ERROR: Internal Vulkan error (-8): A requested feature is not supported
       (DmaBufImageSiblingVkLinux.cpp initImpl:612)
ERROR: Failed to create EGLImage: EGL_BAD_PARAMETER
ERROR: GPU process exited unexpectedly: exit_code=8704
libwayland: [destroyed object]: error 7: importing the supplied dmabufs failed
Trace/breakpoint trap
```

### 排查过程（含一次严重的自误）

启动包装 `/usr/local/bin/google-chrome` 里有 `--use-angle=vulkan`，先怀疑它。
去掉后仍崩。然后逐个组合测了 7 种参数，**全部失败**，包括 `--disable-gpu`
和 `--use-angle=swiftshader`，于是误判"是合成器/驱动的 dmabuf 通路断了，
任何参数都绕不过去"。

**★ 这个判断是错的。** 错因是我的测试方法：

```sh
runuser ... google-chrome ... 2>&1 | head -40      # ✗ head 读够就退出
```

`head` 退出后管道断开 ⇒ Chrome 收到 **SIGPIPE** ⇒ 被打死 ⇒ Wayland 连接
随之销毁 ⇒ 才报出 `importing the supplied dmabufs failed` 和
`Trace/breakpoint trap`。**我把自己的测试假象当成了根因。**

改成脱离终端、日志写文件之后，真相很清楚：

```
1  只有 --ozone-platform=wayland                 → 崩
2  --ozone-platform=wayland --disable-gpu  ★     → 起来了（11 个进程）
3  --disable-features=Vulkan                     → 崩
4  --use-angle=gl                                → 崩
5  --ignore-gpu-blocklist                        → 崩
6  完整包装脚本那套                               → 崩
7  什么都不加                                     → 崩
```

### 结论

这台机器上 **Chrome 的 GPU 路径是坏的，只有 `--disable-gpu`（软件渲染）
能起来**。KWin 侧同时也在报：

```
kwin_scene_opengl: failed to import dmabuf KWin::LinuxDmaBufV1ClientBuffer(0x...)
```

即 KWin 与客户端之间的 dmabuf 导入是断的。这是**合成器/驱动层**的问题，
不是 Chrome 参数能绕过去的。

### 修法

包装脚本固定为 `--ozone-platform=wayland --disable-gpu --no-sandbox`。

**★ 两条禁令**：
- 不要加回 `--use-angle=vulkan`；
- 不要改成 `--ozone-platform=x11` —— 本容器**没有 Xwayland**，X11 后端
  只会报 `Missing X server or $DISPLAY`。

### ★ 教训（通用）

**用 `| head` / `| grep` 截断一个 GUI 进程的输出会把它 SIGPIPE 打死，
从而伪造出"崩溃"的假象。** 判断"某程序能不能起来"必须：
`setsid nohup <程序> >日志文件 2>&1 </dev/null &`，然后看进程数。

---

## 四、键盘最后一行（符号/文A/空格/Chinese）消失

### 症状

5 行布局的**最后一行**被挤出屏幕，或者被任务栏切掉一半。

### 根因（三个叠在一起）

#### 4.1 候选条从"叠在键盘上"改成"真正占位"，可用高度少了 44

上游把候选条定位在 `keyboardComp.top`（即键盘上方、**不参与布局分配**）。
我们改成真正占位后，`canvas.height` 从 434 变成 **390**，
`keyboardComp` 只剩 346。键高还是 86 时，`5 × 86 = 430 > 346` ⇒
最后一行被裁掉。

**★ 键高不能估。** 我按 86 → 62 → 54 猜了三次。
正确做法是让键盘把真实几何打出来（`Keyboard.qml` 里的 **KBGEO** 诊断日志）：

```
qml: KBGEO canvas=390 ribbon=44 keyboardComp=346 keypad=286
           keypadKeyHeight=57 topMargin=8 bottomMargin=0
```

有了这行就一目了然：**按键可用高度 286，5 行 ⇒ 每行最多 57**。
取 54 留余量。

> ★ `Device.bottom_margin` 实测是 **0**，不是想当然的 10~20。

#### 4.2 任务栏压住键盘最后一行

KWin 把输入法面板**贴屏幕底**放置，不理会任务栏的 strut。实测 surface 是
`y=566..1000`，任务栏高 **50 逻辑像素**，正好压在最后一行上。

试过让任务栏让开，**三条路都不通**：

| panelVisibility | 含义 | 结果 |
|---|---|---|
| 2 | DodgeWindows | KWin 不把 IME 面板当普通窗口，不躲 |
| 3 | WindowsCanCover | 同上 |
| 1 | AutoHide | 面板仍画在上面 |

> ★ 顺带纠正一个错误注释：仓库里曾把 `2` 标成「窗口可以覆盖」，
> 实际 `2 = DodgeWindows`，`3 = WindowsCanCover`。
> 完整枚举：`0 NormalPanel / 1 AutoHide / 2 DodgeWindows / 3 WindowsCanCover / 4 WindowsGoBelow`。

所以只能让**键盘自己让位**：`Keyboard.qml` 里给 keypad 加 52 像素底部
边距（任务栏 50 + 2 余量），按键在任务栏上方结束，任务栏只盖住键盘下方
的空白。

#### 4.3 安装脚本的两个 bug（★ 最坑的一个）

改动怎么都不生效，因为 `input/osk/install.sh` 有两处错：

**Bug 1 —— 基础布局永远不在目标列表里。**

```sh
OSK_VARIANTS=" _email _url _url_search"
for V in $OSK_VARIANTS; do echo "...Keyboard_$L$V.qml"; done
```

想靠 shell 分词把**开头的空串**当成"基础布局"那一项，但**分词会吃掉开头
的空字段** ⇒ `Keyboard_<lang>.qml` 永远不被替换。而 maliit 做普通文本
输入时加载的**正是这个基础文件**。

后果极具误导性：脚本报「全部已是目标状态，无需安装」，而怎么调键高都不
生效，日志上还看不出任何异常。

**Bug 2 —— `Keyboard.qml` 的替换判据太弱。**

```sh
grep -qF '改动 4/4' "$KBQML" && RIBBON_SAME=1     # ✗
```

只要文件里有这个标记就跳过，于是后来追加的改动（底部让位、负高度夹取、
KBGEO 日志）**一个都没装进去**，脚本还报「已装过，跳过」。
改成 `cmp -s "$KBQML_SRC" "$KBQML"` 逐字节比对。

### 修法

- `Keyboard.qml`：候选条占位 + 固定 44 高 + 负高度夹取 + KBGEO 诊断
- `Keyboard_zh-hans.qml`：`readonly property int keyH: 54`
- `install.sh`：修上面两个 bug

### 关于"残影"的最终结论

用户报的残影**只在键盘弹出/收起的一瞬间**。查下来：

- `Keyboard.animationEnabled` **在 maliit 里根本不存在**（grep 了所有
  maliit 的 .so，零命中）⇒ 它是 `undefined` ⇒ QML 当 false ⇒
  **动画本来就是关的**；
- 最近 30 次高度上报**只有两个值**（`h=390` / `h=0`），
  **一个中间值都没有** ⇒ 协议层是干净的。

所以这一瞬间的残影**不来自键盘**，换任何键盘都不会好。它属于合成器/驱动
层 —— 大概率是让这块屏能亮起来的那套**四平面分裂 hack**（把同一个
framebuffer 裁成 4 个 plane 分别送显），输入法面板出现时四个平面不同步。

**该 hack 是屏幕正常显示的前提，动它风险极高（最坏黑屏），暂不处理。**

### 关于"换一个屏幕键盘"

用户的诉求是换个能正常弹的键盘。查下来**没有可换的**：

- KWin 只支持**老版**输入法协议 `zwp_input_method_v1` +
  `zwp_input_method_context_v1`；
- `squeekboard` / `wvkbd` 这类现代 Wayland 键盘走 `zwp_input_method_v2` /
  `zwp_virtual_keyboard_v1` ⇒ **在 KWin 上根本起不来**；
- 能替的只有同样说 v1 协议的 KDE 自家 `plasma-keyboard` ⇒
  **Debian trixie 没有这个包**；
- `qt6-virtualkeyboard` 虽然装了，但它走进程内 `QT_IM_MODULE`，
  **对 Chrome 这种非 Qt 程序无效**。

换键盘的接口是 `kwinrc` 里的：

```ini
[Wayland]
InputMethod[$e]=/usr/share/applications/com.github.maliit.keyboard.desktop
```

指向另一个 `.desktop` 即可。但既然没有合格的替代品，且残影根因不在键盘，
**维持 maliit**。

---

## 五、方法上的教训（比具体结论更重要）

1. **不要用 `| head` / `| grep` 判断 GUI 程序是否崩溃** —— SIGPIPE 会伪造
   出 `Trace/breakpoint trap`。用 `setsid nohup … >日志 2>&1 </dev/null &`。

2. **"配置看起来对"不等于生效。** 这一批里最耗时的两个问题
   （安装脚本 bug、kded 模块没加载）都是"配置对、状态对、日志无异常、
   但就是不生效"，必须找到**实际的生效判据**（逐字节比对 / NM 的
   `agent registered` 日志）。

3. **判据要选对。** `nmcli` 失败 ≠ 代理没生效；`/kded6` 报错 ≠ kded6 没起来；
   `SecretAgent` 名字没 owner ≠ 代理没注册。

4. **不要估，要量。** 键高猜了三次；最后靠一行 KBGEO 日志解决。

5. **改完必须实测自证**，而且要分层（同子网 → 出网 → DNS → HTTP），
   别一步跳到"能不能上网"。

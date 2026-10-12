# 掉帧：zh_CN locale 触发 sycoca 无限重建

**结论：桌面会话必须用 `en_US.UTF-8`。用 `zh_CN.UTF-8` 会让 plasmashell 烧掉
一个核心的 70%，整个 KDE 明显掉帧。**

代码落点：`core/lib/display.sh` 的 `drm_start_desktop()` 里 `_lang=en_US.UTF-8`。

---

## 1. 可复现的对照

同一台机、同一份配置、只改 locale：

| plasmashell 的 locale | CPU 消耗 | 观感 |
|---|---|---|
| `LANG=en_US.UTF-8` | **15 秒耗 0.00 秒**（空闲） | 不掉帧 |
| `LANG=zh_CN.UTF-8` | **20 秒耗 14.61 秒**（73%） | 明显掉帧 |
| `LANG=en_US.UTF-8` + `LC_MESSAGES=zh_CN.UTF-8` | 18 秒耗 13.04 秒（72%） | 明显掉帧 |
| `zh_CN` 但把 Kickoff 从面板摘掉 | 15 秒耗 5.20 秒（35%） | 仍卡 |

**第三行很关键**：`LC_MESSAGES` 单独设成 `zh_CN` 也会触发 —— 它决定
**选哪个 sycoca 数据库**，所以"英文 locale + 中文文案"这条路走不通。

第四行说明 Kickoff 是**主要贡献者但不是唯一**：摘掉它 73% → 35%，
剩余部分来自其它 applet（任务栏 `icontasks` 同样要解析 `.desktop`）。

---

## 2. gdb 抓到的现场

`gdb -p <plasmashell> -batch -ex 'bt 18'` 采样时抓到的线程栈：

```
#3  KBuildSycoca::recreate(bool)              libKF6Service.so.6
#4  KSycocaPrivate::buildSycoca()             libKF6Service.so.6
#5  KSycocaPrivate::checkDatabase(...)        libKF6Service.so.6
#6  KSycoca::ensureCacheValid()               libKF6Service.so.6
#7  KService::serviceByStorageId(QString const&)  libKF6Service.so.6
#8  ...                                        libkickerplugin.so   ← Kickoff
```

配合 `/proc/<pid>/io`：

```
write_bytes  110436352  →  126124032     （6 秒写 15.7 MB）
```

⇒ 确实在**无限重建 sycoca**。

---

## 3. 已推翻的两个假说（不要再往这两个方向查）

### 3.1 「两个 sycoca 库互相覆盖」

**这是本项目里出现过的最严重的一次误诊**，一度写进了 `display.sh` 的注释和
一个提交（`5da5c76`），现已更正。

错在**测量方法**：`ls ksycoca6_*` 会同时列出两个文件，而 locale 是文件名的
一部分：

```
ksycoca6_en_<hostkey>     ← en_US 会话用的库
ksycoca6_zh_<hostkey>     ← zh_CN 会话用的库
```

把这两个文件的尺寸交替出现，误读成了"同一个库在 `350877 ↔ 224925`
之间每 4 秒震荡一轮"。实际上它们**各自稳定，从未互相覆盖**。

顺带被这条误诊连坐的还有 `XDG_DATA_DIRS` / `XDG_CONFIG_DIRS`
（当时认为"两边搜索路径不一致导致缓存互相作废"）—— **同样没有证据**。

### 3.2 「文件 mtime 过旧」

把库的 mtime 推到 1 小时后：

```sh
touch -d '+1 hour' /home/Gold/.cache/ksycoca6_zh_*
```

⇒ 循环照旧（库被立刻覆盖回来，mtime 回到当前时间），18 秒仍烧 12.94 秒。

### 3.3 「陈旧 .lock 残留」

`ksycoca6_zh_<hostkey>.lock` 的内容：

```
21712
kwin_wayland
DEBIAN
6554a7743c9f46e2b5b9dea1c1abf15b
017098ce-bdcb-474f-b82c-df38ec1428c3
```

这是 **`kwin_wayland` 持有的活锁**，不是残留。删掉后 15 秒仍烧 10.88 秒，
且锁立刻重现。

---

## 4. 当前最重要的嫌疑：f2fs + `lazytime`

容器根文件系统：

```
/dev/block/dm-7[...]  f2fs  rw,nosuid,nodev,noatime,lazytime,...
                                                     ^^^^^^^^
```

`lazytime` 让 f2fs **延迟更新文件 mtime**。`kbuildsycoca6` 写完数据库后立刻做
失效检查，此时 mtime 可能还没同步落盘 ⇒ 检查判定"缓存仍是旧的" ⇒ 再重建。

**未定案**：mtime 假说（3.2）被否掉了，但那只证明了"把 mtime 推到未来"不管用，
并没有排除"mtime 读到的值滞后于写入"。两者是不同的失效判据。

**注意**：不要用 `mount -o remount,nolazytime /` 去试 —— rootfs 是
`/dev/block/dm-7` 的一个子卷，而这个块设备同时是**安卓的 `/data`**，
remount 会改到整机的挂载选项。

---

## 5. 被否掉的相关假说（更早的排查）

| 假说 | 结论 |
|---|---|
| 缺中文字体 | ✗ 系统有 80 个 CJK 字体（Noto CJK 齐全），再装 `fonts-wqy-*` 无变化 |
| `QML FolderViewDropArea` 的 `minimumWidth` 绑定死循环 | ✗ 该警告在 en_US 和 zh_CN 下**都**出现，不是 locale 相关 |
| 中文翻译文件损坏 | ✗ `/usr/share/locale/zh_CN/LC_MESSAGES/` 有 430 个文件，`plasmashell.mo` 在位 |
| locale 数据缺失 | ✗ `locale -a` 有 `zh_CN.utf8`，`LC_ALL=zh_CN.UTF-8 date` 输出正常中文日期 |

---

## 6. 恢复中文界面的前提

**必须先解决 sycoca 无限重建，不要只把 `_lang` 改回 `zh_CN.UTF-8`。**

改回去就是满屏掉帧 —— 用"能用"换"能看中文"，是净亏。

若将来要试，`display.sh` 留了设备层覆盖口：

```sh
DEV_DESKTOP_LANG=zh_CN.UTF-8 sh switch.sh enter
```

会打印一条明确警告。

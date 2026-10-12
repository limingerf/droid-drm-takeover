#!/usr/bin/env python3
# drm-powerkey.py —— 电源键**短按**切换屏幕亮灭（DPMS off/on）
#
# ======== 为什么自己读电源键（而不是改 KDE 配置）========
# KDE 的正路是 PowerDevil 的「电源键动作 = 关闭屏幕」，但本机**这条路断了**
# （2026-09-28 实测）：
#   · PowerDevil 在跑（org_kde_powerdevil），但它**一个 /dev/input 都没打开**
#     （fd 表里只有 /dev/null）—— 按键不是它读的；
#   · 它的 DBus 接口**没有** turnOffScreen / screenOff / blank 之类方法
#     （Plasma 6 把这些从 DBus 撤了）；
#   · 会话来自 `runuser` 直启、没有 logind 会话 ⇒ 拿不到 `handle-power-key`
#     inhibitor 那条路。logind 侧 HandlePowerKey 已被设成 **ignore**
#     （`/etc/systemd/logind.conf.d/99-power-key.conf`）—— 这是**故意的**：
#     默认值是 `poweroff`，绝不能让它自己处理电源键。
# ⇒ 只能自己读。
#
# ======== ⚠️ 为什么是 Python 而不是 shell（踩了很久）========
# 本容器的 coreutils 是 **uutils（Rust 版）**，`/usr/bin/{dd,cat,head,od}`
# **全部**软链到 `../lib/cargo/bin/coreutils/*`，而它们读 evdev **都是坏的**：
#     dd  if=... bs=1  count=1  ⇒ `IO error: Invalid input`
#     dd  if=... bs=24 count=1  ⇒ 不报错但**永远不返回**
#     cat /dev/input/eventN      ⇒ **立刻返回 0 字节**（不阻塞）
#     head -c 24 /dev/input/...  ⇒ 同上
# 现象是"连续 N 次读不到事件"的空转，极具误导性。Python 的 os.read 正常
# （无数据正确抛 BlockingIOError）。⇒ 本脚本整条链路都用 Python。
#
# ======== 关键设计 ========
# 1. **只认短按，长按完全不管**（LONG_MS 默认 1500ms）。
#    ⚠️ 这是**故意的安全阀**：长按电源键在硬件层是强制关机/重启，
#    用户必须留着这条逃生路。本守护绝不干预长按。
# 2. 状态自己存文件：**sysfs 的 /sys/class/drm/*/dpms 不可信** ——
#    实测 `kscreen-doctor --dpms off` 之后它照样读 `On`。
# 3. 设备**运行时解析**：先按名字（pmic_pwrkey），再按 KEY_POWER 能力扫，
#    不写死 event 编号（换次开机就会变）。
# 4. `kscreen-doctor --dpms off/on` 是唯一可用的 DPMS 开关
#    （`-d/--dpms`，wayland only；KWin 自身没暴露 DPMS 方法）。
#    必须**以 Gold 身份 + 会话总线**调 —— root 直接跑会
#    `Failed to create wl_display` + 加载不了 wayland 平台插件。
#
# 用法（容器内 root）：
#   python3 drm-powerkey.py            前台（调试）
#   python3 drm-powerkey.py -d         后台常驻（setsid + pidfile）
#   python3 drm-powerkey.py --selftest 自测（用 uinput 注入虚拟按键走完整条链路）
# 环境变量：LONG_MS / DEBOUNCE_MS / FIXED_DEV
import os, sys, glob, time, struct, select, subprocess, signal

PIDF   = '/run/drm-powerkey.pid'
LOG    = '/run/drm-powerkey.log'
STATEF = '/run/drm-powerkey.state'
RUNDIR = '/run/user/1000'
USER   = 'Gold'

LONG_MS     = int(os.environ.get('LONG_MS', '1500'))
DEBOUNCE_MS = int(os.environ.get('DEBOUNCE_MS', '400'))
FIXED_DEV   = os.environ.get('FIXED_DEV', '')
# Local adaptation: KWin's wayland socket on this device is named "taketest"
# (drm_start_kwin uses --socket=$DRM_WAYLAND_SOCKET, default taketest), NOT the
# default "wayland-0" (that one is a stale leftover socket).  Without this,
# kscreen-doctor dies with "Failed to create wl_display (Connection refused)".
WL_DISPLAY  = os.environ.get('WL_DISPLAY', 'taketest')

EV_KEY, EV_SYN = 1, 0
KEY_POWER = 116
EVENT_FMT = struct.Struct('llHHi')          # struct input_event (64-bit) = 24B

# ---- 背光（★ 用户明确要求"熄灭屏幕"而不是"黑屏"）------------------------
# `kscreen-doctor --dpms off` 只是让**显示管线停止扫描**（画面变黑），
# **背光仍然亮着** ⇒ 看起来是"黑屏"而不是"熄屏"（暗处能看到微光）。
# 真正的熄灭要把背光写到 0。实测本机：
#   /sys/class/backlight/panel0-backlight/brightness  可写，且 **Gold 有写权限**
#   max_brightness=2047（KDE 报 Brightness=2300/10000 ⇒ 2300*2047/10000 ≈ 471 ✓）
# ⚠️ `actual_brightness` 恒为 0，**不能当判据**（type=raw，不回报实际值）。
# ⚠️ 必须保存/恢复用户原亮度：直接写 0 再写死一个值会把用户的亮度设置冲掉。
BLDIR = None
for _d in sorted(glob.glob('/sys/class/backlight/*')):
    if os.path.exists(_d + '/brightness'):
        BLDIR = _d
        break
BL_SAVE = '/run/drm-powerkey.brightness'

def bl_get():
    try:
        return int(open(BLDIR + '/brightness').read().strip())
    except Exception:
        return None

def bl_set(v):
    try:
        with open(BLDIR + '/brightness', 'w') as f:
            f.write(str(int(v)))
        return True
    except Exception as e:
        log(f"背光写入失败: {e}")
        return False

def bl_save():
    """熄屏前保存用户亮度（只在还没有保存值时保存，避免二次熄屏把 0 存进去）。"""
    if os.path.exists(BL_SAVE):
        try:
            if int(open(BL_SAVE).read().strip()) > 0:
                return
        except Exception:
            pass
    v = bl_get()
    if v and v > 0:
        try:
            with open(BL_SAVE, 'w') as f:
                f.write(str(v))
        except Exception:
            pass

def bl_restore():
    """亮屏时恢复保存的亮度（没有记录就保持不动）。"""
    try:
        v = int(open(BL_SAVE).read().strip())
    except Exception:
        return
    if v > 0:
        bl_set(v)

def log(msg):
    try:
        with open(LOG, 'a') as f:
            f.write(f"{time.strftime('%T')} {msg}\n")
    except Exception:
        pass

# ---- 设备探测 -------------------------------------------------------------
def key_caps_has_power(sysfs_ev):
    """capabilities/key 里有没有 bit 116。
    ⚠️ 该文件是**高位字在前**打印的（pmic_pwrkey 实测 `10000000000000 0`，
       字段数 2）。10000000000000(hex)=2^52，而 116=64*1+52 ⇒ 正好是高字第 52 位。
       所以字段 0 是**最高位**字。若按"低位字在前"解码会得出"不支持电源键"的
       错误结论（我第一次就读错方向）。"""
    try:
        words = open(sysfs_ev + '/device/capabilities/key').read().split()
    except Exception:
        return False
    word, bit = KEY_POWER // 64, KEY_POWER % 64
    idx = len(words) - 1 - word            # 字段 0 是最高位字
    if idx < 0:
        return False
    return bool(int(words[idx], 16) >> bit & 1)

def find_dev():
    if FIXED_DEV:
        return FIXED_DEV
    for p in sorted(glob.glob('/sys/class/input/event*')):
        try:
            if open(p + '/device/name').read().strip() == 'pmic_pwrkey':
                return '/dev/input/' + os.path.basename(p)
        except Exception:
            pass
    for p in sorted(glob.glob('/sys/class/input/event*')):
        if key_caps_has_power(p):
            return '/dev/input/' + os.path.basename(p)
    return None

# ---- DPMS 切换 ------------------------------------------------------------
def call_kscreen(arg):
    """以 Gold 身份 + 会话总线调 kscreen-doctor。返回 (rc, 输出)。"""
    env = dict(os.environ,
               XDG_RUNTIME_DIR=RUNDIR,
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + RUNDIR + '/bus')
    try:
        r = subprocess.run(['runuser', '-u', USER, '--', 'env',
                            'XDG_RUNTIME_DIR=' + RUNDIR,
                            'WAYLAND_DISPLAY=' + WL_DISPLAY,
                            'DBUS_SESSION_BUS_ADDRESS=unix:path=' + RUNDIR + '/bus',
                            'kscreen-doctor', '--dpms', arg],
                           capture_output=True, text=True, timeout=15)
        return r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        return 1, str(e)

def read_state():
    try:
        return open(STATEF).read().strip() == '1'
    except Exception:
        return False

def write_state(off):
    try:
        with open(STATEF, 'w') as f:
            f.write('1' if off else '0')
    except Exception:
        pass

def toggle():
    """熄屏 = DPMS off **加** 背光 0；亮屏 = 恢复背光 **加** DPMS on。
    ⚠️ 两件都要做：只 DPMS off 是"黑屏"（背光还亮），只背光 0 则显示管线还在
       空转（费电、且某些合成器会把亮度又写回来）。"""
    if read_state():
        # ⚠️ 顺序：**先** dpms on（点亮面板），**再**恢复背光 —— 否则背光先亮、
        #    面板还没扫，会闪一下白。
        rc, out = call_kscreen('on')
        bl_restore()
        write_state(False)
        log(f"亮屏 dpms on rc={rc} 背光→{bl_get()}" + (f" | {out}" if out else ""))
    else:
        bl_save()
        # ⚠️ 顺序：**先**把背光写 0，**再** dpms off。
        #    反过来的话面板已被 blank，背光写入可能被驱动丢弃
        #    （现象就是"dpms off 了但背光还亮"）。
        ok = bl_set(0)
        rc, out = call_kscreen('off')
        write_state(True)
        log(f"熄屏 背光→0(ok={ok}) dpms off rc={rc}"
            f"（原值 {open(BL_SAVE).read().strip() if os.path.exists(BL_SAVE) else '?'}）"
            + (f" | {out}" if out else ""))

# ---- 主循环 ---------------------------------------------------------------
def kill_others():
    """单例保护 ★ 必须做（2026-09-28 实测踩坑）：
    两个守护同时读同一个 evdev，各拿一份事件 ⇒ **两个都会响应**。
    它们共享 state 文件却各自翻转 ⇒ 一个刚熄屏、另一个立刻亮回来，
    净效果就是用户看到的『按了没反应 / 屏幕黑了但背光还亮』。
    （evdev 支持多读者，所以不会互相阻塞 —— 不报错、只是行为错乱，很难查。）

    ⚠️⚠️ **必须跳过自己的父进程**（2026-09-29 修，否则是个自伤 bug）：
    `-d` 模式是 fork 出来的，而**父进程的 cmdline 与被杀条件完全吻合**
    （`python3 /root/drm-powerkey.py -d` —— 含 `python` 也含 `drm-powerkey.py`）。
    实测后果：子进程一进 run() 就把父进程 SIGKILL 掉 ⇒ 父进程来不及
    `print("drm-powerkey pid=…")` 就死了（shell 打一行 `Killed`），
    调用方读 pidfile 还可能撞上竞态读到旧值/空值 ⇒ 日志显示 `pid=未起`。
    ⇒ 显式排除 `os.getppid()`。
    """
    me = os.getpid()
    pp = os.getppid()          # ★ 父进程（fork 的那一半）绝不能杀
    for d in glob.glob('/proc/[0-9]*'):
        try:
            pid = int(d.rsplit('/', 1)[1])
            if pid == me or pid == pp:
                continue
            cl = open(d + '/cmdline', 'rb').read().decode('utf-8', 'replace')
            if 'drm-powerkey.py' in cl and 'python' in cl:
                os.kill(pid, signal.SIGKILL)
                log(f"单例：杀掉重复实例 pid={pid}")
        except Exception:
            pass

def run():
    kill_others()
    dev = find_dev()
    if not dev:
        log("找不到支持 KEY_POWER 的设备，退出"); print("找不到电源键设备"); return 1
    if not os.path.exists(dev):
        log(f"{dev} 不存在，退出"); print(f"{dev} 不存在"); return 1
    try:
        fd = os.open(dev, os.O_RDONLY)
    except Exception as e:
        log(f"{dev} 打不开（{e}），退出"); print(f"{dev} 打不开"); return 1

    with open(PIDF, 'w') as f:
        f.write(str(os.getpid()))
    if not os.path.exists(STATEF):
        write_state(False)
    log(f"启动 dev={dev} long={LONG_MS}ms debounce={DEBOUNCE_MS}ms "
        f"初始={'off' if read_state() else 'on'} pid={os.getpid()}")

    down_ts = None
    last_toggle = 0.0
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 5.0)
        except InterruptedError:
            continue
        if not r:
            continue
        try:
            data = os.read(fd, EVENT_FMT.size)
        except OSError:
            # 设备消失/重插：重新探测（掉线自愈）
            log("读取出错，重新探测设备")
            time.sleep(1)
            new = find_dev()
            if new and new != dev:
                log(f"设备改为 {new}")
                dev = new
            try:
                os.close(fd)
            except Exception:
                pass
            try:
                fd = os.open(dev, os.O_RDONLY)
            except Exception:
                time.sleep(2)
            continue
        if len(data) < EVENT_FMT.size:
            continue
        _, _, etype, code, value = EVENT_FMT.unpack(data)
        if etype != EV_KEY or code != KEY_POWER:
            continue

        now = time.time() * 1000.0
        if value != 0:                        # 按下
            down_ts = now
            continue
        if down_ts is None:                   # 抬起但没有配对的按下
            continue
        dur = now - down_ts
        down_ts = None
        if dur >= LONG_MS:
            log(f"长按 {dur:.0f}ms ⇒ 忽略（留给硬件强制关机/重启）")
            continue
        if now - last_toggle < DEBOUNCE_MS:
            log(f"防抖：距上次 {now - last_toggle:.0f}ms ⇒ 忽略")
            continue
        last_toggle = now
        log(f"短按 {dur:.0f}ms ⇒ 切换")
        toggle()

# ---- 自测（uinput 注入）---------------------------------------------------
UINPUT_SETUP  = 0x405c5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY= 0x5502
UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565

def selftest():
    import fcntl, threading
    name = b'pwrtest'
    ufd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(ufd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(ufd, UI_SET_KEYBIT, KEY_POWER)
    setup = struct.pack('HHHH', 0x03, 0x1234, 0x5678, 1) + name + b'\0' * (80 - len(name)) + struct.pack('I', 0)
    fcntl.ioctl(ufd, UINPUT_SETUP, setup)
    fcntl.ioctl(ufd, UI_DEV_CREATE)
    time.sleep(1.5)
    vdev = None
    for p in sorted(glob.glob('/sys/class/input/event*')):
        try:
            if open(p + '/device/name').read().strip() == 'pwrtest':
                vdev = '/dev/input/' + os.path.basename(p)
        except Exception:
            pass
    if not vdev:
        fcntl.ioctl(ufd, UI_DEV_DESTROY); os.close(ufd)
        print("  ✗ 虚拟设备没出现"); return 1
    print(f"  ✓ 虚拟设备 {vdev}")

    # 用虚拟设备跑一份真实主循环
    # ⚠️ 必须改**模块级全局** FIXED_DEV —— find_dev() 读的是它，
    #    只改 os.environ 没用（踩过：自测静默地打开了真实电源键设备）。
    global FIXED_DEV
    FIXED_DEV = vdev
    t = threading.Thread(target=run, daemon=True)
    t.start()
    time.sleep(1.0)

    def emit(v):
        os.write(ufd, EVENT_FMT.pack(0, 0, EV_KEY, KEY_POWER, v))
        os.write(ufd, EVENT_FMT.pack(0, 0, EV_SYN, 0, 0))

    print(f"  起始: 背光={bl_get()} dpms={'off' if read_state() else 'on'}")
    print("  → 注入短按 (120ms)，期望：熄屏 + 背光 0")
    emit(1); time.sleep(0.12); emit(0)
    time.sleep(2.5)
    print(f"    背光={bl_get()} dpms={'off' if read_state() else 'on'}"
          + ("   ✓ 已熄灭（背光=0）" if bl_get() == 0 else "   ✗ 背光没灭"))
    print("  → 注入长按 (2500ms)，期望：被忽略（亮度/状态都不变）")
    emit(1); time.sleep(2.5); emit(0)
    time.sleep(2.0)
    print(f"    背光={bl_get()} dpms={'off' if read_state() else 'on'}"
          + ("   ✓ 长按被忽略" if bl_get() == 0 else "   ✗ 长按不该改状态"))
    print("  → 再注入短按 (120ms)，期望：亮屏 + 背光恢复")
    emit(1); time.sleep(0.12); emit(0)
    time.sleep(2.5)
    _r = bl_get()
    print(f"    背光={_r} dpms={'off' if read_state() else 'on'}"
          + (f"   ✓ 已亮屏（背光恢复到 {_r}）" if _r and _r > 0 else "   ✗ 背光没恢复"))
    fcntl.ioctl(ufd, UI_DEV_DESTROY); os.close(ufd)
    # ⚠️ 必须显式 flush：run() 跑在守护线程里，主线程 os._exit() 会**跳过缓冲区刷新**
    #    ⇒ 自测的输出全部丢失（踩过：只看到守护日志、看不到自测结论）。
    sys.stdout.flush(); sys.stderr.flush()
    os._exit(0)

# ---- 入口 -----------------------------------------------------------------
if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--selftest':
        sys.exit(selftest())
    if len(sys.argv) > 1 and sys.argv[1] == '-d':
        if os.path.exists(PIDF):
            try:
                old = int(open(PIDF).read().strip())
                os.kill(old, signal.SIGKILL)
                time.sleep(1)
            except Exception:
                pass
        pid = os.fork()
        if pid > 0:
            # ⚡ 父进程**等判据**而不是死等 2 秒（原版 sleep(2) 是白等，
            #    实测子进程 ~0.3s 就把 pidfile 写好了）。
            #    判据 = pidfile 里的 pid **是个活着的进程**，且不是本父进程。
            #    ⚠️ 只判"文件非空"不够：pidfile 可能是上一轮残留。
            _t = 0.0
            _ok = False
            while _t < 5.0:
                try:
                    _p = int(open(PIDF).read().strip())
                    if _p != os.getpid() and os.path.isdir('/proc/%d' % _p):
                        _ok = True
                        break
                except Exception:
                    pass
                time.sleep(0.05); _t += 0.05
            if _ok:
                print("drm-powerkey pid=" + open(PIDF).read().strip())
            else:
                print("drm-powerkey 启动失败，看 " + LOG)
            sys.exit(0)
        os.setsid()
        with open('/dev/null', 'wb') as nul:
            os.dup2(nul.fileno(), 0); os.dup2(nul.fileno(), 1); os.dup2(nul.fileno(), 2)
    sys.exit(run())


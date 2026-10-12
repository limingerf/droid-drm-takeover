#!/usr/bin/env python3
# drm-keys.py —— 平板硬件按键守护：**音量键** + **电源键短按**。
#
# ══════════════════════════════════════════════════════════════════════
# 一、为什么必须有这个守护（不是"配置没调对"，是链路断了）
# ══════════════════════════════════════════════════════════════════════
#
# 【2026-10-12 实测证据】物理按键**确实**进了容器：
#   $ python3 evmon2.py /root/evmon2.out 300
#   22:47:21  /dev/input/event0 gpio-keys    KEY_VOLUMEUP 1
#   22:47:21  /dev/input/event0 gpio-keys    KEY_VOLUMEUP 0
#   22:47:23  /dev/input/event1 pmic_pwrkey  KEY_POWER    1
#   22:47:23  /dev/input/event1 pmic_pwrkey  KEY_POWER    0
#   22:48:09  /dev/input/event1 pmic_pwrkey  KEY_POWER    1
#   22:48:09  /dev/input/event1 pmic_pwrkey  KEY_POWER    0
# ⇒ 内核 evdev 层、容器 /dev/input 节点、权限，全都正常。事件到了。
#
# 那为什么按下去没反应？两条独立的原因：
#
# ① 音量键：**桌面里根本没有"音量"这个动作**。
#    - kglobalaccel 的组件清单里没有 plasma-volume / kmix：
#        $ gdbus call ... org.kde.KGlobalAccel.allComponents
#        '/component/plasmashell' ... '/component/org_kde_plasma_emojier_desktop'
#      （只有这三个；org_kde_powerdevil 都还没注册上。）
#    - ~/.config/kglobalshortcutsrc 里 `grep -i volume` **零命中**，
#      只有 [org_kde_powerdevil] 段的亮度键。
#    - PowerDevil 从没启动（plasma-powerdevil.service inactive，
#      因为 graphical-session.target 从没被拉起）。
#    ⇒ 音量键的 keysym 没人接。KWin 收到也只是当作"未处理的键"丢弃。
#
# ② 电源键：logind **收到了但按配置丢掉**。
#    /etc/systemd/logind.conf.d/99-power-key.conf:
#        HandlePowerKey=ignore
#    journal: `systemd-logind[15555]: Power key pressed short.`  ← 收到了
#    但 ignore ⇒ 什么都不做。这是**故意**的（默认值是 poweroff，
#    在这个"绕过 startplasma 手工起"的环境里让它 poweroff 会直接关掉用户的桌面）。
#
# ══════════════════════════════════════════════════════════════════════
# 二、本守护做什么 / 绝不做什么
# ══════════════════════════════════════════════════════════════════════
#
# 做：
#   · 音量键（event0 KEY_VOLUMEUP / event2 KEY_VOLUMEDOWN）
#       ⇒ 调默认 sink 音量 ±VOL_STEP%，并弹一个 OSD 通知。
#   · 电源键**短按**（event1 KEY_POWER，< LONG_MS）
#       ⇒ 熄屏 / 亮屏 切换（背光 0 + DPMS off，两者都做，见下）。
#
# 绝不（红线，写在代码里而不是注释里）：
#   · **绝不 EVIOCGRAB**。全程 O_RDONLY 普通读取，evdev 允许多读者，
#     所以 logind / KWin 照旧收到同样的事件 —— 我们只是"旁听"。
#   · **绝不动长按**（≥ LONG_MS 直接忽略）。长按电源键是**硬件级强制断电**，
#     是这台设备唯一的救砖手段，任何软件都不能碰。
#   · 绝不写 persist.* / settings / setenforce / ip rule / wlan0。
#
# ══════════════════════════════════════════════════════════════════════
# 三、几个"看起来可以但其实不行"的路，以及为什么
# ══════════════════════════════════════════════════════════════════════
#
# · 用 uinput 造个虚拟音量键塞给 KWin？**不行**（2026-10-12 实测）：
#   注入的 injkeyboard 出现在 /dev/input/event10，但 KWin 的设备数
#   始终是 7，日志里没有它。原因是 KWin 的 libinput 走 udev，
#   而 uinput 新设备要等 udev 处理完才有 ID_INPUT_KEYBOARD / seat 标签；
#   容器里的 udev 对这些节点不给 seat 标签（对比实测：
#     event5 TAGS=:1:seat:uaccess:power-switch:   ← 触摸屏有 seat
#     event0 TAGS=:power-switch:                  ← 音量键**没有** seat
#   ）。所以走 KWin 这条路既不可靠又要重启 KWin（用户正在用设备）。
#
# · 改 logind 的 HandlePowerKey 去处理短按？**不选**：
#   (a) 要 `systemctl reload systemd-logind`，且我们这条会话是
#       `su - Gold -c ...` 起的（Service=su-l、RemoteUser=root），
#       logind 的 lock 动作要求会话能自己处理 Lock 信号，而本机
#       **没有**任何 org.kde.screensaver / ksmserver 在总线上
#       （实测 ServiceUnknown）⇒ lock 会静默无效。
#   (b) 实测 logind 的 LockedHint=no 且没有锁屏器。
#   ⇒ 直接自己做熄屏，确定、可逆、不依赖任何外部服务。
#
# · 用 coreutils 读 evdev？**不行**（上游踩过，本机复核过）：
#   本容器 coreutils 是 GNU 9.7，但 dd/cat/head 读 evdev 的语义不可靠
#   （立即 EOF 或不返回）。Python 的 os.read + select 是正确的。
#   ⇒ 整条链路用 Python，不用 shell 读事件。
#
# ══════════════════════════════════════════════════════════════════════
# 四、熄屏为什么"背光 + DPMS"两件都要做
# ══════════════════════════════════════════════════════════════════════
#   · 只 DPMS off：显示管线停扫（画面黑），但**背光还亮** ⇒ 暗处能看到微光，
#     是"黑屏"不是"熄屏"，而且白耗电。
#   · 只背光 0：面板还在扫，费电，且合成器可能把亮度又写回来。
#   顺序也有讲究（实测）：
#     熄屏 = **先**背光写 0，**再** dpms off（反过来的话面板已 blank，
#            背光写入可能被驱动丢弃 ⇒ "dpms off 了但背光还亮"）
#     亮屏 = **先** dpms on，**再**恢复背光（反过来的话背光先亮、面板还没扫，
#            会闪一下白）
#
# ══════════════════════════════════════════════════════════════════════
# 五、用法
# ══════════════════════════════════════════════════════════════════════
#   python3 drm-keys.py              前台（调试）
#   python3 drm-keys.py -d           后台常驻（fork + setsid + pidfile）
#   python3 drm-keys.py --selftest   自测：uinput 注入虚拟键，走完整条逻辑
#   python3 drm-keys.py --status     打印当前状态（背光 / 熄屏标志 / pid）
#
# 环境变量：
#   VOL_STEP=5        音量每档百分比
#   LONG_MS=1500      长按判定（≥ 此值一律忽略）
#   DEBOUNCE_MS=250   同一键的防抖
#   SCREEN_WATCHDOG_S=300  熄屏后最多保持多少秒（0=不限）—— 防"守护死了屏幕还黑着"
#   FIXED_DEV_VOL=...  指定音量设备（自测用）
#   FIXED_DEV_PWR=...  指定电源设备（自测用）
#   NO_OSD=1          不弹通知
import os
import sys
import glob
import time
import signal
import struct
import select
import subprocess

# ─────────────────────────── 常量 ───────────────────────────
# ★ 状态文件路径统一由 _state_paths() 生成，**只有一个地方**拼前缀。
#
#   曾经踩过的坑（2026-10-12）：前缀在模块级拼成 `_ST + '/run/xxx'`，
#   而 __main__ 里处理 --state-prefix 时又拼了一遍不带 '/run' 的 —— 两处
#   不一致。测试夹具走的是模块级那条，于是路径变成 `/tmp/dk2/run/xxx`，
#   而那个目录不存在 ⇒ **所有状态写入静默失败**（open(...,'w') 被 except
#   吞掉）。现象：熄屏标志永远读成"亮屏"、保存亮度永远读成 None，
#   于是亮屏时用兜底 2048 而不是用户原亮度。极难从日志上看出来，
#   因为日志本身也写在同一个坏路径下、也是空的。
_ST = os.environ.get('DRM_KEYS_STATE_PREFIX', '')


def _state_paths(prefix):
    """(PIDF, LOG, STATEF, BL_SAVE, LOCKF)。

    prefix 为空 ⇒ 用 /run（正式运行）。
    prefix 非空 ⇒ 全部落在 prefix 下（自测/干跑用），**不再加 /run**。
    """
    if prefix:
        return (prefix + '/drm-keys.pid', prefix + '/drm-keys.log',
                prefix + '/drm-keys.screenoff', prefix + '/drm-keys.brightness',
                prefix + '/drm-keys.lock')
    return ('/run/drm-keys.pid', '/run/drm-keys.log',
            '/run/drm-keys.screenoff', '/run/drm-keys.brightness',
            '/run/drm-keys.lock')


PIDF, LOG, STATEF, BL_SAVE, LOCKF = _state_paths(_ST)
# STATEF 是熄屏标志（'1' = 已熄屏）；BL_SAVE 是熄屏前的用户亮度。
# ★ display/keepbright.sh 会读 STATEF 决定要不要把背光钉回来（见该文件）。
# 亮屏时如果保存值不可用（文件丢了 / 里面是 0）用的兜底亮度。
# ★ 为什么不"就保持 0"：0 就是全黑，用户会以为屏幕坏了。宁可亮一点。
#   本机 max_brightness=4095，KDE 默认 20% ⇒ 819；这里给 2048（≈50%）是
#   接管脚本里 DEV_BRIGHTNESS 的默认量级，足够看清。
BL_FALLBACK = int(os.environ.get('BL_FALLBACK', '2048'))
# 保存亮度时的最小可用值：低于它的读数视为"脏值"（安卓关机残留），
# 不作为"用户原亮度"保存，亮屏时改用 BL_FALLBACK。
BL_MIN = int(os.environ.get('BL_MIN', '10'))
LOCKF = '/run/drm-keys.lock'            # 单例锁

RUNDIR = os.environ.get('RUNDIR', '/run/user/1000')
DESKTOP_USER = os.environ.get('DESKTOP_USER', '')       # 空则运行时解析
WAYLAND_DISPLAY = os.environ.get('WAYLAND_DISPLAY', '')


def detect_wayland_display():
    """运行时探测 Wayland socket 名。

    ★★ 2026-10-12 实测的坑：守护是 `droidspaces run` 起的，
      **环境里没有 WAYLAND_DISPLAY**。于是 kscreen-doctor 报
          Failed to create wl_display (No such file or directory)
          qt.qpa.plugin: Could not load the Qt platform plugin "wayland"
      rc=134（SIGABRT）。
      现象极具误导性：**背光那半成功了**（背光=0），只有 DPMS 那半失败，
      于是看起来"熄屏了"（真的黑），实际显示管线还在扫 —— 正是本文件
      开头说的"黑屏不是熄屏"。

    ★★ 第二个坑（第一次修这个 bug 时踩的）：本机 kwin 的 socket 名是
      **`taketest`**，**不带 `wayland-` 前缀**（kwin 是用
      `--socket=taketest` 起的）。所以按 `wayland-` 前缀过滤会全部漏掉，
      探测结果为空、报错照旧。
      ⇒ 判据必须是"**是个 unix socket 且有同名 .lock 文件**"：
        Wayland 协议规定服务端会建 <socket>.lock 做互斥。
        本机实测 /run/user/1000/ 下：taketest + taketest.lock ✓
        （对照：pipewire-0 也有 .lock，所以还要排除已知的非 wayland 名。）
    """
    global WAYLAND_DISPLAY
    if WAYLAND_DISPLAY:
        return WAYLAND_DISPLAY
    NOT_WL = ('pipewire', 'pulse', 'bus', 'dbus', 'systemd', 'gnupg',
              'dconf', 'gvfs', 'ssh', 'drkonqi', 'openssh')
    cands = []
    try:
        names = sorted(os.listdir(RUNDIR))
    except Exception:
        names = []
    for n in names:
        if n.endswith('.lock'):
            continue
        if any(n.startswith(p) for p in NOT_WL):
            continue
        p = os.path.join(RUNDIR, n)
        try:
            import stat as _st
            if not _st.S_ISSOCK(os.stat(p).st_mode):
                continue
        except Exception:
            continue
        # 有同名 .lock 才当 wayland socket（协议规定）
        if os.path.exists(p + '.lock'):
            cands.append(n)
        elif n.startswith('wayland-'):
            cands.append(n)          # 兜底：标准名字即使没 lock 也认
    # 优先标准名
    for pref in ('wayland-0', 'wayland-1'):
        if pref in cands:
            WAYLAND_DISPLAY = pref
            return WAYLAND_DISPLAY
    WAYLAND_DISPLAY = cands[0] if cands else ''
    return WAYLAND_DISPLAY

VOL_STEP = int(os.environ.get('VOL_STEP', '5'))
LONG_MS = int(os.environ.get('LONG_MS', '1500'))
DEBOUNCE_MS = int(os.environ.get('DEBOUNCE_MS', '250'))
WATCHDOG_S = int(os.environ.get('SCREEN_WATCHDOG_S', '300'))
FIXED_VOL = os.environ.get('FIXED_DEV_VOL', '')
FIXED_PWR = os.environ.get('FIXED_DEV_PWR', '')
NO_OSD = os.environ.get('NO_OSD', '') == '1'
SKIP_LOCK = False                       # 只有 --selftest 会置 True

EV_SYN, EV_KEY = 0, 1
KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_POWER = 114, 115, 116
EVENT = struct.Struct('llHHi')          # struct input_event (64bit) = 24 字节

# uinput ioctl
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UINPUT_SETUP = 0x405c5503


# ─────────────────────────── 日志 ───────────────────────────
def log(msg):
    try:
        with open(LOG, 'a') as f:
            f.write("%s %s\n" % (time.strftime('%T'), msg))
    except Exception:
        pass
    if not DAEMON:
        try:
            print(msg, flush=True)
        except Exception:
            pass


DAEMON = False


# ─────────────────────── 桌面用户 / 环境 ───────────────────────
def resolve_user():
    """运行时解析桌面账号：不写死 Gold（换设备/换发行版就变了）。"""
    global DESKTOP_USER
    if DESKTOP_USER:
        return DESKTOP_USER
    try:
        import pwd
        for p in pwd.getpwall():
            if 1000 <= p.pw_uid < 65534:
                DESKTOP_USER = p.pw_name
                return DESKTOP_USER
    except Exception:
        pass
    DESKTOP_USER = 'root'
    return DESKTOP_USER


def as_user(argv, extra_env=None, timeout=15):
    """以桌面用户 + 会话总线执行命令。

    ★ 为什么必须降权：kscreen-doctor 是 Qt/Wayland 程序，root 直接跑会
      `Failed to create wl_display` + 加载不了 wayland 平台插件（实测）。
      pactl 也一样要会话的 PULSE_SERVER / XDG_RUNTIME_DIR。
    """
    env = dict(os.environ)
    env['XDG_RUNTIME_DIR'] = RUNDIR
    env['HOME'] = '/home/' + resolve_user()
    env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + RUNDIR + '/bus'
    env['PULSE_SERVER'] = 'unix:' + RUNDIR + '/pulse/native'
    if WAYLAND_DISPLAY:
        env['WAYLAND_DISPLAY'] = WAYLAND_DISPLAY
    if extra_env:
        env.update(extra_env)
    cmd = ['runuser', '-u', resolve_user(), '--', 'env']
    for k in ('XDG_RUNTIME_DIR', 'HOME', 'DBUS_SESSION_BUS_ADDRESS',
              'PULSE_SERVER', 'WAYLAND_DISPLAY'):
        if k in env:
            cmd.append('%s=%s' % (k, env[k]))
    cmd += list(argv)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        return 1, str(e)


# ─────────────────────── 音量（PipeWire / PulseAudio） ───────────────────────
def sink_volume():
    """读默认 sink 音量百分比。返回 int 或 None。

    ★ 用 `pactl list sinks` 的 `Volume: front-left: N / P% / ...` 取 P，
      不用 `get-sink-volume` 的原始值（那是 raw，要自己按 cubic 换算）。
    """
    rc, out = as_user(['pactl', 'list', 'sinks'])
    if rc != 0:
        return None
    name = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith('Name:'):
            name = s.split(':', 1)[1].strip()
        elif s.startswith('Volume:') and name:
            # 只取第一个 "N / P%" 里的 P
            try:
                part = s.split('/')[1].strip()      # "35%"
                return int(part.rstrip('%'))
            except Exception:
                return None
    return None


def sink_muted():
    rc, out = as_user(['pactl', 'list', 'sinks'])
    if rc != 0:
        return None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith('Mute:'):
            return s.split(':', 1)[1].strip().lower() == 'yes'
    return None


def volume_action(code):
    """音量键的落地动作。返回 (是否成功, 人类可读描述)。"""
    if code == KEY_VOLUMEUP:
        rc, _ = as_user(['pactl', 'set-sink-volume', '@DEFAULT_SINK@',
                         '+%d%%' % VOL_STEP])
        verb = '+%d%%' % VOL_STEP
    else:
        rc, _ = as_user(['pactl', 'set-sink-volume', '@DEFAULT_SINK@',
                         '-%d%%' % VOL_STEP])
        verb = '-%d%%' % VOL_STEP
    # 调音量顺带取消静音：否则用户会看到"音量在涨但没声音"，很难判断
    if rc == 0:
        as_user(['pactl', 'set-sink-mute', '@DEFAULT_SINK@', '0'])
    pct = sink_volume()
    muted = sink_muted()
    # ★ 把读回值写进日志：pactl 的 `-N%` 是"相对"调整，但如果服务端
    #   把相对量算错（或我们读到的是陈旧值），**只有读回值能看出来**。
    #   不记这个的话，自测失败时只能看到"没变化"，无法区分
    #   "动作没执行" / "执行了但没生效" / "生效了但读回太早"。
    log("  音量动作 rc=%s 读回=%s%% 静音=%s" % (rc, pct, muted))
    return rc == 0, "%s ⇒ %s%s" % (verb, '静音' if muted else (str(pct) + '%' if pct is not None else '?'),
                                   '' if pct is not None else ' (读不回)')


def osd(text):
    """弹一个 KDE 通知。失败无所谓（不是判据）。"""
    if NO_OSD:
        return
    as_user(['notify-send', '-a', 'drm-keys', '-t', '1200',
             '-i', 'audio-volume-high', '音量', text], timeout=5)


# ─────────────────────── 背光 / 熄屏 ───────────────────────
def bl_dir():
    for d in sorted(glob.glob('/sys/class/backlight/*')):
        if os.path.exists(d + '/brightness'):
            return d
    return None


BLDIR = bl_dir()


def bl_get():
    if not BLDIR:
        return None
    try:
        return int(open(BLDIR + '/brightness').read().strip())
    except Exception:
        return None


def bl_set(v):
    if not BLDIR:
        return False
    try:
        with open(BLDIR + '/brightness', 'w') as f:
            f.write(str(int(v)))
        return True
    except Exception as e:
        log("背光写入失败: %s" % e)
        return False


def bl_save():
    """把**当前**背光保存为"用户原亮度"，供亮屏时恢复。

    ★★ 2026-10-12 血泪：这里曾经有个**自己把自己判掉**的 bug。
      原来的实现是"标志=熄屏就跳过保存"（防止重复熄屏把 0 存进去），
      而 screen_off() 的调用顺序是：
          ① set_screen_off_flag(True)   ← 先置标志
          ② bl_save()                   ← 再保存 ⇒ 看到标志=熄屏，直接 return！
      于是 BL_SAVE **永远是空的**，亮屏时只能走兜底 2048。
      现象：每次熄屏/亮屏都会把用户的亮度重置成 2048，而日志里
      只有一句 `原亮度=?`，看起来像"没保存"，其实是顺序问题。
      ⇒ 判据必须是**调用者显式传入**的"现在屏幕是不是亮着"，
        而不是让函数自己去读那个即将被改写的标志。
    """
    v = bl_get()
    if v and v >= BL_MIN:
        try:
            with open(BL_SAVE, 'w') as f:
                f.write(str(v))
            log("  bl_save: 保存用户亮度 %s" % v)
        except Exception as e:
            log("  bl_save: 写 %s 失败 %s" % (BL_SAVE, e))
    elif v:
        log("  bl_save: 当前背光 %s 低于可用阈值 %s，不保存（亮屏时用兜底 %s）"
            % (v, BL_MIN, BL_FALLBACK))
    else:
        log("  bl_save: 读不到背光，不保存")


def bl_restore():
    """亮屏时恢复保存的亮度。

    ★★ 必须有兜底（2026-10-12 加的）：如果 BL_SAVE 丢了、或者里面是 0
      （例如 keepbright 在熄屏期间把 0 钉进了 sysfs，而我们在那之后才
       读到它），那么"恢复"就是写 0 —— 屏幕亮着但全黑，用户会以为坏了。
      ⇒ 保存值不可用就写 BL_FALLBACK。
    """
    v = None
    try:
        v = int(open(BL_SAVE).read().strip())
    except Exception:
        v = None
    if not v or v <= 0:
        log("背光保存值不可用（%s）⇒ 用兜底 %d" % (v, BL_FALLBACK))
        v = BL_FALLBACK
    bl_set(v)


def screen_is_off():
    try:
        return open(STATEF).read().strip() == '1'
    except Exception:
        return False


def set_screen_off_flag(off):
    try:
        with open(STATEF, 'w') as f:
            f.write('1' if off else '0')
    except Exception:
        pass


def dpms(arg):
    rc, out = as_user(['kscreen-doctor', '--dpms', arg])
    return rc, out


def screen_off():
    # ★ 顺序（和 display/keepbright.sh 的协作有关，别调）：
    #   ① 先置标志：keepbright 每 5 秒回写背光，它靠 /run/drm-keys.screenoff
    #      判断"现在是熄屏状态，别把亮度钉回来"。如果先写背光 0 再置标志，
    #      中间那几毫秒里 keepbright 可能刚好把亮度钉回去 ⇒ 屏幕闪一下。
    #   ② 背光 0
    #   ③ DPMS off
    set_screen_off_flag(True)
    bl_save()
    ok = bl_set(0)
    rc, out = dpms('off')
    if rc != 0:
        # ★ 不要静默：DPMS 失败时屏幕只是"黑"，背光已灭但管线还在扫，
        #   既费电又和"熄屏"不是一回事。必须留下证据。
        log("!! 熄屏：dpms off 失败 rc=%s —— 只有背光灭了，管线仍在扫描" % rc)
    log("熄屏：背光→0(ok=%s) dpms off rc=%s 原亮度=%s%s"
        % (ok, rc, open(BL_SAVE).read().strip() if os.path.exists(BL_SAVE) else '?',
           (' | ' + out.replace('\n', ' ')[:200]) if out else ''))


def screen_on():
    # ★ 顺序：① 先清标志（让 keepbright 恢复回写）② DPMS on ③ 恢复背光。
    #   反过来的话背光先亮、面板还没扫，会闪一下白。
    set_screen_off_flag(False)
    rc, out = dpms('on')
    bl_restore()
    if rc != 0:
        log("!! 亮屏：dpms on 失败 rc=%s" % rc)
    log("亮屏：dpms on rc=%s 背光→%s%s"
        % (rc, bl_get(), (' | ' + out.replace('\n', ' ')[:200]) if out else ''))


def screen_toggle():
    if screen_is_off():
        screen_on()
    else:
        screen_off()


# ─────────────────────── 设备探测 ───────────────────────
def caps_key(sysfs_ev, code):
    """capabilities/key 里有没有 bit `code`。

    ★★ 这个文件是**高位字在前**打印的（实测 pmic_pwrkey 是 `10000000000000 0`，
       两个字段）。116 = 64*1 + 52 ⇒ 落在字段 0 的第 52 位 ⇒ 字段 0 是最高位字。
       按"低位字在前"解码会得出"不支持电源键"的**错误**结论。
    """
    try:
        words = open(sysfs_ev + '/device/capabilities/key').read().split()
    except Exception:
        return False
    word, bit = code // 64, code % 64
    idx = len(words) - 1 - word
    if idx < 0:
        return False
    try:
        return bool(int(words[idx], 16) >> bit & 1)
    except Exception:
        return False


def dev_name(sysfs_ev):
    try:
        return open(sysfs_ev + '/device/name').read().strip()
    except Exception:
        return ''


def find_vol_devs():
    """找所有支持 KEY_VOLUMEUP / KEY_VOLUMEDOWN 的设备。

    ★ 不写死 eventN：换一次开机编号就会变（上游踩过）。
    """
    if FIXED_VOL:
        return [FIXED_VOL]
    out = []
    for p in sorted(glob.glob('/sys/class/input/event*'),
                    key=lambda x: int(x.rsplit('event', 1)[1])):
        if caps_key(p, KEY_VOLUMEUP) or caps_key(p, KEY_VOLUMEDOWN):
            out.append('/dev/input/' + os.path.basename(p))
    return out


def find_pwr_dev():
    """找支持 KEY_POWER 的设备。先按名字，再按能力。"""
    if FIXED_PWR:
        return FIXED_PWR
    for p in sorted(glob.glob('/sys/class/input/event*')):
        if dev_name(p) in ('pmic_pwrkey', 'gpio-keys-power'):
            return '/dev/input/' + os.path.basename(p)
    for p in sorted(glob.glob('/sys/class/input/event*')):
        if caps_key(p, KEY_POWER):
            return '/dev/input/' + os.path.basename(p)
    return None


# ─────────────────────── 单例 ───────────────────────
def singleton():
    """用 flock 做单例。

    ★ 为什么必须做（上游实测）：evdev **支持多读者**，两个守护各拿一份事件
      ⇒ 两个都会响应。它们共享 state 文件却各自翻转 ⇒ 一个刚熄屏、
      另一个立刻亮回来，用户看到的就是"按了没反应"。而且不报错、很难查。
    ★ 为什么用 flock 而不是扫 /proc：扫 /proc 时要靠 cmdline 匹配，
      会误杀自己的父进程（-d 模式 fork 出来的那一半 cmdline 完全吻合，
      上游踩过这个自伤 bug）。flock 由内核保证，没有这个问题。
    """
    import fcntl
    try:
        fd = os.open(LOCKF, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd
    except OSError:
        return None


# ─────────────────────── 主循环 ───────────────────────
def open_dev(path):
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except Exception as e:
        log("打不开 %s: %s" % (path, e))
        return None


def run(skip_lock=None):
    """主循环。skip_lock=None 时读模块级 SKIP_LOCK。

    ★ 为什么把 skip_lock 做成参数而不是只读全局：自测是在线程里跑 run() 的，
      而全局 SKIP_LOCK 由主线程设置 —— 时序上不能保证线程一定读到新值
      （实测踩过：自测因此整个被单例锁挡掉，四项判据全红）。
      显式传参就没有这个竞态。
    """
    global DAEMON
    if skip_lock is None:
        skip_lock = SKIP_LOCK
    detect_wayland_display()             # ★ 必须在任何 kscreen-doctor 之前
    # ★ 自测要跳过单例锁：守护通常正在跑（占着锁），而自测用的是**虚拟设备**
    #   （FIXED_VOL/FIXED_PWR 指向 uinput），和真守护读的不是同一条流，
    #   不会互相抢事件。不跳过的话自测永远在第一行就退出。
    # ★★ 这里曾经有个很隐蔽的 bug：写成
    #       lock = None if skip_lock else singleton()
    #       if lock is None: <拒绝>
    #   于是"跳过锁"（lock=None）和"抢锁失败"（singleton() 返回 None）
    #   被判成同一件事 —— 自测**永远**在第一行就退出，而且报的是
    #   "已有实例在跑"，看起来像单例保护生效，实际是自测根本没跑。
    #   两个语义必须分开表达。
    if not skip_lock and singleton() is None:
        print("已有 drm-keys 实例在跑（%s）" % LOCKF)
        return 1

    vol_devs = find_vol_devs()
    pwr_dev = find_pwr_dev()
    if not vol_devs and not pwr_dev:
        log("找不到任何音量/电源设备，退出")
        print("找不到按键设备")
        return 1

    fds = {}
    for d in vol_devs:
        fd = open_dev(d)
        if fd is not None:
            fds[fd] = ('vol', d, dev_name(d.replace('/dev/input/', '/sys/class/input/')))
    if pwr_dev:
        fd = open_dev(pwr_dev)
        if fd is not None:
            fds[fd] = ('pwr', pwr_dev, dev_name(pwr_dev.replace('/dev/input/', '/sys/class/input/')))

    if not fds:
        log("设备都打不开，退出")
        return 1

    try:
        with open(PIDF, 'w') as f:
            f.write(str(os.getpid()))
    except Exception:
        pass
    if not os.path.exists(STATEF):
        set_screen_off_flag(False)

    _vnames = ','.join('%s(%s)' % (d, n)
                       for kind, d, n in fds.values() if kind == 'vol')
    log("启动 pid=%d 用户=%s 音量设备=%s 电源设备=%s 步进=%d%% 长按阈值=%dms "
        "熄屏看门狗=%ds 初始=%s"
        % (os.getpid(), resolve_user(), _vnames or '无',
           pwr_dev or '无', VOL_STEP, LONG_MS, WATCHDOG_S,
           '熄屏' if screen_is_off() else '亮屏'))
    for k, (kind, d, n) in fds.items():
        log("  监听 %s [%s] %s" % (d, kind, n))

    # 启动自愈：如果上次守护是被 kill 的，屏幕可能还黑着而标志没了。
    #
    # ★ 顺序要紧（和 bl_save 的语义有关）：
    #   ① 标志=亮屏 且 背光可用 ⇒ 先把这个值记为"用户原亮度"。
    #      这样后面任何一次熄屏/亮屏都能恢复到正确的亮度，而不是兜底值。
    #      （实测：不加这一步时，守护重启后第一次熄屏会因为 BL_SAVE 是空的
    #        而用兜底 2048，把用户调好的亮度冲掉。）
    #   ② 标志=亮屏 但背光为 0 ⇒ 说明上次守护是被强杀的，屏幕还黑着 ⇒ 点亮。
    if not screen_is_off():
        if bl_get() == 0:
            log("启动自愈：标志是亮屏但背光为 0 ⇒ 强制点亮")
            screen_on()
        else:
            bl_save()
    else:
        log("启动：标志是熄屏，保持熄屏（背光=%s）" % bl_get())

    down_ts = {}
    last_act = {}
    off_since = time.time() if screen_is_off() else None

    while True:
        try:
            r, _, _ = select.select(list(fds), [], [], 5.0)
        except InterruptedError:
            continue

        # 熄屏看门狗：防止"守护挂了/逻辑卡住 ⇒ 屏幕永远黑着"
        if WATCHDOG_S > 0 and screen_is_off():
            if off_since is None:
                off_since = time.time()
            elif time.time() - off_since > WATCHDOG_S:
                log("熄屏看门狗触发（已 %ds）⇒ 强制亮屏" % WATCHDOG_S)
                screen_on()
                off_since = None
        else:
            off_since = None

        if not r:
            continue

        for fd in r:
            kind, dev, name = fds[fd]
            try:
                data = os.read(fd, EVENT.size)
            except OSError:
                # 设备消失/重插（例如 Android 侧重启输入子系统）⇒ 重探
                log("%s 读取出错，重新探测" % dev)
                try:
                    os.close(fd)
                except Exception:
                    pass
                del fds[fd]
                for d in (find_vol_devs() if kind == 'vol' else [find_pwr_dev()]):
                    if not d:
                        continue
                    nfd = open_dev(d)
                    if nfd is not None:
                        fds[nfd] = (kind, d, dev_name(
                            d.replace('/dev/input/', '/sys/class/input/')))
                continue
            if len(data) < EVENT.size:
                continue
            _, _, etype, code, value = EVENT.unpack(data)
            if etype != EV_KEY:
                continue

            now = time.time() * 1000.0

            # ── 音量键：按下即动作（不用等抬起，手感更跟手）──
            if code in (KEY_VOLUMEDOWN, KEY_VOLUMEUP):
                if value != 1:                      # 只在按下沿触发
                    continue
                if now - last_act.get(code, 0.0) < DEBOUNCE_MS:
                    continue
                last_act[code] = now
                ok, desc = volume_action(code)
                log("音量键 %s ⇒ %s（%s）"
                    % ('UP' if code == KEY_VOLUMEUP else 'DOWN',
                       desc, 'ok' if ok else '失败'))
                if ok:
                    osd(desc)
                continue

            # ── 电源键：只认短按，长按一律放行 ──
            if code == KEY_POWER:
                if value != 0:                       # 按下沿：只记时间
                    down_ts['pwr'] = now
                    continue
                t0 = down_ts.pop('pwr', None)
                if t0 is None:                       # 抬起但没有配对的按下
                    continue
                dur = now - t0
                if dur >= LONG_MS:
                    # ★★ 红线：长按是硬件级强制断电，唯一救砖手段。
                    #    我们**不 grab** 设备，所以长按照样能走到 PMIC。
                    log("电源键长按 %.0fms ⇒ 忽略（留给硬件强制断电/重启）" % dur)
                    continue
                if now - last_act.get(KEY_POWER, 0.0) < DEBOUNCE_MS:
                    continue
                last_act[KEY_POWER] = now
                log("电源键短按 %.0fms ⇒ 切换熄屏" % dur)
                screen_toggle()
                off_since = time.time() if screen_is_off() else None
                continue


# ─────────────────────── 自测（uinput 注入） ───────────────────────
def _other_daemon_pids(me):
    """找出**别的** drm-keys 进程（排除自己）。

    ★ 自测必须先把真守护挂起（SIGSTOP），原因（2026-10-12 实测踩过）：
      真守护和自测**共用同一块屏幕**（背光 sysfs、DPMS 都是全局的）。
      真守护的看门狗/自愈逻辑会往背光写值，和自测的判据打架，
      现象是自测第 2/4 步读到"背光=1"或 2048 而不是自测自己写的值 ——
      看起来像"保存/恢复逻辑坏了"，其实是两个进程在抢同一个硬件。
      只读的判据（音量）不受影响，写硬件的判据必须独占。
    """
    out = []
    try:
        for d in os.listdir('/proc'):
            if not d.isdigit() or int(d) == me:
                continue
            try:
                cl = open('/proc/%s/cmdline' % d, 'rb').read().decode(
                    'utf-8', 'replace').replace('\0', ' ')
            except Exception:
                continue
            if 'drm-keys.py' in cl:
                out.append(int(d))
    except Exception:
        pass
    return out


def selftest(stp=''):
    """用 uinput 注入虚拟按键，跑**完整的主循环逻辑**。

    ★ 为什么这样就能自证：注入走的是和真按键**完全相同**的内核 evdev 链路
      （input core → /dev/input/eventN），只是多一个虚拟设备。主循环读到的
      是同样的 24 字节 struct input_event。所以"注入有效果"证明"读键→动作"
      这段逻辑是对的；真设备能不能上报，由 evmon2.py 单独验证（已验证）。
    """
    import fcntl
    import threading

    name = b'keystest'
    ufd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(ufd, UI_SET_EVBIT, EV_KEY)
    for k in (KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_POWER):
        fcntl.ioctl(ufd, UI_SET_KEYBIT, k)
    setup = (struct.pack('HHHH', 0x03, 0x1234, 0x5678, 1) + name
             + b'\0' * (80 - len(name)) + struct.pack('I', 0))
    fcntl.ioctl(ufd, UINPUT_SETUP, setup)
    fcntl.ioctl(ufd, UI_DEV_CREATE)
    time.sleep(1.5)

    vdev = None
    for p in sorted(glob.glob('/sys/class/input/event*')):
        if dev_name(p) == 'keystest':
            vdev = '/dev/input/' + os.path.basename(p)
    if not vdev:
        fcntl.ioctl(ufd, UI_DEV_DESTROY)
        os.close(ufd)
        print("  ✗ 虚拟设备没出现")
        return 1
    print("  ✓ 虚拟设备 %s" % vdev)

    # ★ 必须改**模块级全局** —— find_* 读的是它，只改 os.environ 没用
    #   （上游踩过：自测静默地打开了真实电源键设备）。
    global FIXED_VOL, FIXED_PWR, NO_OSD, WATCHDOG_S, SKIP_LOCK
    FIXED_VOL = vdev
    FIXED_PWR = vdev
    NO_OSD = True
    WATCHDOG_S = 0

    # ★★ 必须**从干净状态开始**（2026-10-12 踩过）：
    #   状态文件（尤其 BL_SAVE）跨进程存活。上一次自测失败时留下的 BL_SAVE
    #   会让这一次的 bl_save() 沿用旧值，于是第 4 步"亮屏恢复原亮度"把屏幕
    #   恢复成**上一次测试时的**亮度 —— 判据失败，而且看起来像"保存/恢复
    #   逻辑坏了"，实际只是脏状态。
    for _f in (STATEF, BL_SAVE):
        try:
            os.unlink(_f)
        except Exception:
            pass
    print("  ✓ 状态已清空（STATEF/BL_SAVE）")

    # ★ 挂起真守护（见 _other_daemon_pids 的注释）：它和自测抢同一块屏幕。
    #   用 SIGSTOP/SIGCONT 而不是 kill：自测结束后真守护原样继续跑，
    #   不会因为跑一次自测就把用户的按键响应弄没。
    _suspended = []
    for _p in _other_daemon_pids(os.getpid()):
        try:
            os.kill(_p, signal.SIGSTOP)
            _suspended.append(_p)
        except Exception:
            pass
    if _suspended:
        print("  ✓ 已挂起真守护 %s（自测结束后恢复）"
              % ','.join(str(p) for p in _suspended))

    def _resume():
        for _p in _suspended:
            try:
                os.kill(_p, signal.SIGCONT)
            except Exception:
                pass

    # ★ 自测自己**显式持有**锁：这样 [5] 那步"第二个实例必须被拒绝"的判据
    #   才成立（拒绝的原因必须是自测占着锁，而不是真守护占着）。
    #   同时 run() 用 skip_lock=True 起，避免自测被真守护的锁挡掉。
    import fcntl as _fcntl
    _lockfd = None
    try:
        _lockfd = os.open(LOCKF, os.O_CREAT | os.O_RDWR, 0o644)
        _fcntl.flock(_lockfd, _fcntl.LOCK_EX | _fcntl.LOCK_NB)
        os.ftruncate(_lockfd, 0)
        os.write(_lockfd, str(os.getpid()).encode())
        print("  ✓ 自测已持有单例锁 %s" % LOCKF)
    except OSError as e:
        print("  ! 自测拿不到锁 %s: %s（[5] 判据可能不成立）" % (LOCKF, e))

    def _thread_main():
        # ★ 线程里抛的异常默认只打到 stderr 且可能被缓冲区吞掉，
        #   自测会表现成"所有判据全红但没有任何错误信息"（实测踩过）。
        #   这里显式抓出来。
        try:
            run(skip_lock=True)
        except BaseException:
            import traceback
            print("  ✗ 主循环线程异常：")
            traceback.print_exc()
            _resume()          # ★ 异常路径也必须恢复真守护，否则它一直停着

    t = threading.Thread(target=_thread_main, daemon=True)
    t.start()
    time.sleep(1.0)
    if not t.is_alive():
        print("  ✗ 主循环线程没活着（run() 提前返回或抛异常）")

    def emit(code, val):
        os.write(ufd, EVENT.pack(0, 0, EV_KEY, code, val))
        os.write(ufd, EVENT.pack(0, 0, EV_SYN, 0, 0))

    def press(code, ms):
        emit(code, 1)
        time.sleep(ms / 1000.0)
        emit(code, 0)

    fails = 0

    for _f in (STATEF, BL_SAVE):
        try:
            os.unlink(_f)
        except Exception:
            pass

    def check(label, cond, extra=''):
        nonlocal fails
        if cond:
            print("  ✓ %s %s" % (label, extra))
        else:
            print("  ✗ %s %s" % (label, extra))
            fails += 1

    # ── 1) 音量键 ──
    as_user(['pactl', 'set-sink-volume', '@DEFAULT_SINK@', '50%'])
    v0 = sink_volume()
    print("\n[1] 音量键：起始 %s%%" % v0)
    press(KEY_VOLUMEUP, 80)
    time.sleep(1.5)
    v1 = sink_volume()
    check("VOLUMEUP", v1 is not None and v0 is not None and v1 > v0,
          "%s%% → %s%%" % (v0, v1))
    press(KEY_VOLUMEDOWN, 80)
    time.sleep(1.5)
    v2 = sink_volume()
    check("VOLUMEDOWN", v2 is not None and v1 is not None and v2 < v1,
          "%s%% → %s%%" % (v1, v2))

    # ── 2) 电源键短按：熄屏 ──
    # ★ 先把背光设到一个**已知的非 1 值**再开始测。
    #   为什么不是"读当前值当基准"（2026-10-12 踩过）：接管后 sysfs 里
    #   常常是 1（安卓关机流程留下的残留），而 bl_save() 的判据是
    #   `v > 0` —— 恰好 1 是能通过的最小值，但它同时又是"没恢复成功"的
    #   症状值。基准和症状重合 ⇒ 判据无法区分成功与失败。
    TEST_BL = 1500
    bl_set(TEST_BL)
    time.sleep(0.5)
    orig_bl = bl_get()
    print("\n[2] 电源键短按：基准背光设为 %s / 标志 %s"
          % (orig_bl, screen_is_off()))
    if orig_bl != TEST_BL:
        print("  ! 基准背光没设成 %d（读到 %s）—— 后面第 4 步判据可能不准"
              % (TEST_BL, orig_bl))
    press(KEY_POWER, 120)
    time.sleep(3.0)
    check("短按 ⇒ 熄屏", screen_is_off() and bl_get() == 0,
          "背光=%s 标志=%s" % (bl_get(), screen_is_off()))

    # ── 3) 电源键长按：必须被忽略 ──
    print("\n[3] 电源键长按 (%dms)：期望被忽略、状态不变" % (LONG_MS + 1000))
    press(KEY_POWER, LONG_MS + 1000)
    time.sleep(2.0)
    check("长按被忽略", screen_is_off() and bl_get() == 0,
          "背光=%s 标志=%s" % (bl_get(), screen_is_off()))

    # ── 4) 再短按：亮屏并恢复原亮度 ──
    print("\n[4] 再短按：期望亮屏 + 背光恢复 %s" % orig_bl)
    press(KEY_POWER, 120)
    time.sleep(3.0)
    check("短按 ⇒ 亮屏", (not screen_is_off()) and bl_get() == orig_bl,
          "背光=%s（原 %s）标志=%s" % (bl_get(), orig_bl, screen_is_off()))

    # ── 5) 单例 ──
    print("\n[5] 单例保护：再起一个实例应当拒绝")
    # ★ 必须把 --state-prefix 一起传下去：否则第二个实例会去抢**真守护**的锁，
    #   于是"拒绝"的原因不是自测实例占着锁，而是真守护占着 —— 判据就不成立了。
    _argv = [sys.executable, os.path.abspath(__file__)]
    if stp:
        _argv.append('--state-prefix=' + stp)
    r = subprocess.run(_argv, capture_output=True, text=True, timeout=20)
    check("第二个实例被拒绝", '已有' in (r.stdout + r.stderr),
          (r.stdout + r.stderr).strip()[:60])

    # 收尾：确保屏幕是亮的，并**恢复真守护**
    if screen_is_off():
        screen_on()
    fcntl.ioctl(ufd, UI_DEV_DESTROY)
    os.close(ufd)
    _resume()
    if _suspended:
        print("  ✓ 已恢复真守护 %s" % ','.join(str(p) for p in _suspended))

    print("\n===== 自测结果：%s =====" % ('全部通过' if fails == 0 else '%d 项失败' % fails))
    # ★ 必须显式 flush：run() 在守护线程里，主线程 os._exit 会跳过缓冲区刷新
    #   （上游踩过：只看到守护日志、看不到自测结论）。
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(1 if fails else 0)


def status():
    detect_wayland_display()
    print("pidfile   : %s" % (open(PIDF).read().strip() if os.path.exists(PIDF) else '(无)'))
    print("桌面用户  : %s" % resolve_user())
    print("Wayland   : %s" % (WAYLAND_DISPLAY or '(没探到)'))
    print("背光节点  : %s" % BLDIR)
    print("当前背光  : %s" % bl_get())
    print("熄屏标志  : %s" % ('熄屏' if screen_is_off() else '亮屏'))
    print("音量设备  : %s" % (', '.join(find_vol_devs()) or '无'))
    print("电源设备  : %s" % (find_pwr_dev() or '无'))
    print("sink 音量 : %s%%  静音=%s" % (sink_volume(), sink_muted()))
    print("日志尾部  :")
    if os.path.exists(LOG):
        for line in open(LOG).read().splitlines()[-12:]:
            print("  " + line)
    return 0


# ─────────────────────── 入口 ───────────────────────
def cleanup(signum, frame):
    """收到 TERM/INT：把屏幕恢复亮，再退出。

    ★ 为什么必须做：守护被杀时如果屏幕是黑的，用户按电源键也没用了
      （没人在听），只能长按强制断电 —— 那会丢掉他正在做的工作。
    """
    global DAEMON
    if screen_is_off():
        try:
            screen_on()
        except Exception:
            pass
    log("收到信号 %s，退出（屏幕已恢复）" % signum)
    sys.exit(0)


if __name__ == '__main__':
    args = sys.argv[1:]
    # ★ --state-prefix 必须在读 STATEF 之前生效，而 STATEF 是模块级常量。
    #   自测专用：把状态文件挪到独立目录，避免踩到**正在跑的**守护
    #   （覆写 /run/drm-keys.pid 会让 --status / --stop 指向错误的 pid）。
    #   ★ 注意 STATEF 也要一起挪：否则自测的熄屏标志和真守护的打架，
    #     而 display/keepbright.sh 读的是 /run/drm-keys.screenoff。
    _stp = ''
    for _a in list(args):
        if _a.startswith('--state-prefix='):
            _stp = _a.split('=', 1)[1].rstrip('/')
            args.remove(_a)
    _STP = _stp                              # 供 selftest() 拼子进程 argv
    if _stp:
        os.makedirs(_stp, exist_ok=True)
        # ★ 走同一个 _state_paths()，别再手工拼一遍（两处拼法不一致
        #   正是上面那个"状态写入静默失败"bug 的成因）。
        PIDF, LOG, STATEF, BL_SAVE, LOCKF = _state_paths(_stp)
    if args and args[0] == '--selftest':
        sys.exit(selftest(_stp))
    if args and args[0] == '--status':
        sys.exit(status())

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    if args and args[0] == '-d':
        DAEMON = True
        if os.path.exists(PIDF):
            try:
                old = int(open(PIDF).read().strip())
                if old != os.getpid():
                    os.kill(old, signal.SIGKILL)
                    time.sleep(1)
            except Exception:
                pass
        pid = os.fork()
        if pid > 0:
            # 父进程等判据（pidfile 里是个活着的、不是自己的进程），不白等
            t = 0.0
            while t < 5.0:
                try:
                    p = int(open(PIDF).read().strip())
                    if p != os.getpid() and os.path.isdir('/proc/%d' % p):
                        print("drm-keys pid=%s" % p)
                        sys.exit(0)
                except Exception:
                    pass
                time.sleep(0.05)
                t += 0.05
            print("drm-keys 启动失败，看 %s" % LOG)
            sys.exit(1)
        os.setsid()
        with open('/dev/null', 'wb') as nul:
            os.dup2(nul.fileno(), 0)
            os.dup2(nul.fileno(), 1)
            os.dup2(nul.fileno(), 2)

    sys.exit(run())

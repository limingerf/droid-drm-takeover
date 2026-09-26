#!/bin/bash
# drm-takeover.sh — 以容器 ROOT 运行的一次性 DRM 试验编排。
# 流程: 开内核调试 → 停 SF+composer → 确认 master 释放 → 跑当前二进制 → 无论成败恢复安卓显示。
# 输出全部在 ../logs/drm-takeover.log
ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"
LOG=$LOGD/drm-takeover.log
exec >>"$LOG" 2>&1
set -x

if [ "${1:-}" = "--fuse" ]; then
    MAIN=$2; DEV=$3
    sleep 150
    if [ ! -f $DIR/takeover.ok ] && ! kill -0 "$MAIN" 2>/dev/null; then
        echo "FUSE: main script $MAIN dead, force-restoring"
        adb -s "$DEV" shell "su -c 'setprop ctl.start vendor.qti.hardware.display.composer; sleep 1; setprop ctl.start surfaceflinger; sleep 3; setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim'"
        adb -s "$DEV" shell input keyevent 224
        sleep 1
        adb -s "$DEV" shell input keyevent 224
    fi
    exit 0
fi

ADB=$(command -v adb)
DEV=""
# 优先本机 adb 传输（容器与 pad 同机；emulator-5554 型本地通道与 WiFi 生死无关）
LOCAL=$($ADB devices | awk '$2=="device"{print $1; exit}')
if [ -n "$LOCAL" ] && $ADB -s "$LOCAL" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
    DEV=$LOCAL
fi
for EP in 10.166.147.104:46213 10.166.147.104:33575 10.166.147.104:36933 10.166.147.104:36263 10.166.147.104:38851 10.166.147.104:44295 10.166.147.104:43439 10.166.147.104:36031 10.166.147.104:33549 10.166.147.104:38245 \
          172.16.42.159:36483 172.16.42.159:45525 172.16.42.159:5555; do
    [ -n "$DEV" ] && break
    $ADB connect $EP >/dev/null 2>&1
    if $ADB -s $EP shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        DEV=$EP
        break
    fi
done
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
echo "USING DEV $DEV"
run() { $ADB -s "$DEV" shell "su -c '$1'"; }

# Resolve the active container desktop account instead of baking in the
# upstream author's username/UID.
DESKTOP_USER=${DESKTOP_USER:-${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}}
[ -n "$DESKTOP_USER" ] || { echo "NO-DESKTOP-USER"; exit 1; }
DESKTOP_UID=$(id -u "$DESKTOP_USER")
DESKTOP_GID=$(id -g "$DESKTOP_USER")
DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
DESKTOP_RUNTIME_DIR=${DESKTOP_RUNTIME_DIR:-/run/user/$DESKTOP_UID}

# Android owns the input nodes; query the active NVT device while ADB is up,
# then recreate that exact node in the container for touchdraw/libinput.
TOUCH_EVENT=${TOUCH_EVENT:-$($ADB -s "$DEV" shell "su -c 'for d in /sys/class/input/input*; do [ \"\$(cat \"\$d/name\" 2>/dev/null)\" = \"NVTCapacitiveTouchScreen\" ] || continue; for e in \"\$d\"/event*; do basename \"\$e\"; exit; done; done'" | tr -d '\r' | head -1)}
case "$TOUCH_EVENT" in
    event[0-9]*) ;;
    *) echo "NO-TOUCH-EVENT [$TOUCH_EVENT]"; exit 1 ;;
esac
TOUCH_DEVT=$($ADB -s "$DEV" shell "su -c 'stat -c %t:%T /dev/input/$TOUCH_EVENT'" | tr -d '\r')
TOUCH_MAJOR_HEX=${TOUCH_DEVT%%:*}
TOUCH_MINOR_HEX=${TOUCH_DEVT#*:}
[ -n "$TOUCH_MAJOR_HEX" ] && [ -n "$TOUCH_MINOR_HEX" ] || { echo "BAD-TOUCH-DEVNUM [$TOUCH_DEVT]"; exit 1; }
TOUCH_MAJOR=$((16#$TOUCH_MAJOR_HEX))
TOUCH_MINOR=$((16#$TOUCH_MINOR_HEX))
TOUCH_NODE=/dev/input/$TOUCH_EVENT
echo "TOUCH $TOUCH_EVENT $TOUCH_MAJOR:$TOUCH_MINOR USER $DESKTOP_USER"

restore() {
    run "setprop ctl.start vendor.qti.hardware.display.composer; sleep 1; setprop ctl.start surfaceflinger; sleep 3; setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim"
    # 背光可能被留在 dim 最低档(≈2nit)→ 直接写 vendor brightness 属性
    $DIR/bin/setbright 2048 >/dev/null 2>&1
    $ADB -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
    sleep 1
    run "setprop ctl.stop bootanim"
    # 唤醒会被锁屏快速回睡吃掉：解 keyguard + 拉一个界面钉住 Awake
    $ADB -s "$DEV" shell "su -c 'wm dismiss-keyguard; am start -a android.settings.DISPLAY_SETTINGS'" >/dev/null 2>&1
    $ADB -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
    run "getprop init.svc.surfaceflinger"
    run "echo 0x0 > /sys/module/msm_drm/parameters/debug_level; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy; echo 0x0 > /sys/module/drm/parameters/debug"
}
if [ "${PERSIST:-0}" != 1 ]; then trap restore EXIT; fi

nohup setsid bash "$0" --fuse $$ "$DEV" >/dev/null 2>&1 < /dev/null &

# 内核侧调试（Android root 才有 /sys 写权限）。
# 实测 debug_level=0xffffffff 时每次 atomic ioctl 打印数百行，耗时 20-40ms，
# 直接压垮帧率 → 默认关，只有 DBG=1 的诊断轮才打开。
if [ "${DBG:-0}" = 1 ]; then
    run "dmesg -C; echo 0xffffffff > /sys/module/drm/parameters/debug; echo 0x3f > /sys/module/msm_drm/parameters/debugpolicy; echo 0xffffffff > /sys/module/msm_drm/parameters/debug_level"
else
    run "dmesg -C; echo 0x0 > /sys/module/drm/parameters/debug; echo 0x20 > /sys/module/msm_drm/parameters/debugpolicy; echo 0x0 > /sys/module/msm_drm/parameters/debug_level"
fi

# 18:29 incident (harvest logs): ~120s after SF stopped, system_server's own
# "watchdog" thread (tid 8224) killed system_server -> init cascade SIGKILLed
# wpa_supplicant/netd/zygote -> total WLAN loss (DRM holds screen, UI dead,
# force-reboot only). Disarm the watchdog BEFORE the clock starts:
#  watchdog_timeout = AOSP Watchdog ms (re-read every monitor cycle)
#  watchdog         = Xiaomi/MiUI watchdog on/off switch
#  nativehang*      = Xiaomi stability daemons that escalate hangs
#  stay_on          = PMS must never try to blank the (gone) display
[ "${PERSIST:-0}" = 1 ] && run "settings put global watchdog_timeout 86400000; settings put global watchdog 0; setprop persist.sys.stability.nativehang.enable false; setprop persist.sys.stability.nativehangII.enable false; setprop persist.sys.stability.qcom_hang_task.enable false; settings put global stay_on_while_plugged_in 7"

run "setprop ctl.stop surfaceflinger; setprop ctl.stop vendor.qti.hardware.display.composer"
rm -f $DIR/takeover.ok

# 设备/容器重启后手动节点会丢，master 检查之前必须先补
mkdir -p /dev/dri /dev/input
[ -c /dev/dri/card0 ] || mknod /dev/dri/card0 c 226 0
chmod 666 /dev/dri/card0 2>/dev/null
chmod 666 /dev/dri/renderD128 2>/dev/null
[ -c "$TOUCH_NODE" ] || mknod "$TOUCH_NODE" c "$TOUCH_MAJOR" "$TOUCH_MINOR"
chmod 666 "$TOUCH_NODE" 2>/dev/null

# kwin 用 libudev 枚举 DRM 设备，容器没有 udev daemon/db → "No suitable DRM
# devices"。合成 /run/udev/data 记录（systemd 259 格式，已用 bin/udevprobe 验证）。
# DRIVER=vmwgfx：kwin Hardware 白名单只收 i915/amdgpu/nouveau/vmwgfx，msm_drm
# 会被过滤；vmwgfx 在 kwin 里无特殊 quirk，最安全。
if [ ! -f /run/udev/data/c226:0 ] || ! grep -q DRIVER /run/udev/data/c226:0; then
    mkdir -p /run/udev/data
    printf 'Q:100\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0\nE:MAJOR=226\nE:MINOR=0\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/card0\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:0
    printf 'Q:101\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/renderD128\nE:MAJOR=226\nE:MINOR=128\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/renderD128\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:128
    chmod -R a+rX /run/udev
fi
if [ ! -f "/run/udev/data/c$TOUCH_MAJOR:$TOUCH_MINOR" ]; then
    mkdir -p /run/udev/data
    printf 'Q:100\nE:DEVPATH=/devices/virtual/input/%s\nE:MAJOR=%s\nE:MINOR=%s\nE:SUBSYSTEM=input\nE:DEVNAME=input/%s\nE:ID_INPUT=1\nE:ID_INPUT_TOUCH=1\nE:ID_INPUT_TOUCHSCREEN=1\nE:LIBINPUT_DEVICE_GROUP=%s/%s:NVTCapacitiveTouchScreen\nE:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1\nH:uaccess\nH:seat\n' "$TOUCH_EVENT" "$TOUCH_MAJOR" "$TOUCH_MINOR" "$TOUCH_EVENT" "$TOUCH_MAJOR" "$TOUCH_MINOR" > "/run/udev/data/c$TOUCH_MAJOR:$TOUCH_MINOR"
    chmod a+r "/run/udev/data/c$TOUCH_MAJOR:$TOUCH_MINOR"
fi

python3 - <<'EOF'
import os, time, fcntl, sys
SET_MASTER = 0x4004641E   # _IOR('d', 0x1e, __u32)
DROP_MASTER = 0x4004641F  # _IOW('d', 0x1f, __u32)
got = False
for attempt in range(30):
    fd = os.open('/dev/dri/card0', os.O_RDWR)
    try:
        fcntl.ioctl(fd, SET_MASTER)
        got = True
        fcntl.ioctl(fd, DROP_MASTER)
    except OSError as e:
        print('try', attempt, e)
        time.sleep(0.5)
    finally:
        os.close(fd)
    if got:
        break
print('MASTER FREE' if got else 'MASTER STILL BUSY after 15s')
sys.exit(0 if got else 1)
EOF
[ $? = 0 ] || exit 1

export HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 对照实验：master 空闲时 root 与 uid1000 各自能否 SET_MASTER
python3 - <<'EOF'
import os, fcntl
fd = os.open('/dev/dri/card0', os.O_RDWR)
try:
    fcntl.ioctl(fd, 0x4004641E)
    print('root SETMASTER OK')
    fcntl.ioctl(fd, 0x4004641F)
except OSError as e:
    print('root SETMASTER FAIL', e)
os.close(fd)
EOF
runuser -u "$DESKTOP_USER" -- python3 -c '
import os, fcntl
fd = os.open("/dev/dri/card0", os.O_RDWR)
try:
    fcntl.ioctl(fd, 0x4004641E)
    print("uid1000 SETMASTER OK")
    fcntl.ioctl(fd, 0x4004641F)
except OSError as e:
    print("uid1000 SETMASTER FAIL", e)
os.close(fd)
'

# 对照：纯 uid1000 直接开 / root kwinwrap fd 劫持后的 uid1000 子进程
runuser -u "$DESKTOP_USER" -- $DIR/bin/masterprobe; echo PURE-UID1000-PROBE=$?
env KWINWRAP_HIJACK=1 KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
    $DIR/bin/kwinwrap --out $LOGD/probe-hijack.log -- $DIR/bin/masterprobe
echo HIJACK-PROBE=$?
cat $LOGD/probe-hijack.log
# addGpu 检查链回放：A=真实 fd 但共享 kwinwrap 的 master 对象（join 语义）
runuser -u "$DESKTOP_USER" -- $DIR/bin/kwinwrap --out $LOGD/probe-a.log -- $DIR/bin/kwinprobe
echo PROBE-A=$?
# B=劫持 fd 250（与 kwinwrap 同一 file_priv，is_master=1）
env KWINWRAP_HIJACK=1 KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
    $DIR/bin/kwinwrap --out $LOGD/probe-b.log -- $DIR/bin/kwinprobe
echo PROBE-B=$?

if [ "${MODE:-touchdraw}" = kwin ]; then
    # kwin 只是合成器：后台起它，再起一个会画窗口的客户端作证据
    # kwin 必须 uid1000 跑（root kwin 被系统策略秒 SIGKILL）。
    # 教训：本机 vendor 内核/KernelSU 在 ptrace 上下文里拒绝 SET_MASTER
    #（纯 uid1000 不被 trace 时 OK，一旦被 trace 连自调都 -13）。
    # 故 Plan C fd 劫持：root kwinwrap fork 前开 card0 拿 master，
    # dup 到 fd 250 被子进程继承；kwin 每次 openat card0 的返回值被改写成
    # 250 → kwin 手上的 fd 天生就是 master，无需任何 master ioctl。
    if [ "${STRACE:-0}" = 1 ]; then
        # 诊断轮：不加 ptrace 干预，纯 strace 看 kwin 枚举/打开 DRM 的全部文件动作
        runuser -u "$DESKTOP_USER" -- env -u DISPLAY -u WAYLAND_DISPLAY HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
            strace -f -qq -e trace=%file,%stat \
                -o $LOGD/kwinstrace.log \
            kwin_wayland --drm --socket=taketest \
            > $LOGD/kwin.log 2>&1 &
    else
    env KWINWRAP_HIJACK=1 KWINWRAP_LEASE=1 KWINWRAP_SECCOMP=1 \
        KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
        $DIR/bin/kwinwrap --out $LOGD/kwinatomic.log -- \
        env -u DISPLAY -u WAYLAND_DISPLAY -u ANLAND -u ANLAND_SOCKET -u ANLAND_DRM_DEVICE -u MESA_LOADER_DRIVER_OVERRIDE -u GALLIUM_DRIVER -u FD_FORCE_KGSL HOME="$DESKTOP_HOME" \
            KWIN_DRM_DEVICES=/dev/dri/card0 \
            FD_MESA_DEBUG=noubwc \
            KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
            XDG_SESSION_ID=bogus \
            XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
            kwin_wayland --drm --socket=taketest \
        > $LOGD/kwin.log 2>&1 &
    fi
    KPID=$!
    sleep 5
    if kill -0 $KPID 2>/dev/null; then
        echo "kwin pid $KPID alive after 5 s"
        runuser -u "$DESKTOP_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
            HOME="$DESKTOP_HOME" XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            QT_QPA_PLATFORM=wayland \
            timeout 5 wayland-info > $LOGD/wayland-info.log 2>&1
        echo "wayland-info exit=$?"
        if [ "${PERSIST:-0}" = 1 ]; then
            # panic-safety: previous persistent run died because Android kept
            # entering suspend (composer dead => PMS blanks => system_suspend
            # writes /sys/power/state every ~3 s; WLAN fails suspend -> loop;
            # eventually a QTEE SMC jammed and hangdetect BUGged at 1451).
            # system_suspend is the only writer of suspend requests on Android,
            # stopping it kills the loop at the source; wake_lock is a 2nd belt.
            # (watchdog/nativehang disarm already done pre-SF-stop above)
            run "setprop ctl.stop system_suspend; echo qoderdbg > /sys/power/wake_lock; settings put system screen_off_timeout 2147483647; echo 2048 > /sys/class/backlight/panel0-backlight/brightness"
            # 18:47 proof: settings-based watchdog disarm is IGNORED by HyperOS
            # (killed again at +117 s; watchdog dump then arms hangdetect ->
            # BUG hang_detect.c:1451 panic at +210 s). Only reliable neutraliser
            # left: freeze system_server itself — no timers, no watchdog, no
            # PMS blank attempts, and wpa_supplicant keeps running as it is a
            # separate process. drm-stop.sh MUST SIGCONT it back.
            run "kill -STOP \$(pidof system_server)"
            touch $DIR/takeover.ok
            DEV=$DEV nohup bash $DIR/scripts/keepbright.sh > /dev/null 2>&1 &
            DEV=$DEV nohup bash $DIR/scripts/dmesg-harvester.sh > /dev/null 2>&1 &
            sleep 2
            run "getprop init.svc.system_suspend; cat /sys/power/wake_lock; grep State /proc/\$(pidof system_server)/status"
            run "dmesg" > $LOGD/dmesg-raw.log 2>/dev/null
            echo "PERSIST: kwin pid $KPID alive, panel stays with kwin. Run bin/drm-stop.sh to restore Android."
            exit 0
        fi
        ( for i in 1 2 3; do
              sleep 5
              echo "=== snap $i $(date +%T) ==="
              runuser -u "$DESKTOP_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
                  HOME="$DESKTOP_HOME" XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
                  timeout 8 grim $LOGD/kwinframe_$i.png 2>&1
              run "mount -t debugfs none /sys/kernel/debug 2>/dev/null; echo '--- state ---'; cat /sys/kernel/debug/dri/0/state; echo '--- framebuffer ---'; cat /sys/kernel/debug/dri/0/framebuffer"
          done ) > $LOGD/kmssummary.log 2>&1 &
        SNAP=$!
        runuser -u "$DESKTOP_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
            HOME="$DESKTOP_HOME" XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            timeout 25 es2gears_wayland > $LOGD/es2gears.log 2>&1 &
        ES=$!
        runuser -u "$DESKTOP_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
            HOME="$DESKTOP_HOME" XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            timeout 25 $DIR/bin/touchtest > $LOGD/touchtest.log 2>&1 &
        TT=$!
        sleep 3
        runuser -u "$DESKTOP_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
            HOME="$DESKTOP_HOME" XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
            timeout 20 $DIR/bin/touchinj 18 "$TOUCH_NODE" > $LOGD/touchinj.log 2>&1 &
        wait $ES; echo "es2gears exit=$?"
        wait $TT; echo "touchtest exit=$?"
        kill $SNAP 2>/dev/null
    else
        echo "kwin DIED early; kwin.log:"
        cat $LOGD/kwin.log
    fi
    kill -INT $KPID 2>/dev/null
    sleep 3
    kill -9 $KPID 2>/dev/null   # kwinwrap 带 PTRACE_O_EXITKILL，连坐杀 kwin
    pkill -9 -f "socket=taketest" 2>/dev/null
    wait $KPID 2>/dev/null
    echo "kwin stopped"
else
    TOUCH_EVENT="$TOUCH_NODE" $DIR/bin/touchdraw /dev/dri/card0 "${TOUCHDRAW_SECS:-90}"
fi
echo "DRMTEST_EXIT=$?"
run "dmesg" > $LOGD/dmesg-raw.log 2>/dev/null
grep -iE 'drm|sde|atomic|propert|commit' $LOGD/dmesg-raw.log | tail -n 400 > $LOGD/dmesg.log
touch $DIR/takeover.ok
echo "TAKEOVER SCRIPT DONE"

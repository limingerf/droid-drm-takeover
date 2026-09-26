#!/bin/bash
# kwin-restart.sh — 常驻接管模式下只重启容器侧 kwinwrap+kwin(不碰 Android 桌面)。
# 以 root 运行。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"
DESKTOP_USER=${DESKTOP_USER:-${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}}
[ -n "$DESKTOP_USER" ] || { echo "NO-DESKTOP-USER"; exit 1; }
DESKTOP_UID=$(id -u "$DESKTOP_USER")
DESKTOP_GID=$(id -g "$DESKTOP_USER")
DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
DESKTOP_RUNTIME_DIR=${DESKTOP_RUNTIME_DIR:-/run/user/$DESKTOP_UID}
pkill -9 -f "kwinwrap --out" 2>/dev/null
pkill -9 -f "socket=taketest" 2>/dev/null
sleep 1
chmod 666 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null
env KWINWRAP_HIJACK=1 KWINWRAP_SECCOMP=1 KWINWRAP_FILTER=1 \
    KWINWRAP_UID="$DESKTOP_UID" KWINWRAP_GID="$DESKTOP_GID" \
    "$DIR/bin/kwinwrap" --out $LOGD/kwinatomic.log -- \
    env -u DISPLAY -u WAYLAND_DISPLAY -u ANLAND -u ANLAND_SOCKET -u ANLAND_DRM_DEVICE -u MESA_LOADER_DRIVER_OVERRIDE -u GALLIUM_DRIVER -u FD_FORCE_KGSL HOME="$DESKTOP_HOME" \
        KWIN_DRM_DEVICES=/dev/dri/card0 \
        FD_MESA_DEBUG=noubwc \
        KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
        XDG_SESSION_ID=bogus \
        XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS=unix:path=$DESKTOP_RUNTIME_DIR/bus \
        kwin_wayland --drm --socket=taketest \
    > $LOGD/kwin.log 2>&1 &
KPID=$!
sleep 5
if kill -0 $KPID 2>/dev/null; then
    echo "KWIN-RESTART OK pid=$KPID"
    grep -iE "input|libinput|touch" $LOGD/kwin.log | tail -8
else
    echo "KWIN-RESTART FAILED; kwin.log tail:"; tail -15 $LOGD/kwin.log
fi

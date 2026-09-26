#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
ADB=${ADB:-adb}
DEV=${ANDROID_SERIAL:-$($ADB devices | awk '$2=="device"{print $1; exit}')}
REMOTE_ROOT=${REMOTE_ROOT:-/root/droid-drm-takeover}
OUT=${OUT:-$ROOT/logs}
if [ -z "$DEV" ]; then
  echo "NO-ADB-DEVICE"
  exit 1
fi
TMP=/data/local/tmp/drm-diag
mkdir -p "$OUT"

restore() {
  "$ADB" -s "$DEV" shell su -c 'setprop ctl.start vendor.qti.hardware.display.composer; sleep 1; setprop ctl.start surfaceflinger; sleep 3; setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim' >/dev/null 2>&1 || true
  "$ADB" -s "$DEV" shell input keyevent 224 >/dev/null 2>&1 || true
  echo RESTORE_ISSUED
}
trap restore EXIT

"$ADB" -s "$DEV" shell "su -c 'mkdir -p $TMP; dmesg -C; setprop ctl.stop surfaceflinger; setprop ctl.stop vendor.qti.hardware.display.composer'"
sleep 2

"$ADB" -s "$DEV" shell "su -c '/data/local/Droidspaces/bin/droidspaces --name=\"Linux\" run $REMOTE_ROOT/bin/masterprobe > $TMP/masterprobe.txt 2>&1'"

"$ADB" -s "$DEV" shell "su -c '/data/local/Droidspaces/bin/droidspaces --name=\"Linux\" run $REMOTE_ROOT/bin/kmsdump /dev/dri/card0 > $TMP/kmsdump.txt 2>&1'"

for tool in rawprobe stageprobe atombisect replicate; do
  "$ADB" -s "$DEV" shell "su -c '/data/local/Droidspaces/bin/droidspaces --name=\"Linux\" run $REMOTE_ROOT/bin/$tool /dev/dri/card0 > $TMP/$tool.txt 2>&1'"
done

"$ADB" -s "$DEV" shell "su -c 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; cat /sys/kernel/debug/dri/0/state > $TMP/state.txt 2>&1'"
"$ADB" -s "$DEV" shell "su -c 'dmesg > $TMP/dmesg.txt 2>&1'"

for f in masterprobe kmsdump rawprobe stageprobe atombisect replicate state dmesg; do
  "$ADB" -s "$DEV" pull "$TMP/$f.txt" "$OUT/drmdiag-$f.txt" >/dev/null 2>&1 || true
done

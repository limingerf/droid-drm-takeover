#!/bin/bash
# dmesg-harvester.sh — 接管期间周期收割安卓 dmesg 到外层 logs/harvest/（保留最近 15 份）。
# 断流/重启会清掉设备侧 ring 与 pstore，只有提前落盘才能留下断前现场。
# 用法: DEV=<adb端点> nohup bash dmesg-harvester.sh >/dev/null 2>&1 &
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}/harvest
mkdir -p "$LOGD"
while [ -f $DIR/takeover.ok ]; do
    ts=$(date +%m%d-%H%M%S)
    { date "+# local %F %T"; timeout -k 3 12 adb -s "$DEV" shell uptime; timeout -k 3 12 adb -s "$DEV" shell "su -c 'dmesg'"; } > "$LOGD/dmesg-$ts.log" 2>/dev/null
    ls -t "$LOGD"/dmesg-*.log 2>/dev/null | tail -n +16 | xargs -r rm -f
    sleep 20
done

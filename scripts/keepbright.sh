#!/bin/bash
# keepbright.sh — 常驻接管期间钉住背光，防止任何路径把亮度拉 0。
# 用法: DEV=<adb端点> nohup bash keepbright.sh >/dev/null 2>&1 &
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# 停止: pkill -f keepbright.sh
while [ -f $ROOT/takeover.ok ]; do
    adb -s "$DEV" shell "su -c 'echo 2048 > /sys/class/backlight/panel0-backlight/brightness'" >/dev/null 2>&1
    sleep 5
done

#!/bin/bash
NDK=/home/bai/android-ndk-r27c
OBJ=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
L=/mnt/c/Users/bai/Downloads/drm/probe/diag/libs/libagmclient.so
for sym in agm_session_aif_connect agm_session_set_config; do
  t=$($OBJ -d --disassemble-symbols=$sym $L 2>/dev/null | grep -oE 'b\s+0x[0-9a-f]+ <' | head -1 | grep -oE '0x[0-9a-f]+')
  echo "=== $sym  跳转目标=$t ==="
  if [ -n "$t" ]; then
    s=$((t)); e=$((t+0x70))
    $OBJ -d --start-address=$s --stop-address=$e $L 2>/dev/null | sed -n '6,40p' | grep -E 'mov|ldr|str|ldrb|bl|add|sub' | head -22
  fi
  echo
done
echo "=== 服务端 impl 里跟 first_device / backend 有关的字符串 ==="
strings -a /mnt/c/Users/bai/Downloads/drm/probe/diag/libs/vendor.qti.hardware.AGMIPC@1.0.so | grep -iE 'first_device|second_device|Backend|session_mode|NO_DEVICE|device_switch' | sort -u | head -20
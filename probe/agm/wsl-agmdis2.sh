#!/bin/bash
NDK=/home/bai/android-ndk-r27c
OBJ=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
L=/mnt/c/Users/bai/Downloads/drm/probe/diag/libs/libagmclient.so
echo "=== agm_session_open 实体 @0xab84 ==="
$OBJ -d --start-address=0xab84 --stop-address=0xac90 $L 2>&1 | sed -n '5,80p'
echo
echo "=== 对照 agm_get_aif_info_list 实体 @0xb99c（已知签名 OK）==="
$OBJ -d --start-address=0xb99c --stop-address=0xba70 $L 2>&1 | sed -n '5,60p'
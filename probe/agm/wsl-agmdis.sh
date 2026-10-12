#!/bin/bash
NDK=/home/bai/android-ndk-r27c
OBJ=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
L=/mnt/c/Users/bai/Downloads/drm/probe/diag/libs/libagmclient.so
echo "=== agm_session_open 反汇编（看参数怎么用）==="
$OBJ -d --disassemble-symbols=agm_session_open $L 2>&1 | head -45
echo
echo "=== agm_session_close 反汇编（已知签名 (session_id) 做对照）==="
$OBJ -d --disassemble-symbols=agm_session_close $L 2>&1 | head -25
echo
echo "=== agm_get_aif_info_list 反汇编（已知签名 (list, num*) 做对照）==="
$OBJ -d --disassemble-symbols=agm_get_aif_info_list $L 2>&1 | head -25
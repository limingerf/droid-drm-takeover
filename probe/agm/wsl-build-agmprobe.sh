#!/bin/bash
set -e
NDK=/home/bai/android-ndk-r27c
BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
CC=$BIN/aarch64-linux-android33-clang
cd /home/bai/argsloop-build
cp -f /mnt/c/Users/bai/Downloads/drm/probe/diag/agmprobe.c ./
echo "=== 编译 agmprobe ==="
$CC -std=gnu11 -O2 -fPIE -pie agmprobe.c -o agmprobe -ldl -lm 2>&1 | head -20
ls -l agmprobe
$BIN/llvm-readelf -d agmprobe | grep NEEDED
cp -f agmprobe /mnt/c/Users/bai/Downloads/drm/probe/diag/agmprobe
echo BUILD-OK
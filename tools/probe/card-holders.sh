#!/bin/sh
# tools/probe/card-holders.sh — 列出持有某个 DRM 节点的进程。
#
# 用法: sh card-holders.sh [/dev/dri/card0]
# 输出: 每行 "pid comm"（comm 读不到时只输出 pid）
#
# ══ 为什么单独抽成一个脚本 ══
# 这个扫描要在两侧跑（安卓 toybox / 容器 GNU），而调用方要么隔着
# `adb shell su -c '...'` 两层引号，要么在 shell 函数里。把 awk 程序
# 内联进那些字符串要转义三层引号 —— 本项目已经因此写出过两个
# "看起来对、实际永远匹配不上"的实现。抽成文件后只有一份真话。
#
# ══ 为什么不能直接 sed 抽 pid（血泪，务必别再犯）══
# `ls -l /proc/[0-9]*/fd` 传**多个**目录时会先打一行头
#     /proc/123/fd:
# 后面的 fd 行里**没有** /proc/ 前缀：
#     lrwx------ 1 root root 64 ... 11 -> /dev/dri/card0
# toybox 和 GNU coreutils 都是这个格式。所以任何
#     sed -n 's#^.*/proc/\([0-9]*\)/fd/.*#\1#p'
# 都永远匹配不上，结果**恒为空**。而"没有持有者"会被上层读成
# "composer 已经松手了" ⇒ 在错误的时刻接管 ⇒ kwin 拿到 master 但
# atomic 提交报 ret=-13(EACCES) ⇒ 有 master、不出画。
# 正确做法是**用 awk 跟踪头行**得到当前 pid（见下）。
#
# ══ 为什么不用 `for p in /proc/[0-9]*; do ls -l $p/fd; done` ══
# 那是对每个进程 fork 两次。720 进程的设备上单次调用上千次 fork，
# 而调用方每 0.5s 轮询一次 ⇒ 名义 15s 的等待实际拖成几十秒。

_node=${1:-/dev/dri/card0}

ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v want="$_node" '
    # 头行：记下当前是哪个 pid 的 fd 目录
    /\/fd:$/ {
        p = $0
        sub(/^.*\/proc\//, "", p)
        sub(/\/fd:$/, "", p)
        next
    }
    # fd 行：形如 `... 11 -> /dev/dri/card0`。
    # ★ 不要用 $(NF-1) 取 "->" —— 空行的 NF 是 0，$(NF-1) 就是 $(-1)，
    #   toybox awk 直接报 "trying to access out of range field -1"。
    #   改成纯字符串比较：行里有 "-> " 且以目标路径结尾。
    index($0, "-> ") > 0 && length($0) >= length(want) \
        && substr($0, length($0) - length(want) + 1) == want {
        if (p != "") print p
    }
' | sort -u | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _c=$(cat "/proc/$_p/comm" 2>/dev/null | head -1)
    if [ -n "$_c" ]; then
        printf '%s %s\n' "$_p" "$_c"
    else
        printf '%s\n' "$_p"
    fi
done

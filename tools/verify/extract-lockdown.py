#!/usr/bin/env python3
"""
从 Payload.java 里抽出 LOCKDOWN 常量，还原成它会在设备上执行的 shell 脚本。

【为什么需要它】
verify-apk-payload.sh 要拿"设备上真正会跑的那段脚本"来测落地权限。
如果测试里手抄一份，两边迟早漂移 —— 而漂移的后果正是这个测试要防的东西
（payload 落地后权限不对：脚本不可执行、或者 root 要执行的脚本居然对
group/other 可写）。

这个检查抓到过一次真问题：LOCKDOWN 原来逐个目录列举 `chmod 755`，
后来新增了 tools/ 目录没被列进去，于是 tools/verify/device-acceptance.sh
落地后是 644，而它在仓库里是 755。

只处理这个文件用到的那几种形式：字符串字面量 + 常量拼接。
"""
import re
import sys


def unescape(s):
    out, i = [], 0
    simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append(simple.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def const(src, name):
    m = re.search(
        r'String\s+' + re.escape(name) + r'\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', src
    )
    if not m:
        sys.exit(f"找不到常量 {name}")
    return unescape(m.group(1))


def main():
    if len(sys.argv) != 2:
        sys.exit("用法: extract-lockdown.py <Payload.java>")
    src = open(sys.argv[1], encoding="utf-8").read()

    # 语句体：从 `String LOCKDOWN =` 到 `;\n\n`（语句后的空行）。
    # 不能图省事写 `.*?;` —— 字符串字面量里本身就有分号（`"; "`）。
    m = re.search(
        r"private static final String LOCKDOWN\s*=\s*(.*?);\n\n", src, re.S
    )
    if not m:
        sys.exit("找不到 LOCKDOWN 语句")
    body = m.group(1)

    # 把常量拼接替换成字面量，好让下面的提取只处理字符串
    for name in ("MARKER", "OK", "BAD"):
        val = const(src, name)
        body = body.replace("+ " + name + " +", '+ "' + val + '" +')
        body = body.replace("+ " + name + ";", '+ "' + val + '";')

    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
    if not parts:
        sys.exit("LOCKDOWN 里没解析出任何字符串")

    sys.stdout.write("".join(unescape(p) for p in parts))


if __name__ == "__main__":
    main()

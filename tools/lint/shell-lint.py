#!/usr/bin/env python3
"""
shell-lint —— 静态检查脚本层的"链接错误"。

【为什么需要它】
本项目 56 个 shell 脚本互相 source，一个函数名拼错、一个设备上不存在的命令，
都只会在**执行到那一行**时才暴露。而那一行可能在接管过程中（屏幕已经归 Linux、
没有回显），或者更糟 —— 在"返回安卓"的路径上。到那时用户只能长按电源键。

`dash -n` 查不出这类问题：语法完全合法。

【它抓到过的真问题】
  · core/lib/display.sh 用 `fuser -k $DEV_DRM_CARD` 做最后兜底，
    而 fuser 在安卓 toybox 里根本不存在 —— 那条兜底在设备上从未生效过。
  · 同一个文件用 `pkill -f` / `pgrep -f` 按正则匹配整条命令行，
    会误伤"命令行里恰好提到该字符串"的无关进程（项目在 netd 那边踩过）。

【检查项】
  1. 项目命名空间的函数（drm_/android_/ds_/net_/dev_）被调用但无定义
  2. 变量被使用但从未赋值（跳过 ${VAR:-默认值} 这类合法覆盖）
  3. 调用了目标环境（安卓 toybox / 精简容器 rootfs）上不存在的命令
  4. bash 专有构造（mksh / dash 上会失败）

退出码：0 = 通过，1 = 有硬错误（未定义函数 / 缺失命令）
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKIP_PARTS = {".git", "bin", "build", "bin-rt", "build-rt", "node_modules"}

FUNC_PREFIXES = ("drm_", "android_", "ds_", "net_", "dev_")

# 目标环境上确实不存在的命令。每一条都有具体理由，不要随手加。
MISSING_CMDS = {
    "fuser": "安卓 toybox 没有（实测 'inaccessible or not found'）",
    "jq": "安卓上没有；所以状态文件用 key=value 而不是 JSON",
    "systemctl": "精简容器里不保证有 systemd",
    "pgrep": "按正则匹配整条命令行，会误伤无关进程；改用 drm_pids_by_comm",
    "pkill": "同上；改用 drm_kill_by_comm / drm_kill_by_cmdline",
    "getevent": "存在，但对触摸节点旁听会触发厂商安全联动；改用 bin/touchtest",
}

BASHISMS = [
    (re.compile(r"\[\["), "[[ ]]"),
    (re.compile(r"\]\]"), "[[ ]]"),
    (re.compile(r"(?:^|[;&|(])\s*function\s+\w+"), "function 关键字"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*//"), "${var//} 替换"),
    (re.compile(r"\$'"), "$'...'"),
    (re.compile(r"(?:^|[;&|(])\s*\w+\s*=\s*\("), "数组赋值"),
    (re.compile(r"(?:^|[;&|(])\s*declare\s"), "declare"),
    (re.compile(r"(?:^|[;&|(])\s*local\s+-[a-zA-Z]"), "local -x"),
    (re.compile(r"&>>"), "&>>"),
    (re.compile(r"<\("), "进程替换 <()"),
    (re.compile(r"(?:^|[;&|(])\s*select\s+\w+\s+in\b"), "select"),
]


def scripts():
    out = []
    for p in sorted(ROOT.rglob("*.sh")):
        rel = p.relative_to(ROOT)
        if set(rel.parts) & SKIP_PARTS:
            continue
        out.append(p)
    return out


def strip_comment(line):
    """去掉行内注释（不在引号里的 # 之后丢弃）。"""
    out, i, q = [], 0, None
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\":
                out.append(c)
                i += 1
                if i < len(line):
                    out.append(line[i])
                i += 1
                continue
            if c == q:
                q = None
            out.append(c)
        else:
            if c in "\"'":
                q = c
                out.append(c)
            elif c == "#":
                break
            else:
                out.append(c)
        i += 1
    return "".join(out)


def main():
    files = scripts()
    if not files:
        print("没找到任何 .sh —— 路径不对？", file=sys.stderr)
        return 1

    defined, defined_vars = {}, set()
    calls, uses = [], []

    for p in files:
        rel = str(p.relative_to(ROOT))
        text = p.read_text(encoding="utf-8", errors="replace")
        for n, raw in enumerate(text.split("\n"), 1):
            line = strip_comment(raw)

            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{?", line)
            if m:
                defined.setdefault(m.group(1), []).append(f"{rel}:{n}")
                continue
            m = re.match(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if m:
                defined.setdefault(m.group(1), []).append(f"{rel}:{n}")
                continue

            for vm in re.finditer(
                r"(?:^|[\s;(])(?:export\s+|local\s+|readonly\s+)?"
                r"([A-Za-z_][A-Za-z0-9_]*)=", line
            ):
                defined_vars.add(vm.group(1))
            for vm in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*):=", line):
                defined_vars.add(vm.group(1))
            for vm in re.finditer(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", line):
                defined_vars.add(vm.group(1))
            for vm in re.finditer(r"\bread\s+(?:-r\s+)?([A-Za-z_][A-Za-z0-9_]*)", line):
                defined_vars.add(vm.group(1))

            for cm in re.finditer(
                r"(?:^|[;&|({]|\$\()\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:[)\s;&|]|$)", line
            ):
                if cm.group(1).startswith(FUNC_PREFIXES):
                    calls.append((cm.group(1), rel, n, raw.strip()))

            # ★ 负向先行断言在这里是错的：贪婪的 [A-Za-z0-9_]* 会回溯到让断言
            #   成立的位置，把名字截断（PERSIST → PERSIS）。匹配完再看后一个字符。
            for um in re.finditer(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", line):
                name = um.group(1)
                nxt = line[um.end():um.end() + 1]
                if nxt in ":+-=?":      # ${VAR:-默认值} 等，无需先赋值
                    continue
                if name.startswith(FUNC_PREFIXES) or name.isupper():
                    uses.append((name, rel, n, raw.strip()))

    undef, undef_vars, missing, bash_hits = {}, {}, {}, {}

    for name, rel, n, line in calls:
        if name not in defined:
            undef.setdefault(name, []).append((rel, n, line))
    for name, rel, n, line in uses:
        if name not in defined_vars:
            undef_vars.setdefault(name, []).append((rel, n, line))

    for p in files:
        rel = str(p.relative_to(ROOT))
        for n, raw in enumerate(p.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
            line = strip_comment(raw)
            for cmd in MISSING_CMDS:
                if re.search(rf"(?:^|[;&|(]|\$\()\s*{re.escape(cmd)}\s", line):
                    missing.setdefault(cmd, []).append((rel, n, raw.strip()))
            for rx, label in BASHISMS:
                if rx.search(line):
                    bash_hits.setdefault(label, []).append((rel, n, raw.strip()))

    def section(title):
        print()
        print("═" * 70)
        print(title)
        print("═" * 70)

    print(f"shell-lint: 检查 {len(files)} 个脚本")

    section("1) 调用了但从未定义的函数")
    if undef:
        for name in sorted(undef):
            print(f"\n  ❌ {name}  （{len(undef[name])} 处调用）")
            for rel, n, line in undef[name][:4]:
                print(f"       {rel}:{n}  {line[:90]}")
    else:
        print("  ✅ 没有未定义的函数调用")

    section("2) 使用了但从未赋值的变量")
    if undef_vars:
        for name in sorted(undef_vars):
            print(f"\n  ⚠️  {name}  （{len(undef_vars[name])} 处使用）")
            for rel, n, line in undef_vars[name][:3]:
                print(f"       {rel}:{n}  {line[:90]}")
        print("\n  （如果是纯环境变量覆盖，忽略即可；否则是拼写错误）")
    else:
        print("  ✅ 没有未定义的变量")

    section("3) 调用了目标环境上不存在的命令")
    if missing:
        for cmd in sorted(missing):
            print(f"\n  ❌ {cmd} —— {MISSING_CMDS[cmd]}")
            for rel, n, line in missing[cmd][:5]:
                print(f"       {rel}:{n}  {line[:90]}")
    else:
        print("  ✅ 没有调用已知缺失的命令")

    section("4) bash 专有构造（mksh/dash 上会失败）")
    if bash_hits:
        for label in sorted(bash_hits):
            print(f"\n  ❌ {label}")
            for rel, n, line in bash_hits[label][:5]:
                print(f"       {rel}:{n}  {line[:90]}")
    else:
        print("  ✅ 没有 bash 专有构造")

    hard = len(undef) + len(missing) + len(bash_hits)
    print()
    print("═" * 70)
    print(f"汇总：未定义函数 {len(undef)}，缺失命令 {len(missing)}，"
          f"bash 构造 {len(bash_hits)}，未定义变量 {len(undef_vars)}（软告警）")
    print("═" * 70)
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())

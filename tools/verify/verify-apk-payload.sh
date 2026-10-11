#!/bin/sh
# tools/verify/verify-apk-payload.sh — 端到端验证 APK 的 payload 落地链路
#
# 【为什么需要它】
# 设备上 payload 的落地链路是：
#
#   APK 的 assets/payload/**
#     → Payload.extractToPrivate()   解到应用私有目录
#     → Tar.writeTree()              打成 tar 流（手写的 USTAR 编码器）
#     → su -c 'tar -x -f - -C $D'    root 侧还原
#     → LOCKDOWN                     收权限
#
# 这条链路里全是"本地看起来没问题、到设备上才炸"的东西：
#   · 手写 USTAR 编码器 → toybox tar 能不能读
#   · 落地权限 → bin/kwinwrap 是被**直接 exec** 的，644 就 Permission denied
#   · 换行符 → CRLF 会让 `#!/bin/sh\r` 变成 "not found"
#   · LOCKDOWN 里的 chmod 列举漏了目录 → 仓库里是 755、设备上是 644
#
# 这个脚本把每一步都在本地跑一遍，最后逐字节比对往返结果。
# 它抓到过一次真问题：LOCKDOWN 逐个目录列举 chmod，新增 tools/ 后漏掉，
# device-acceptance.sh 落地是 644 而仓库里是 755。
#
# 用法：
#   sh tools/verify/verify-apk-payload.sh [apk路径]
#
# 需要 javac（编译 Tar.java）和 python3（解析 LOCKDOWN）。
# 缺任何一个就跳过并返回 0 —— 这是开发期检查，不该挡住没装 JDK 的人。

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
ROOT=$(cd "$SELF_DIR/../.." 2>/dev/null && pwd) || exit 1
APK=${1:-$ROOT/android/build/drmswitch.apk}
T=${TMPDIR:-/tmp}/drm-payload-verify.$$

fail=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

say() { printf '%s\n' "$*"; }
bad() { say "❌ $*"; fail=1; }

if [ ! -f "$APK" ]; then
    say "找不到 APK: $APK"
    say "先跑 sh android/build.sh"
    exit 1
fi

if ! command -v javac >/dev/null 2>&1; then
    say "⏭️  没有 javac —— 跳过（装个 JDK 再来，这一步值得跑）"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    say "⏭️  没有 python3 —— 跳过"
    exit 0
fi

mkdir -p "$T/priv" "$T/D" "$T/src/dev/limingerf/drmswitch" "$T/classes" || exit 1

say "═══ 1) 编译 Tar.java + TarTest.java ═══"
cp "$ROOT/android/app/src/dev/limingerf/drmswitch/Tar.java" \
   "$T/src/dev/limingerf/drmswitch/" || exit 1
cp "$ROOT/tools/verify/TarTest.java" "$T/src/dev/limingerf/drmswitch/" || exit 1
javac -d "$T/classes" "$T/src/dev/limingerf/drmswitch/"*.java || {
    say "javac 失败"; exit 1
}
say "ok"

say ""
say "═══ 2) 从 APK 解出 assets/payload（模拟 extractToPrivate）═══"
unzip -q -o "$APK" 'assets/payload/*' -d "$T/priv" || { say "unzip 失败"; exit 1; }
mv "$T/priv/assets/payload" "$T/priv_tree" || exit 1
n_priv=$(find "$T/priv_tree" -type f | wc -l | tr -d ' ')
n_bin=$(ls -1 "$T/priv_tree/bin" 2>/dev/null | wc -l | tr -d ' ')
say "assets 里的文件数: $n_priv"
say "payload/bin 产物数: $n_bin"

# ★ 这一条是"APK 里到底有没有二进制"的硬判据。
#   第一次跑 CI 时 apk job 没先跑 make，做出了一个"脚本齐全、零二进制"的 APK。
if [ "$n_bin" -ge 24 ]; then
    say "✅ bin/ 有 $n_bin 个产物"
else
    bad "bin/ 只有 $n_bin 个产物（期望 >= 24）—— APK 打包时没带 bin/"
fi

say ""
say "═══ 3) Tar.writeTree 打成 tar 流 ═══"
java -cp "$T/classes" dev.limingerf.drmswitch.TarTest "$T/priv_tree" "$T/payload.tar" \
    || { say "TarTest 失败"; exit 1; }

say ""
say "═══ 4) tar -x 还原（设备上由 su 执行）═══"
tar -x -f "$T/payload.tar" -C "$T/D" || { say "tar -x 失败"; exit 1; }
n_D=$(find "$T/D" -type f | wc -l | tr -d ' ')
say "还原出的文件数: $n_D"

say ""
say "═══ 5) 逐字节比对 ═══"
if diff -r "$T/priv_tree" "$T/D" >"$T/diff.txt" 2>&1; then
    say "✅ tar 往返逐字节一致"
else
    bad "tar 往返有差异"
    head -30 "$T/diff.txt"
fi

say ""
say "═══ 6) 跑 LOCKDOWN（★ 直接从 Payload.java 解析，不是手抄）═══"
python3 "$ROOT/tools/verify/extract-lockdown.py" \
    "$ROOT/android/app/src/dev/limingerf/drmswitch/Payload.java" >"$T/lockdown.sh" \
    || { say "解析 LOCKDOWN 失败"; exit 1; }
sed 's/^/    /' "$T/lockdown.sh"

if D="$T/D" sh "$T/lockdown.sh" | grep -q DRM_PAYLOAD_OK; then
    say "✅ LOCKDOWN 跑通并打印了 DRM_PAYLOAD_OK"
else
    bad "LOCKDOWN 没打印 DRM_PAYLOAD_OK（core/switch.sh 没落地？）"
fi

say ""
say "═══ 7) 权限校验 ═══"
d_mode=$(stat -c '%a' "$T/D" 2>/dev/null || stat -f '%Lp' "$T/D" 2>/dev/null)
if [ "$d_mode" = "700" ]; then
    say "✅ 目录模式 700"
else
    bad "目录模式 $d_mode（应为 700）"
fi

go_w=$(find "$T/D" \( -perm -0020 -o -perm -0002 \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$go_w" = "0" ]; then
    say "✅ 没有 group/other 可写的条目"
else
    bad "有 $go_w 个 group/other 可写条目"
    find "$T/D" \( -perm -0020 -o -perm -0002 \) 2>/dev/null | head
fi

badx=0
for b in "$T/D"/bin/*; do
    [ -f "$b" ] || continue
    [ -x "$b" ] || { say "❌ bin/$(basename "$b") 不可执行"; badx=$((badx+1)); }
done
if [ "$badx" = "0" ]; then
    say "✅ bin/ 全部可执行（$(ls -1 "$T/D/bin" | wc -l | tr -d ' ') 个）"
else
    fail=1
fi

badx=0; n_sh=0
for s in $(find "$T/D" -name '*.sh' -o -name '*.py'); do
    n_sh=$((n_sh+1))
    [ -x "$s" ] || { say "❌ ${s#$T/D/} 不可执行"; badx=$((badx+1)); }
done
if [ "$badx" = "0" ]; then
    say "✅ 全部 $n_sh 个 .sh/.py 可执行"
else
    fail=1
fi

say ""
say "═══ 8) 关键产物在位 ═══"
for f in core/switch.sh core/lib/common.sh bin/kwinwrap bin/setbright \
         linux/session-up.sh linux/drm-switch.sh display/kill-desktop.sh \
         tools/verify/device-acceptance.sh android/enter.sh android/exit-watch.sh; do
    if [ -f "$T/D/$f" ]; then
        say "✅ $f"
    else
        bad "缺 $f"
    fi
done

say ""
say "═══ 9) 换行符与静态检查 ═══"
if head -1 "$T/D/core/switch.sh" | grep -q "$(printf '\r')"; then
    bad "core/switch.sh 首行含 CR —— 设备上会 'not found'"
else
    say "✅ 首行无 CR（LF 换行）"
fi
crlf=$(find "$T/D" -name '*.sh' -exec grep -lI "$(printf '\r')" {} + 2>/dev/null | wc -l | tr -d ' ')
if [ "$crlf" = "0" ]; then
    say "✅ 没有 .sh 含 CR"
else
    bad "$crlf 个 .sh 含 CR"
fi

if python3 "$T/D/tools/lint/shell-lint.py" >/dev/null 2>&1; then
    say "✅ 还原后的树通过 shell-lint"
else
    say "⚠️  还原后的树 shell-lint 有告警"
fi

say ""
say "════════════════════════════════════════"
if [ "$fail" = "0" ]; then
    say " 全部通过 —— APK 的 payload 落地链路可信"
else
    say " 有失败项"
fi
say "════════════════════════════════════════"
exit "$fail"

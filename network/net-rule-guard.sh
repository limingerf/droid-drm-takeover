#!/bin/sh
# net-rule-guard.sh —— 策略路由看门狗：周期性确认那两条 rule 还在
#
# ══════════════════════════════════════════════════════════════════════
# 为什么必须有它（2026-10-12 实测，别删）
# ══════════════════════════════════════════════════════════════════════
#
# 症状：WiFi 明明连着、地址和默认路由都对，ping 任何地址都是
#       "Network is unreachable"，连同一子网的网关都不通。
#
# 实测到的现场（两处必须同时成立才会断）：
#     ① ip rule 里 31000/31500 两条**凭空消失**
#     ② 但 main 表和 1042 表里的路由**完好无损**
#   ⇒ 没有任何规则指向 main/1042，兜底的 `32000: from all unreachable`
#     把全部流量吃掉 ⇒ 断网。DNS 也一起死，很容易误判成 DNS 问题。
#
# ★ 为什么 NM dispatcher 兜不住：
#   dispatcher 只在 NM **事件**（up / dhcp4-change / reapply）时被调用。
#   而本机是 net_mode=host，容器和 Android **共用同一个网络栈** ——
#   Android 的 netd 会周期性重整它自己的策略路由，顺手把我们的两条删掉。
#   删的时候**不产生任何 NM 事件**，所以 dispatcher 永远等不到，
#   规则就这么一直缺着。这正是"修好又坏、修好又坏"的原因。
#
# ⇒ 所以 dispatcher 负责"事件驱动的快速恢复"，本看门狗负责
#   "没人通知我们时的兜底"。两者都要，缺一不可。
#
# ⚠️ 红线：只新增/纠正，绝不 `ip rule flush`，绝不删 netd 的任何
#   rule/table，绝不 `ip link set wlan0 up/down`，绝不改 net_mode。
#
# 用法：
#   net-rule-guard.sh            常驻循环（默认 1 秒一轮）
#   net-rule-guard.sh --once     只跑一次（自检/调试）
#   net-rule-guard.sh --status   打印当前状态后退出
#   INTERVAL=5 net-rule-guard.sh 自定义间隔
#
# ★ 为什么间隔是 1 秒而不是 15 秒：
#   实测规则每 75-90 秒被删一次，15 秒间隔虽然能补回来，但每次断网最多
#   15 秒 —— 用户是能感觉到的（网页转圈、SSH 卡住）。降到 1 秒后断网
#   窗口 ≤1 秒，基本无感。代价只有每秒一次 `ip rule show`（约 1 毫秒，
#   即单核的 0.1%），完全不值得省。

set -u

INTERVAL=${INTERVAL:-1}
LOG=${LOG:-/var/log/drm-net-guard.log}
FIX=${FIX:-/usr/local/lib/droid-drm-takeover/route-rule-fix.sh}
[ -x "$FIX" ] || FIX=/root/droid-drm-takeover/network/route-rule-fix.sh
[ -x "$FIX" ] || FIX=$(dirname "$0")/route-rule-fix.sh

# 需要存在的两条 rule 的 pref（与 route-rule-fix.sh 保持一致）
MAIN_PREF=31000
TBL_PREF=31500
IFACE=${IFACE:-wlan0}

_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

# 返回缺失的 pref 列表（空 = 都齐）
_missing() {
    _m=""
    ip rule show 2>/dev/null | grep -q "^$MAIN_PREF:" || _m="$MAIN_PREF"
    ip rule show 2>/dev/null | grep -q "^$TBL_PREF:"  || _m="$_m $TBL_PREF"
    printf '%s' "$_m"
}

# 接口上有没有 IPv4（没地址就别折腾，等它拿到）
_has_v4() {
    ip -4 -o addr show "$IFACE" 2>/dev/null | grep -q 'inet '
}

_status() {
    echo "接口 $IFACE:"
    ip -4 -o addr show "$IFACE" 2>/dev/null | sed 's/^/  /'
    echo "规则:"
    ip rule show 2>/dev/null | grep -aE "^($MAIN_PREF|$TBL_PREF):" | sed 's/^/  /'
    echo "main 默认路由:"
    ip -4 route show table main 2>/dev/null | grep -a default | sed 's/^/  /'
    echo "表 1042:"
    ip -4 route show table 1042 2>/dev/null | sed 's/^/  /'
    echo "缺失的 pref:$( _missing )"
}

case "${1:-}" in
    --status)
        _status
        exit 0
        ;;
    --once)
        if ! _has_v4; then echo "  $IFACE 没有 IPv4，跳过"; exit 0; fi
        M=$(_missing)
        if [ -z "$M" ]; then echo "  两条 rule 都在，无需动作"; exit 0; fi
        echo "  缺:$M ⇒ 调用 $FIX"
        sh "$FIX" 2>&1 | tail -6 | sed 's/^/    /'
        exit 0
        ;;
esac

# ── 常驻循环 ─────────────────────────────────────────────────────
_log "看门狗启动：间隔 ${INTERVAL}s，接口 $IFACE，修复脚本 $FIX"
echo "net-rule-guard: 间隔 ${INTERVAL}s，日志 $LOG（Ctrl-C 退出）"

while :; do
    if _has_v4; then
        M=$(_missing)
        if [ -n "$M" ]; then
            _log "★ 检测到规则缺失:$M ⇒ 重新挂上"
            sh "$FIX" >>"$LOG" 2>&1
            # 复查：补完还缺就是真出问题了，记下来别静默
            M2=$(_missing)
            if [ -n "$M2" ]; then
                _log "!! 补完仍缺:$M2（需要人工看）"
            else
                _log "已恢复：两条 rule 都在了"
            fi
        fi
    fi
    sleep "$INTERVAL"
done

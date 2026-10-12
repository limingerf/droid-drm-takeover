#!/bin/sh
# route-rule-fix.sh —— 补回容器的策略路由规则
#
# ══════════════════════════════════════════════════════════════════════
# 症状
# ══════════════════════════════════════════════════════════════════════
# WiFi 明明连上了（wlan0 UP、拿到 192.168.x.x、default via ... dev wlan0），
# 但 ping 任何地址都是 "Network is unreachable"，DNS 也解析不了，
# 连**同一个子网的网关**都 ping 不通。
#
# ══════════════════════════════════════════════════════════════════════
# 根因
# ══════════════════════════════════════════════════════════════════════
# 容器的策略路由里有一条兜底规则：
#     32000:  from all unreachable
# 它**之前**必须有更靠前的规则把流量导向真正的表，否则一切都不可达。
#
# 实测 WiFi 连上之后，规则表长这样：
#     0:     from all lookup local
#     11000: from all iif lo oif dummy0 uidrange 0-0 lookup 1002
#     16000: from all fwmark 0x10063/0x1ffff iif lo lookup 97
#     17000: from all iif lo oif dummy0 lookup 1002
#     20000: from all fwmark 0/0x10000 lookup 97
#     32000: from all unreachable          ← 全落到这里
#
# ★ 指向 main（254）的规则**没了** —— 所以连同一个子网的网关都 ping 不通。
# ★ 指向 1042 的规则**也没了** —— 那是容器放 wlan0 默认路由的表。
#
# 为什么会没：NetworkManager 接管 wlan0 时会重建策略路由，把容器原先
# 装好的规则挤掉。这是 NM 与容器网络共存的已知冲突，
# 详见 network/README.md 的 §8.1。
#
# ══════════════════════════════════════════════════════════════════════
# 修法
# ══════════════════════════════════════════════════════════════════════
# **只加不删**（红线：绝不 ip rule flush，绝不删 netd 的 rule/table）。
# 补两条优先级在 32000 之前的规则：
#     31000 → main   （直连子网 + NM 装的默认路由）
#     31500 → 1042   （容器自己的表）
#
# 另外表 1042 里的默认路由网关可能过期（实测出现过 via 192.168.1.1，
# 而真实网关是 192.168.1.2），这里一并用 main 表里的真实网关纠正。
# ══════════════════════════════════════════════════════════════════════

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1) 补规则（幂等）
for P in "31000 main" "31500 1042"; do
    PREF=${P%% *}
    TBL=${P##* }
    if ip rule show 2>/dev/null | grep -aq "^$PREF:"; then
        echo "  pref $PREF 已存在"
    else
        ip rule add pref "$PREF" from all lookup "$TBL" 2>/dev/null \
            && echo "  已加 pref $PREF → table $TBL" \
            || echo "  ✗ 加 pref $PREF 失败"
    fi
done

# 2) 用 main 表的真实网关纠正 1042（只在拿到网关时做）
GW=$(ip route show table main 2>/dev/null | sed -n 's/^default via \([0-9.]*\) .*/\1/p' | head -1)
DEV=$(ip route show table main 2>/dev/null | sed -n 's/^default via .* dev \([a-z0-9]*\) .*/\1/p' | head -1)
if [ -n "$GW" ] && [ -n "$DEV" ]; then
    ip route replace default via "$GW" dev "$DEV" table 1042 2>/dev/null \
        && echo "  表 1042 默认路由 → via $GW dev $DEV"
else
    echo "  main 表里没有默认路由，跳过 1042 纠正"
fi

echo "  当前规则："
ip rule show 2>/dev/null | sed 's/^/    /'

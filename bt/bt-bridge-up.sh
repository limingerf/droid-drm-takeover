#!/system/bin/sh
# bt-bridge-up.sh — 在**安卓侧**起蓝牙 HCI 桥，并做端到端验收。
#
# 用法（在设备上以 root 跑）：
#   su -c 'sh /data/local/tmp/bt-bridge-up.sh'            跑完 4 条验收后把桥收掉
#   su -c 'sh /data/local/tmp/bt-bridge-up.sh --stay'     跑完前 3 条验收后**留着**桥
#   su -c 'sh /data/local/tmp/bt-bridge-up.sh --down'     只把桥收掉并验残留
#
# ══════════════════════════════════════════════════════════════════════
# 前置条件（缺一不可，脚本会自己查）
# ══════════════════════════════════════════════════════════════════════
#   init.svc.surfaceflinger = stopped
#     桥借的是**安卓框架同一条命**的 HAL 客户端位。历史实测：桥与安卓蓝牙栈
#     同时持有 IBluetoothHci 客户端位，会把同一颗 WiFi+BT combo 芯片的电源协调
#     （btpower/cnss）打进 `is_driver_recovering 1 / Driver Loading Timed-out!!`
#     死循环，停桥也解不开，只能整机重启。所以这条是硬门禁，不是建议。
#
# ══════════════════════════════════════════════════════════════════════
# 4 条验收（实测判据，不是"看起来对"）
# ══════════════════════════════════════════════════════════════════════
#   ① 桥日志里出现 initializationComplete(status=0)  ← HAL 收下了我们的回调节点
#   ② 容器里 `hciconfig -a hci0` 有 `Bus: UART` **且** BD_ADDR 非全零
#        ← 非零 BD_ADDR 是"内核 hci_uart ↔ pty ↔ 桥 ↔ HAL ↔ 芯片"整条路
#          跑通了 HCI_Read_BD_ADDR 往返的硬证据。全零就是只注册了设备没通。
#   ③ 容器里 `bluetoothctl show` 列出 Controller
#        ← BlueZ 通过 mgmt 接口认领了这个 hci0（这是最终目的）
#   ③b（信息性，不进退出码）实际扫描能不能发现设备
#        ← 证明射频真的能收发，而不是只注册了个设备节点
#   ④ 桥退出后 /sys/class/bluetooth 为空、rfkill 状态回到基线、模块仍在
#        ← 证明"桥一退就把 hci0 还回去"，没有残留
#
# ══════════════════════════════════════════════════════════════════════
# ★ 桥里的顺序是**实测踩出来的**，不是风格问题
# ══════════════════════════════════════════════════════════════════════
#   openPty → initialize(HAL) → 起 pty 泵 → **最后**才 setLdiscH4（挂 N_HCI）
#
#   内核一收到 HCIUARTSETPROTO 就 hci_register_dev() 并立刻跑它自己的 HCI 初始化
#   序列（几十条命令），而 hdev->setup 是有**超时**的。若此时桥还没 initialize HAL、
#   主循环还没在 poll pty，那些命令就堆在 pty 缓冲里没人转发 → 内核 setup 超时 →
#   `HCI_SETUP` 这个 dev_flag 清不掉 → 内核 mgmt 的索引表里永远没有这个设备。
#
#   症状极具误导性：`hciconfig -a hci0` 一切正常（它自己另发 HCI 命令读版本/特性，
#   与内核 setup 无关）、`/sys/class/bluetooth/hci0` 也在，但容器里
#   `bluetoothctl` 报 "No default controller available"、`btmgmt info` 报
#   "Index list with 0 items"。实测：HAL 的 initialize 要 1.6 秒（上电+固件下载），
#   正好够把内核 setup 等超时。
#
#   ⚠️ 重启容器里的 bluetoothd **不能**解决这个问题（实测过）—— 因为内核 mgmt
#      索引里压根没有这个设备，跟 bluetoothd 什么时候启动无关。
#
# ══════════════════════════════════════════════════════════════════════
# 红线
# ══════════════════════════════════════════════════════════════════════
#   · 不重启容器、不改 container.config、不碰 /data/a2lrootfs
#   · 不 setenforce 0、不写 /sys/class/rfkill/*、不打任何 btpower 电源 ioctl
#   · 收桥只用 /proc/*/comm **精确**匹配（等价 `pkill -x bthci-bridge`，
#     绝不用 `pkill -f` 正则 —— 那会误伤命令行里恰好提到该字符串的进程）
#   · 本脚本不重启安卓；要回安卓得整机 reboot（不在这里做）

set +u

DS=${DS:-/data/local/Droidspaces/bin/droidspaces}
CN=${CN:-DEBIAN}
BTBIN=${BTBIN:-/data/local/tmp/bthci-bridge}
BTLOG=${BTLOG:-/data/local/tmp/bt-bridge.log}
WAIT_INIT=${WAIT_INIT:-30}   # 等 initializationComplete 的秒数
WAIT_HCI=${WAIT_HCI:-30}     # 等容器里 hci0 出现的秒数

MODE=run
for _a in "$@"; do
    case "$_a" in
        --stay) MODE=stay ;;
        --down) MODE=down ;;
        -h|--help)
            echo "用法: $0 [--stay|--down]"
            exit 0
            ;;
        *)
            echo "未知参数: $_a" >&2
            exit 2
            ;;
    esac
done

log() { echo "[bt-up $(date +%T)] $*"; }
hr()  { echo "────────────────────────────────────────────────────────────"; }

# ── 收桥：按 comm 精确匹配（= pkill -x，但不依赖 toybox 的 pkill）────────
bt_pids_by_comm() {
    _want=$1
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ "$_p" = "$$" ] && continue
        [ -r "$_d/comm" ] || continue
        read -r _c <"$_d/comm" 2>/dev/null || continue
        [ "$_c" = "$_want" ] && echo "$_p"
    done
}

bt_kill_by_comm() {
    _sig=$1
    _name=$2
    _pids=$(bt_pids_by_comm "$_name")
    [ -n "$_pids" ] || return 0
    for _p in $_pids; do
        kill "-$_sig" "$_p" 2>/dev/null
    done
    return 0
}

# ── 容器侧单条命令 ────────────────────────────────────────────────────
in_c() { "$DS" --name="$CN" run "$@" 2>&1; }

container_running() { "$DS" show 2>/dev/null | grep -q "$CN"; }

# ── 基线快照（验收 ④ 的对照）──────────────────────────────────────────
# ★ 压成**单行**：早先版本每项一行，do_down 里用 case 做模式匹配时，
#   `SYSFS_BT=` 后面跟的是换行而不是空格，模式 `*"SYSFS_BT= "*` 永远不匹配，
#   于是把"已经清干净"误报成"还有残留"。判据不能用脆弱的模式匹配来写。
snapshot() {
    _s_bt=$(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ',')
    _s_rf=$(cat /sys/class/rfkill/rfkill0/name 2>/dev/null)
    _s_rfs=$(cat /sys/class/rfkill/rfkill0/soft 2>/dev/null)
    _s_rfh=$(cat /sys/class/rfkill/rfkill0/hard 2>/dev/null)
    _s_ld=$(grep -c n_hci /proc/tty/ldiscs 2>/dev/null)
    _s_md=$(grep -cE '^(bluetooth|hci_uart|btqca|btpower|rfkill) ' /proc/modules 2>/dev/null)
    _s_pid=$(bt_pids_by_comm bthci-bridge | tr '\n' ',')
    echo "sysfs_bt=[${_s_bt:-}] rfkill=${_s_rf:-?}/${_s_rfs:-?}/${_s_rfh:-?} ldisc=${_s_ld:-?} modules=${_s_md:-?} bridge_pid=[${_s_pid:-}]"
}

show_state() {
    hr
    echo "· /sys/class/bluetooth : $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
    echo "· /proc/tty/ldiscs     : $(grep n_hci /proc/tty/ldiscs 2>/dev/null | tr '\n' ' ')"
    echo "· rfkill0              : $(cat /sys/class/rfkill/rfkill0/name 2>/dev/null) soft=$(cat /sys/class/rfkill/rfkill0/soft 2>/dev/null) hard=$(cat /sys/class/rfkill/rfkill0/hard 2>/dev/null)"
    echo "· bthci-bridge pid     : $(bt_pids_by_comm bthci-bridge | tr '\n' ' ')"
    echo "· surfaceflinger       : $(getprop init.svc.surfaceflinger)"
    hr
}

# ── 收桥 + 验残留（验收 ④）────────────────────────────────────────────
do_down() {
    _before=$1
    log "收桥（/proc comm 精确匹配 bthci-bridge）"
    bt_kill_by_comm TERM bthci-bridge
    _i=0
    while [ "$_i" -lt 15 ]; do
        [ -z "$(bt_pids_by_comm bthci-bridge)" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    if [ -n "$(bt_pids_by_comm bthci-bridge)" ]; then
        log "TERM 15s 没收掉，补一次 KILL"
        bt_kill_by_comm KILL bthci-bridge
        sleep 2
    fi
    # 内核注销 hci0 有一小段延迟
    sleep 2
    _after=$(snapshot)
    hr
    echo "── 验收 ④：退出后无残留 ──"
    echo "  起桥前基线: $_before"
    echo "  收桥后    : $_after"
    _fail=0

    # ★ 逐项**显式**判定，不拿 snapshot 的字符串做模式匹配（那正是上一版的 bug）。
    _bt_now=$(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')
    if [ -z "$_bt_now" ]; then
        echo "  ✅ /sys/class/bluetooth 已空（hci0 被内核回收）"
    else
        echo "  ❌ /sys/class/bluetooth 还有：$_bt_now"
        _fail=1
    fi

    _pid_now=$(bt_pids_by_comm bthci-bridge | tr '\n' ' ')
    if [ -z "$_pid_now" ]; then
        echo "  ✅ 没有残留的 bthci-bridge 进程"
    else
        echo "  ❌ 还有 bthci-bridge 进程：$_pid_now"
        _fail=1
    fi

    _rf_b=$(echo "$_before" | sed -n 's/.*rfkill=\([^ ]*\).*/\1/p')
    _rf_a=$(echo "$_after"  | sed -n 's/.*rfkill=\([^ ]*\).*/\1/p')
    if [ "$_rf_b" = "$_rf_a" ]; then
        echo "  ✅ rfkill0 与基线一致（$_rf_a）—— 桥没碰过射频开关"
    else
        echo "  ❌ rfkill0 变了：基线=$_rf_b 现在=$_rf_a"
        _fail=1
    fi

    _md=$(echo "$_after" | sed -n 's/.*modules=\([0-9]*\).*/\1/p')
    if [ "${_md:-0}" -ge 5 ]; then
        echo "  ✅ 蓝牙内核模块仍在（$_md 个）—— 桥没卸载任何模块"
    else
        echo "  ⚠️ 模块数 ${_md:-?} < 5，核对一下"
    fi

    _ld=$(echo "$_after" | sed -n 's/.*ldisc=\([0-9]*\).*/\1/p')
    if [ "${_ld:-0}" -ge 1 ]; then
        echo "  ✅ n_hci 线路规程仍在（$_ld）—— 桥没改 ldisc 注册表"
    else
        echo "  ⚠️ n_hci 不在了，核对一下"
    fi
    hr
    return $_fail
}

# ══════════════════════════════════════════════════════════════════════
show_state

if [ ! -x "$DS" ]; then
    log "❌ 缺少 droidspaces：$DS"
    exit 1
fi
if [ ! -x "$BTBIN" ]; then
    log "❌ 缺少桥二进制：$BTBIN（先 adb push 再 chmod 755）"
    exit 1
fi
if ! container_running; then
    log "❌ 容器 $CN 没在跑"
    exit 1
fi

if [ "$MODE" = down ]; then
    do_down "$(snapshot)"
    exit $?
fi

# ── 硬门禁：surfaceflinger 必须是 stopped ─────────────────────────────
_sf=$(getprop init.svc.surfaceflinger)
if [ "$_sf" != "stopped" ]; then
    log "❌ 拒绝启动：init.svc.surfaceflinger=$_sf（必须 stopped）"
    log "   桥与安卓蓝牙栈同时持有 IBluetoothHci 客户端位会把 WiFi+BT combo"
    log "   打进电源协调死循环，只能整机重启。先完成接管再起桥。"
    exit 1
fi
log "✅ 门禁通过：surfaceflinger=stopped"

BASE=$(snapshot)
log "基线：$BASE"

# ── 起桥 ──────────────────────────────────────────────────────────────
if [ -n "$(bt_pids_by_comm bthci-bridge)" ]; then
    log "复用已在跑的桥（pid $(bt_pids_by_comm bthci-bridge | tr '\n' ' ')）"
else
    log "启动 $BTBIN --keep 0（日志 $BTLOG）"
    : >"$BTLOG"
    nohup "$BTBIN" --keep 0 >>"$BTLOG" 2>&1 </dev/null &
    sleep 1
fi

# ── 验收 ①：initializationComplete(status=0) ──────────────────────────
hr
echo "── 验收 ①：HAL 收下回调节点 ──"
_i=0
_ok1=0
while [ "$_i" -lt "$WAIT_INIT" ]; do
    if grep -q 'initializationComplete(status=0' "$BTLOG" 2>/dev/null; then
        _ok1=1
        break
    fi
    # 桥自己死了就别等了
    if [ -z "$(bt_pids_by_comm bthci-bridge)" ]; then
        log "桥进程已退出，不再等"
        break
    fi
    sleep 1
    _i=$((_i + 1))
done
grep -E 'initializationComplete|槽位|hci attach|自动判定|回调节点|熔断|★|✗' "$BTLOG" 2>/dev/null | head -20
if [ "$_ok1" = 1 ]; then
    echo "  ✅ ① 通过：initializationComplete(status=0)"
else
    echo "  ❌ ① 失败：${WAIT_INIT}s 内没等到 initializationComplete(status=0)"
    echo "  ── 桥日志尾部 ──"
    tail -n 40 "$BTLOG" 2>/dev/null
fi

# ── 验收 ②：容器里 hci0 的 Bus: UART + 非零 BD_ADDR ───────────────────
hr
echo "── 验收 ②：容器里 hci0 真的通了 ──"
_i=0
_ok2=0
_hci=""
while [ "$_i" -lt "$WAIT_HCI" ]; do
    _hci=$(in_c hciconfig -a hci0)
    case "$_hci" in
        *"Bus: UART"*) _ok2=1; break ;;
    esac
    [ -z "$(bt_pids_by_comm bthci-bridge)" ] && break
    sleep 1
    _i=$((_i + 1))
done
echo "$_hci"
if [ "$_ok2" = 1 ]; then
    echo "  ✅ ②a Bus: UART"
else
    echo "  ❌ ②a ${WAIT_HCI}s 内没看到 Bus: UART"
    echo "  · 容器 /sys/class/bluetooth: $(in_c ls /sys/class/bluetooth | tr '\n' ' ')"
fi
# BD_ADDR 非全零 = HCI_Read_BD_ADDR 往返成功 = 整条链路通
_bd=$(echo "$_hci" | sed -n 's/.*BD Address: \([0-9A-Fa-f:]*\).*/\1/p' | head -1)
case "$_bd" in
    ""|"00:00:00:00:00:00")
        echo "  ❌ ②b BD_ADDR=${_bd:-未解析到}（全零/缺失 ⇒ HCI 往返没通，只注册了设备）"
        _ok2=0
        ;;
    *)
        echo "  ✅ ②b BD_ADDR=$_bd（非全零 ⇒ 内核 hci_uart ↔ pty ↔ 桥 ↔ HAL ↔ 芯片 全链路通）"
        ;;
esac

# ── 验收 ③：bluetoothctl show 列出 Controller ─────────────────────────
hr
echo "── 验收 ③：BlueZ 认领了这个控制器 ──"
_ok3=0
_bt=$(in_c bluetoothctl show)
case "$_bt" in
    *"Controller "*)
        _ok3=1
        ;;
esac
echo "$_bt" | head -12
if [ "$_ok3" = 1 ]; then
    echo "  ✅ ③ 通过：bluetoothctl 列出了 Controller"
else
    echo "  ❌ ③ 失败：bluetoothctl show 没有 Controller"
    echo "  · 容器 bluetoothd: $(in_c ps -A | grep bluetoothd)"
    echo "  · 容器 hciconfig  : $(in_c hciconfig -a 2>&1 | head -3 | tr '\n' ' ')"
    echo "  · 容器 btmgmt     : $(in_c timeout 6 btmgmt info 2>&1 | head -3 | tr '\n' ' ')"
    echo "  ⚠️ BlueZ 看不到控制器时，先怀疑**内核 mgmt 索引**："
    echo "     内核的 read_index_list 会跳过带 HCI_SETUP dev_flag 的设备，"
    echo "     而 HCI_SETUP 只有在 hdev->setup（内核自己的 HCI 初始化序列）**成功**后才清。"
    echo "     所以桥必须先 initialize HAL、先跑起 pty 泵，**最后**才挂 N_HCI ——"
    echo "     否则内核那几十条初始化命令会堆在 pty 里没人转发而超时。"
    echo "     （hciconfig 此时照样一切正常，极具误导性：它自己另发命令读版本/特性。）"
fi

# ── 验收 ③b（信息性）：真的扫得到设备吗 ───────────────────────────────
# 这一条证明的不是"注册了个设备节点"，而是"射频真的能收发"。
# 它不进退出码：射频环境（附近有没有可发现的设备）不由我们决定。
if [ "$_ok3" = 1 ] && [ "${BT_SCAN:-1}" != 0 ]; then
    hr
    echo "── ③b（信息性）：${BT_SCAN_SEC:-12}s 实际扫描 ──"
    _scan=$(in_c timeout 30 bluetoothctl --timeout "${BT_SCAN_SEC:-12}" scan on 2>&1)
    echo "$_scan" | grep -E 'NEW|CHG|Discovery' | head -15
    _nd=$(in_c bluetoothctl devices 2>/dev/null | grep -c '^Device ')
    echo "  发现设备数：${_nd:-0}"
    if [ "${_nd:-0}" -gt 0 ]; then
        echo "  ✅ 射频可用（扫到了真实设备 ⇒ hci0 不是空壳）"
    else
        echo "  ⚠️ 没扫到设备（可能是附近确实没有可发现的设备，不判失败）"
    fi
fi

show_state

# ── 验收 ④ ────────────────────────────────────────────────────────────
if [ "$MODE" = stay ]; then
    hr
    echo "── --stay：桥留着不收了（要收：$0 --down）──"
    echo "   收桥只能用精确匹配："
    echo "     for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm)\" = bthci-bridge ] && kill \$p; done"
    echo "   等价于 pkill -x bthci-bridge（绝不要用 -f）"
    hr
    [ "$_ok1" = 1 ] && [ "$_ok2" = 1 ] && [ "$_ok3" = 1 ] && exit 0
    exit 1
fi

do_down "$BASE"
_ok4=$?

hr
echo "══ 验收汇总 ══"
echo "  ① initializationComplete(status=0) : $([ "$_ok1" = 1 ] && echo 通过 || echo 失败)"
echo "  ② 容器 hci0 Bus:UART + 非零 BD_ADDR: $([ "$_ok2" = 1 ] && echo 通过 || echo 失败)"
echo "  ③ 容器 bluetoothctl 列出 Controller : $([ "$_ok3" = 1 ] && echo 通过 || echo 失败)"
echo "  ④ 退出后无残留                     : $([ "$_ok4" = 0 ] && echo 通过 || echo 失败)"
hr
[ "$_ok1" = 1 ] && [ "$_ok2" = 1 ] && [ "$_ok3" = 1 ] && [ "$_ok4" = 0 ] && exit 0
exit 1
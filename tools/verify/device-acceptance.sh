#!/bin/sh
# tools/verify/device-acceptance.sh — 真机验收测试
#
# 目的：把"这台设备到底能不能跑"变成一条命令、一份可核对的清单。
#
# 默认**不做任何破坏性操作** —— 不接管、不停服务、不重启。只读地检查
# 每一项前置条件，然后给出通过/失败/跳过。绝大多数问题（缺 Droidspaces、
# 触摸节点找不到、split 几何发现不了、bin/ 不可执行）都能在这一步暴露，
# 而不需要真的去接管一次然后黑屏。
#
# 用法（安卓侧，需要 root）：
#   su -c 'sh /data/local/drm-takeover/tools/verify/device-acceptance.sh'
#
#   --takeover   额外执行一次真实接管并验证 kwin 持屏（会改变系统状态，
#                需要重启才能回安卓 —— 想清楚了再用）
#   --quiet      只打印失败项和汇总
#
# 退出码 = 失败项数量（0 = 全部通过）

set -u

SELF_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
DRM_ROOT=$(cd "$SELF_DIR/../.." 2>/dev/null && pwd)
[ -n "$DRM_ROOT" ] || DRM_ROOT=$SELF_DIR

# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/common.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/device.sh"
drm_device_load
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/android.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/container.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/display.sh"
# shellcheck source=/dev/null
. "$DRM_ROOT/core/lib/enter.sh"      # 只取 drm_stage_payload_to_container（无顶层副作用）

DO_TAKEOVER=0
QUIET=0
for _a in "$@"; do
    case "$_a" in
        --takeover) DO_TAKEOVER=1 ;;
        --quiet)    QUIET=1 ;;
        -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0; WARN=0

if [ "$QUIET" = 0 ]; then
    printf '\n'
    printf '════════════════════════════════════════════════════════════\n'
    printf ' 真机验收测试 —— %s\n' "${DEV_MODEL:-未知设备}"
    printf ' 设备代号: %s    平台: %s\n' "${DEV_CODENAME:-?}" "${DEV_PLATFORM:-?}"
    printf ' 时间: %s\n' "$(drm_ts)"
    printf '════════════════════════════════════════════════════════════\n'
fi

ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); [ "$QUIET" = 1 ] || printf '  ⏭️  %s\n' "$1"; }
warn() { WARN=$((WARN+1)); [ "$QUIET" = 1 ] || printf '  ⚠️  %s\n' "$1"; }
head_() { [ "$QUIET" = 1 ] || printf '\n── %s ──\n' "$1"; }

# ════════════════════════════════════════════════════════════════════
head_ "A. 前置条件"

# A1 root
if [ "$(id -u 2>/dev/null)" = "0" ]; then
    ok "以 root 运行（context=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')）"
else
    bad "不是 root —— 这个脚本必须 su 执行" "su -c 'sh $0'"
fi

# A2 payload 可信（这是安全边界，必须过）
if drm_assert_payload_trusted "$DRM_ROOT" 2>/dev/null; then
    ok "payload 可信（$DRM_ROOT 非 group/other 可写）"
else
    bad "payload 未通过可信性检查" "见 core/lib/common.sh 的 drm_assert_payload_trusted；临时绕过 DRM_ALLOW_UNTRUSTED=1"
fi

# A3 payload 完整性
_missing=""
for _f in core/switch.sh core/lib/common.sh core/lib/enter.sh \
          linux/session-up.sh linux/drm-switch.sh \
          display/desk-takeover.sh display/desk-stop.sh display/kill-desktop.sh \
          android/enter.sh android/exit-watch.sh android/boot-install.sh; do
    [ -f "$DRM_ROOT/$_f" ] || _missing="$_missing $_f"
done
if [ -z "$_missing" ]; then
    ok "payload 关键脚本齐全"
else
    bad "payload 缺少:$_missing" "APK 的「安装/更新 payload」没跑完？"
fi

# A4 bin/ 产物
if [ -d "$DRM_ROOT/bin" ]; then
    _n=$(ls -1 "$DRM_ROOT/bin" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_n" -ge 24 ]; then
        ok "bin/ 有 $_n 个产物"
    else
        bad "bin/ 只有 $_n 个产物（期望 >= 24）" "APK 打包时没带 bin/，或 make 没跑完"
    fi
    # 可执行位 —— 这是早期版本踩过的坑（chmod -R go-w 只去写位、没给执行位）
    _noexec=""
    for _b in kwinwrap setbright setprop crtcstate connprops; do
        [ -f "$DRM_ROOT/bin/$_b" ] && [ ! -x "$DRM_ROOT/bin/$_b" ] && _noexec="$_noexec $_b"
    done
    if [ -z "$_noexec" ]; then
        ok "bin/ 关键产物可执行"
    else
        bad "bin/ 产物没有执行位:$_noexec" "chmod 755 $DRM_ROOT/bin/*"
    fi
else
    bad "没有 bin/ 目录" "APK 必须带上编译产物（见 README 的构建顺序）"
fi

# A5 设备适配层
if [ "${DEV_CODENAME:-}" = "generic" ]; then
    warn "用的是 generic 适配层（全靠运行时发现）—— 建议按 docs/适配新设备.md 加一个专属文件"
elif [ -n "${DEV_CODENAME:-}" ]; then
    ok "适配层: $DEV_CODENAME（$DRM_ROOT/core/device/$DEV_CODENAME.sh）"
else
    bad "没有识别出设备适配层"
fi

# ════════════════════════════════════════════════════════════════════
head_ "B. 硬件资源"

# B1 DRM 节点
if [ -e "$DEV_DRM_CARD" ] && [ -r "$DEV_DRM_CARD" ] && [ -w "$DEV_DRM_CARD" ]; then
    ok "$DEV_DRM_CARD 存在且可读写"
else
    bad "$DEV_DRM_CARD 不存在或不可读写" "devno=$DEV_DRM_MAJOR:$DEV_DRM_MINOR；可用 mknod 重建（drm_ensure_drm_nodes）"
fi
if [ -e "$DEV_DRM_RENDER" ]; then
    ok "$DEV_DRM_RENDER 存在"
else
    warn "$DEV_DRM_RENDER 不存在（渲染链可能走别的节点）"
fi
if [ -e /dev/kgsl-3d0 ]; then
    ok "/dev/kgsl-3d0 存在（渲染链）"
else
    warn "/dev/kgsl-3d0 不存在 —— Mesa 的 kgsl 后端会失败"
fi

# B2 面板拓扑（直接读 sysfs，不依赖任何探针）
_panel=""
for _c in /sys/class/drm/card*/card*-*/; do
    [ -r "$_c/status" ] || continue
    [ "$(cat "$_c/status" 2>/dev/null)" = "connected" ] || continue
    _nm=$(basename "$_c")
    case "$_nm" in *Virtual*|*Writeback*) continue ;; esac
    _panel=$_nm
    _modes=$(cat "$_c/modes" 2>/dev/null | head -3 | tr '\n' ' ')
    ok "面板 $_nm: connected，模式: ${_modes:-（无）}"
    break
done
if [ -z "$_panel" ]; then
    bad "找不到 connected 的面板 connector" "ls /sys/class/drm/ 看拓扑"
fi

# B3 触摸节点（按名字找，不写死 eventN）
if [ -z "${DEV_TOUCH_NAME:-}" ]; then
    warn "DEV_TOUCH_NAME 未配置（generic 适配层？）—— 无法按名字定位触摸节点"
else
    _touch=$(drm_touch_find_event 2>/dev/null || true)
    if [ -n "$_touch" ]; then
        ok "触摸节点: $_touch（匹配名 '$DEV_TOUCH_NAME'）"
    else
        bad "按名字 '$DEV_TOUCH_NAME' 找不到触摸节点" "grep -i '$DEV_TOUCH_NAME' /proc/bus/input/devices"
    fi
fi

# B4 背光
# ★ drm_backlight_node 返回的是**节点名**（不是路径），要自己拼
#   /sys/class/backlight/<名>/brightness。
# ★ `echo ?` 里的 ? 不加引号会被当 glob 展开 —— 安卓根目录下正好有个
#   叫 `d` 的条目，于是"读不到"时会打印出一个莫名其妙的 d。
_bl=$(drm_backlight_node 2>/dev/null || true)
if [ -n "$_bl" ]; then
    ok "背光节点: $_bl（当前 $(cat "/sys/class/backlight/$_bl/brightness" 2>/dev/null || echo '?')）"
elif [ -n "${DEV_BACKLIGHT:-}" ]; then
    bad "DEV_BACKLIGHT=$DEV_BACKLIGHT 但节点不存在" "ls /sys/class/backlight/"
else
    warn "没有 sysfs 背光节点 —— 会退回写 DRM connector 的 brightness 属性"
fi

# B5 无线网卡
if [ -n "${DEV_WIFI_IF:-}" ] && [ -e "/sys/class/net/$DEV_WIFI_IF" ]; then
    ok "无线网卡: $DEV_WIFI_IF"
else
    warn "找不到网卡 ${DEV_WIFI_IF:-（未配置）} —— 网络接管会跳过（不影响上屏）"
fi

# ════════════════════════════════════════════════════════════════════
head_ "C. 安卓侧可操作性"

# C1 composer 服务（★ 最容易填错的一项）
if [ -n "${DEV_COMPOSER_SVC:-}" ]; then
    _st=$(android_svc_state "$DEV_COMPOSER_SVC" 2>/dev/null || true)
    if [ -n "$_st" ]; then
        ok "composer 服务 $DEV_COMPOSER_SVC: init.svc=$_st"
    else
        # 注意：判据不是 init.svc，而是"它还占不占着 card0"（见下一项）
        warn "读不到 $DEV_COMPOSER_SVC 的 init.svc 状态（名字对不对？）"
    fi
    # 它是不是真的持有 card0 —— 这才是接管时真正用的判据
    _h=$(android_card_holders 2>/dev/null || true)
    if [ -n "$_h" ]; then
        ok "card0 当前持有者: $(printf '%s' "$_h" | tr '\n' ' ')"
    else
        warn "card0 当前没有持有者（安卓显示栈没在跑？）"
    fi
else
    bad "DEV_COMPOSER_SVC 未配置"
fi

# C2 关键服务（去重：DEV_SF_SVC 通常就是 surfaceflinger）
_seen=""
for _s in "${DEV_SF_SVC:-}" surfaceflinger zygote; do
    [ -n "$_s" ] || continue
    case " $_seen " in *" $_s "*) continue ;; esac
    _seen="$_seen $_s"
    _st=$(android_svc_state "$_s" 2>/dev/null || true)
    if [ "$_st" = "running" ]; then
        ok "服务 $_s: running"
    elif [ -n "$_st" ]; then
        warn "服务 $_s: $_st"
    else
        warn "服务 $_s: 读不到状态"
    fi
done

# C3 reboot（★ 只有 /system/bin/reboot 有效）
if [ -x /system/bin/reboot ]; then
    ok "/system/bin/reboot 存在（返回安卓用它；svc power reboot 是静默 no-op）"
else
    bad "/system/bin/reboot 不存在 —— 返回安卓会失败"
fi

# C4 看门狗设置可读（接管前必须能解除武装）
_wd=$(settings list global 2>/dev/null | grep -icE 'watchdog|nativehang' || true)
if [ "${_wd:-0}" -gt 0 ]; then
    ok "看门狗相关设置可见（$_wd 项）"
else
    warn "没看到 watchdog/nativehang 设置 —— 确认 DEV_WATCHDOG_DISARM 是否还有效"
fi

# C5 内核调试参数可写
_dbg=""
for _p in /sys/module/drm/parameters/debug \
          /sys/module/msm_drm/parameters/debugpolicy \
          /sys/module/msm_drm/parameters/debug_level; do
    [ -e "$_p" ] && [ -w "$_p" ] && _dbg="$_dbg $_p"
done
if [ -n "$_dbg" ]; then
    ok "内核 DRM 调试参数可写:$_dbg"
else
    warn "没有可写的 DRM 调试参数（接管时可能被刷屏拖慢帧率）"
fi

# ════════════════════════════════════════════════════════════════════
head_ "D. 容器运行时"

if ds_available 2>/dev/null; then
    ok "Droidspaces 可用: $DS_BIN"
    if [ -f "$DS_CFG" ]; then
        ok "容器配置存在: $DS_CFG"
        _cfg=$(cat "$DS_CFG" 2>/dev/null || true)
        # ★ 这里原来查的是 `bind_mounts=/dev:/dev` —— 那是**旧版假设**。
        #   Droidspaces v6 里 /dev 是容器自己的 devtmpfs，访问权由
        #   enable_hw_access 给；Droidspaces 只挑几个节点挂进去
        #   （实测 renderD128 + kgsl，**没有 card0**，/dev/input 是空的）。
        #   所以 card0 和输入节点是我们自己 mknod 的，见 display.sh。
        case "$_cfg" in
            *enable_hw_access=1*) ok "enable_hw_access=1（/dev 可用）" ;;
            *bind_mounts=*)
                case "$_cfg" in
                    */dev:/dev*) ok "bind_mounts 含 /dev:/dev" ;;
                    *) warn "有 bind_mounts 但不含 /dev:/dev" ;;
                esac ;;
            *) warn "enable_hw_access 不是 1 —— 容器可能拿不到 /dev 节点" ;;
        esac
        # renderD128 是 Mesa/Freedreno 的渲染节点，上屏不用它但不能少
        case "$_cfg" in
            *enable_gpu_mode=1*) ok "enable_gpu_mode=1（GPU 渲染节点已挂）" ;;
            *) warn "enable_gpu_mode 不是 1 —— 容器里可能没有 renderD128（Mesa 渲染会退回软渲染）" ;;
        esac
        case "$_cfg" in
            *net_mode*=*host*) ok "net_mode=host" ;;
            *) warn "net_mode 不是 host —— 容器可能拿不到安卓的网络栈" ;;
        esac
    else
        bad "容器配置不存在: $DS_CFG" "先建容器（见 README）"
    fi
else
    bad "Droidspaces 不可用（$DS_BIN）" "★ 这是端到端跑通的硬前提，必须先装容器运行时"
fi

_shared=$(ds_shared_dir 2>/dev/null || true)
if [ -n "$_shared" ]; then
    if [ -d "$_shared" ]; then
        ok "共享目录存在: $_shared"
    else
        bad "共享目录不存在: $_shared" "DEV_SHARED 配错了？（v6 里 rootfs 是普通目录，不该缺）"
    fi
fi

# ── 把 payload 摆进容器，供 E 段在容器里跑工具 ─────────────
#
# ★ 为什么工具必须在容器里跑：bin/ 下的产物是 **glibc** 链接
#   （interpreter /lib/ld-linux-aarch64.so.1），而安卓是 bionic。
#   在安卓侧直接执行只会得到一句 "No such file or directory" ——
#   极容易误判成"文件没推上去"。（本项目的验收测试就在这栽过一次。）
CONT_ROOT=""
if ds_running 2>/dev/null; then
    ok "容器 $DS_NAME 在运行"
    if [ -n "$_shared" ] && [ -d "$_shared" ]; then
        # ★ 总是重新同步（drm_stage_payload_to_container 内部是 rm -rf + cp，
        #   幂等）。不能"看到已存在就跳过" —— 那会用容器里的**旧** payload
        #   做验收，测出来的结论对不上当前仓库。
        if drm_stage_payload_to_container >/dev/null 2>&1; then
            ok "payload 已同步进容器共享目录"
        else
            warn "payload 同步进容器失败 —— 容器侧工具无法验证"
        fi
        # ★ 容器内的路径，不是安卓侧的 <rootfs>/root/...
        [ -d "$_shared/droid-drm-takeover/bin" ] && CONT_ROOT=$(ds_repo_in_container)
    fi
else
    warn "容器 $DS_NAME 没在运行 —— 容器侧工具无法验证（先 droidspaces --name=$DS_NAME start）"
fi

# ════════════════════════════════════════════════════════════════════
head_ "E. 工具自检"

_kw="$DRM_ROOT/bin/kwinwrap"
if [ -x "$_kw" ]; then
    _arch=$(file -b "$_kw" 2>/dev/null || echo "")
    case "$_arch" in
        *aarch64*) ok "kwinwrap 是 ARM aarch64" ;;
        *) bad "kwinwrap 架构不对: $_arch" "交叉编译目标错了？" ;;
    esac
    # 链接方式决定"在哪儿跑"：glibc ⇒ 只能进容器
    case "$_arch" in
        *ld-linux-aarch64*)
            ok "kwinwrap 是 glibc 链接 ⇒ 必须在容器里执行（安卓侧会报 No such file or directory）" ;;
        *)
            warn "kwinwrap 链接方式存疑: $_arch" "确认它是不是被换成了 bionic 构建" ;;
    esac
else
    bad "$_kw 不存在或不可执行"
fi

# ── 容器侧：工具能不能真跑起来 ────────────────────────────
if [ -n "$CONT_ROOT" ]; then
    # E1 split 几何发现 —— 换设备最容易出问题的一项
    _split=$(ds_exec "$CONT_ROOT/bin/kwinwrap --probe-split" 2>/dev/null || true)
    if [ -n "$_split" ]; then
        ok "容器里 kwinwrap --probe-split 成功:"
        [ "$QUIET" = 1 ] || printf '%s\n' "$_split" | sed 's/^/       /'
        case "$_split" in
            *PLANES=*) : ;;
            *) warn "输出里没有 KWINWRAP_SPLIT_PLANES —— plane 自动发现可能失败，需人工指定" ;;
        esac
    else
        bad "容器里 kwinwrap --probe-split 没有输出" "接管时会用编译期兜底几何，几乎肯定花屏"
    fi

    # E2 容器里能不能 mknod 出 card0 并读 DRM 拓扑
    #    （Droidspaces 只把 renderD128 挂进容器，card0 要我们自己造）
    _maj=${DEV_DRM_MAJOR:-226}
    _min=${DEV_DRM_MINOR:-0}
    _kms=$(ds_exec "mknod /dev/dri/card0 c $_maj $_min 2>/dev/null; $CONT_ROOT/bin/kmsdump 2>&1 | head -2" 2>&1 || true)
    case "$_kms" in
        *resources:*)
            ok "容器里 mknod card0(${_maj}:${_min}) 后可读 DRM 拓扑"
            [ "$QUIET" = 1 ] || printf '%s\n' "$_kms" | sed 's/^/       /' ;;
        *)
            bad "容器里 card0 造不出来或读不了" "$_kms" ;;
    esac

    # E3 容器里触摸节点能不能造出来并打开
    _tev=$(drm_touch_find_event 2>/dev/null || true)
    if [ -n "$_tev" ]; then
        _dn=$(drm_touch_devno "$_tev" 2>/dev/null)
        _tmaj=$(printf '%s\n' "$_dn" | cut -d' ' -f1)
        _tmin=$(printf '%s\n' "$_dn" | cut -d' ' -f2)
        if [ -n "$_tmaj" ] && [ -n "$_tmin" ]; then
            # evdev 的 read() 在 count < sizeof(struct input_event)(24) 时返回
            # EINVAL —— 所以必须 bs=24，用 bs=16 会误判成"设备坏了"。
            _tr=$(ds_exec "mknod /dev/input/$_tev c $_tmaj $_tmin 2>/dev/null; timeout 2 dd if=/dev/input/$_tev of=/dev/null bs=24 count=1 >/dev/null 2>&1; echo rc=\$?" 2>&1 || true)
            case "$_tr" in
                *rc=124*) ok "容器里触摸节点 /dev/input/$_tev(${_tmaj}:${_tmin}) 可打开（2s 无事件＝在等）" ;;
                *rc=0*)   ok "容器里触摸节点 /dev/input/$_tev 可读（读到了事件）" ;;
                *)        warn "容器里触摸节点读取异常: $_tr" ;;
            esac
        fi
    else
        warn "安卓侧就没找到触摸设备（DEV_TOUCH_NAME=${DEV_TOUCH_NAME:-未指定}）"
    fi

    # E4 其余工具在容器里就绪
    for _t in setbright setprop crtcstate connprops; do
        if ds_exec "[ -x '$CONT_ROOT/bin/$_t' ]" >/dev/null 2>&1; then
            ok "容器里 bin/$_t 就绪"
        else
            bad "容器里 bin/$_t 不可执行"
        fi
    done
else
    skip "容器侧工具自检（容器没跑或 payload 没同步进去）"
fi

# 安卓侧只需确认文件在（它们不在这里执行）
for _t in setbright setprop crtcstate connprops; do
    [ -x "$DRM_ROOT/bin/$_t" ] || bad "bin/$_t 缺失或不可执行"
done

# 静态检查（安卓上没有 python3，跳过）
if command -v python3 >/dev/null 2>&1 && [ -f "$DRM_ROOT/tools/lint/shell-lint.py" ]; then
    if python3 "$DRM_ROOT/tools/lint/shell-lint.py" >/dev/null 2>&1; then
        ok "shell-lint 通过"
    else
        warn "shell-lint 有告警（在开发机上跑一遍看详情）"
    fi
else
    skip "shell-lint（安卓上没有 python3）"
fi

# ════════════════════════════════════════════════════════════════════
head_ "F. 状态机"

_phase=$(drm_state_phase 2>/dev/null || echo unknown)
_bootid=$(drm_state_get BOOT_ID 2>/dev/null || echo "-")
_cur=$(drm_boot_id 2>/dev/null || echo "-")
ok "当前阶段: $_phase（记录 BOOT_ID=$_bootid，当前=$_cur）"
[ "$_bootid" != "$_cur" ] && warn "BOOT_ID 不一致 —— 重启过，状态会自动回到 android-active"

# ════════════════════════════════════════════════════════════════════
if [ "$DO_TAKEOVER" = 1 ]; then
    head_ "G. 真实接管（破坏性）"
    printf '  正在执行 enter ……（这一步会把屏幕交给 Linux）\n'
    if sh "$DRM_ROOT/core/switch.sh" enter; then
        _p=$(drm_state_phase 2>/dev/null || echo "?")
        _k=$(drm_state_get KWIN_HOLDS_DRM 2>/dev/null || echo "?")
        if [ "$_p" = "linux-active" ] && [ "$_k" = "1" ]; then
            ok "接管成功：phase=$_p，kwin 持有 $DEV_DRM_CARD"
        else
            bad "接管后状态不对：phase=$_p，KWIN_HOLDS_DRM=$_k"
        fi
    else
        bad "enter 失败" "看 $DRM_LOG_DIR 下的日志"
    fi
    printf '\n  返回安卓：su -c '\''sh %s/core/switch.sh exit'\''（会重启设备）\n' "$DRM_ROOT"
fi

# ════════════════════════════════════════════════════════════════════
printf '\n'
printf '════════════════════════════════════════════════════════════\n'
printf ' 结果: %d 通过 / %d 失败 / %d 警告 / %d 跳过\n' "$PASS" "$FAIL" "$WARN" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
    if [ "$WARN" -gt 0 ]; then
        printf ' 前置条件齐备（有 %d 条警告，逐条看一下）\n' "$WARN"
    else
        printf ' 前置条件全部齐备\n'
    fi
    [ "$DO_TAKEOVER" = 0 ] && printf '\n 下一步：DRM_TRIAL_SECS=150 sh %s/display/drm-takeover.sh\n（150 秒后自动回滚，比直接常驻安全）\n' "$DRM_ROOT"
else
    printf ' 有 %d 项失败 —— 先修掉再尝试接管\n' "$FAIL"
fi
printf '════════════════════════════════════════════════════════════\n\n'

exit "$FAIL"

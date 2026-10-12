#!/bin/sh
# nm-agent-fix.sh —— 让 plasma-nm 的密钥代理真正注册，使图形界面能输 WiFi 密码
#
# ══════════════════════════════════════════════════════════════════════
# 症状
# ══════════════════════════════════════════════════════════════════════
# 图形界面里点 WiFi 连不上，NM 日志：
#     device (wlan0): Activation: (wifi) access point 'XXX' has security,
#                     but secrets are required.
#     device (wlan0): state change: config -> need-auth
#     device (wlan0): no secrets: No agents were available for this request.
#     device (wlan0): state change: need-auth -> failed (reason 'no-secrets')
#
# ══════════════════════════════════════════════════════════════════════
# 根因
# ══════════════════════════════════════════════════════════════════════
# 连接文件里是 psk-flags=1（密钥交给密钥代理保管，这是**正确**的设置，
# 正是"在图形界面里输密码"该有的模式）。但 NM 问遍总线也没有代理应答。
#
# 提供代理的是 plasma-nm 的 kded 模块：
#     /usr/lib/aarch64-linux-gnu/qt6/plugins/kf6/kded/networkmanagement.so
# 它的元数据是**内嵌在 .so 里**的（X-KDE-Kded-autoload / SecretAgent），
# 所以不需要 /usr/share/kservices6/ 下的 .desktop —— 那个目录为空是正常的，
# 不要往那儿补文件。
#
# 真正的问题是：我们是**绕过 startplasma-wayland 手工起 plasmashell** 的，
# 所以 kded6 从来没有被正常拉起并加载模块。实测 autoloaded=true 也没用，
# 必须显式 loadModule 一次。
#
# ══════════════════════════════════════════════════════════════════════
# 关键细节（踩过的坑）
# ══════════════════════════════════════════════════════════════════════
# ★ kded6 的 DBus 对象路径是 **/kded**，不是 /kded6。
#   用 /kded6 会报 UnknownObject，看起来像"kded6 没起来"，其实是路径错了。
#     对：qdbus6 org.kde.kded6 /kded org.kde.kded6.loadModule networkmanagement
#
# ★ 加载成功的判据**不是** org.freedesktop.NetworkManager.SecretAgent 有没有 owner
#   —— 那个名字永远没有 owner。NM 的代理协议走 AgentManager.Register()，
#   代理用自己的唯一名（:1.xxx）注册。正确判据是 NM 日志里出现：
#     agent-manager: agent[...:1.xxx/org.kde.plasma.networkmanagement/1000]: agent registered
#
# ★ nmcli 不会弹窗（除非加 --ask），所以"nmcli connection up 失败"**不能**
#   用来判断代理有没有生效。要判断就看上面那行日志。
#   真正弹窗的是 plasmashell 里的 plasma-nm 小程序，也就是用户点托盘图标那条路。
# ══════════════════════════════════════════════════════════════════════

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER_NAME=${DESKTOP_USER:-Gold}
UID_N=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)
export HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/$UID_N
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus

run_kded() {
    runuser -u "$USER_NAME" -- env \
        HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        qdbus6 org.kde.kded6 /kded "$@"
}

echo "== 确保 kded6 在跑 =="
if ! pgrep -x kded6 >/dev/null 2>&1; then
    echo "  kded6 没在跑，启动它"
    runuser -u "$USER_NAME" -- env \
        HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        setsid nohup /usr/bin/kded6 >/var/log/kded6-drm.log 2>&1 </dev/null &
    sleep 5
fi
echo "  kded6 pid=$(pgrep -x kded6 | head -1)"

echo "== 加载 networkmanagement 模块 =="
run_kded org.kde.kded6.loadModule networkmanagement 2>&1 | sed 's/^/  loadModule: /'
sleep 3

echo "== 设为自动加载 =="
run_kded org.kde.kded6.setModuleAutoloading networkmanagement true 2>&1 | sed 's/^/  /'

echo "== 确认模块对象存在 =="
runuser -u "$USER_NAME" -- env \
    HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    qdbus6 org.kde.kded6 2>/dev/null | grep -a 'networkmanagement' | sed 's/^/  /'

echo "== 确认 NM 那边代理注册了 =="
journalctl -u NetworkManager --no-pager -n 120 2>/dev/null \
    | grep -aiE 'agent registered|no agents were available' | tail -3 | sed 's/^/  /'
echo
echo "  判据：出现 'org.kde.plasma.networkmanagement' 的 agent registered 就是成功。"
echo "  ★ 不要用 nmcli connection up 是否成功来判断 —— nmcli 不弹窗。"

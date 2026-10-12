/* drmfmt.so — LD_PRELOAD shim：**限制 KWin 能看到的连接器刷新率**。
 *
 * ══ 它解决什么问题 ══════════════════════════════════════════════════
 * 本机面板（connector 67，3200x2000 DSC 面板）暴露 4 个模式：
 *     [0] ★PREFERRED 3200x2000x120vid  htotal=3524  clock=955708
 *     [1]            3200x2000x144vid  htotal=3328  clock=1083064
 *     [2]            3200x2000x90vid   htotal=3916  clock=796514
 *     [3]            3200x2000x60vid   htotal=3524  clock=955708
 * 其中 120vid 带 DRM_MODE_TYPE_PREFERRED，**KWin 必然选它**。
 *
 * 但实测（tools/probe/modelist + kmsdump）：接管后 **CRTC 200 上真正生效的是
 * 144vid**（clock=1083064，htotal=3328），和 KWin 选的 120vid 行时序完全不同。
 * 时序不一致 = 面板收到的行频/像素时钟与它预期的不符 ⇒ 彩色噪声。
 *
 * 于是需要一个办法把 KWin 的候选模式**收窄**到指定的刷新率，
 * 逼它去选和 CRTC 一致的那个。本 shim 就干这件事。
 *
 * ══ 用法 ═══════════════════════════════════════════════════════════
 *   DRM_MODE_KEEP_HZ=144           只保留 144Hz（其余从候选里摘掉）
 *   DRM_MODE_KEEP_HZ=144,120       保留多个
 *   不设 / 空                      完全不干预（默认）
 *   DRM_MODE_LOG=<path>            追加诊断日志
 *                                  ★ 路径避开 /root：本 shim 以桌面账号运行
 *
 * ══ 为什么拦 drmModeGetConnector ═══════════════════════════════════
 * KWin 枚举模式走 drmModeGetConnector()，拿到 drmModeConnector.modes[]。
 * 就地压实这个数组并改小 count_modes 即可 —— 调用方随后用
 * drmModeFreeConnector() 释放，而 libdrm 释放的是整个 malloc 块，
 * 与 count_modes 无关，所以原地收缩是安全的。
 *
 * ══ 历史（避免重蹈覆辙）═══════════════════════════════════════════
 * 本文件**曾经**是"把 10 位像素格式从 IN_FORMATS 里摘掉、逼 KWin 选 8 位"。
 * 那个归因已被实测推翻：
 *   - 用户确认真机面板是 **10 位 DSC 面板，10 位缓冲颜色才正确**；
 *   - "10 位缓冲是垃圾"的观察，实际是 plasmashell 走硬件 GL 把整个场景
 *     写坏造成的（修法是 core/device/opd2511.sh 里的
 *     DEV_QT_QUICK_BACKEND=software），与位深无关。
 * 所以位深过滤逻辑已**整段删除**，不要再加回来。
 *
 * 交叉编译（WSL）：
 *   export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
 *   aarch64-linux-gnu-gcc -O2 -g -Wall -shared -fPIC -o drmfmt.so drmfmt.c \
 *       $(pkg-config --cflags libdrm) -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

/* ── 诊断日志 ────────────────────────────────────────────────────────
 * ★ 实测教训：**不能只靠写文件**。kwinwrap 会给 kwin_wayland 装
 *   seccomp 过滤器（KWINWRAP_SECCOMP=1），open() 被挡掉 —— 日志文件
 *   永远不出现，看起来像"shim 没加载"，实际它好好地在那儿。
 *   所以这里**同时**往 stderr 写一份；kwin.log 就是重定向的 stderr，
 *   一定能看到。文件那份保留给非 seccomp 场景（比如 tools/probe 直接跑）。 */
static void flog(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if (n > (int)sizeof buf - 1)
        n = (int)sizeof buf - 1;

    (void)!write(2, buf, (size_t)n);

    const char *p = getenv("DRM_MODE_LOG");
    if (!p || !*p)
        return;
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    (void)!write(fd, buf, (size_t)n);
    close(fd);
}

/* ── 允许的刷新率列表 ──────────────────────────────────────────────── */
#define HZ_MAX 16
static int g_hz[HZ_MAX];
static int g_nhz = -1;          /* -1 = 还没解析 */

static void parse_hz(void)
{
    if (g_nhz >= 0)
        return;
    g_nhz = 0;
    const char *s = getenv("DRM_MODE_KEEP_HZ");
    if (!s || !*s)
        return;
    while (*s && g_nhz < HZ_MAX) {
        while (*s == ',' || *s == ' ')
            s++;
        if (!*s)
            break;
        char *end = NULL;
        long v = strtol(s, &end, 10);
        if (end == s)
            break;
        if (v > 0 && v < 1000)
            g_hz[g_nhz++] = (int)v;
        s = end;
    }
}

/* 从模式名里抠出刷新率：本机名字形如 "3200x2000x120vid"。
 * 先试 drmModeModeInfo.vrefresh；它为 0 时再解析名字。 */
static int mode_hz(const drmModeModeInfo *m)
{
    if (m->vrefresh > 0 && m->vrefresh < 1000)
        return m->vrefresh;
    const char *p = strrchr(m->name, 'x');
    if (!p)
        return 0;
    return (int)strtol(p + 1, NULL, 10);
}

static int hz_allowed(int hz)
{
    for (int i = 0; i < g_nhz; i++)
        if (g_hz[i] == hz)
            return 1;
    return 0;
}

/* ── 插桩：连接器模式列表 ──────────────────────────────────────────── */
drmModeConnectorPtr drmModeGetConnector(int fd, uint32_t connector_id)
{
    static drmModeConnectorPtr (*real)(int, uint32_t);
    if (!real)
        real = dlsym(RTLD_NEXT, "drmModeGetConnector");
    if (!real)
        return NULL;

    drmModeConnectorPtr c = real(fd, connector_id);
    if (!c || !c->modes || c->count_modes <= 0)
        return c;

    parse_hz();
    if (g_nhz == 0)
        return c;                    /* 没配置 → 不干预 */

    /* 先数一遍会留下几个；一个都不留就整个放弃（避免把面板搞成无模式） */
    int keep = 0;
    for (int i = 0; i < c->count_modes; i++)
        if (hz_allowed(mode_hz(&c->modes[i])))
            keep++;
    if (!keep) {
        flog("drmfmt: conn %u 有 %d 个模式，但没有一个落在允许列表里 —— 不干预\n",
             connector_id, c->count_modes);
        return c;
    }

    int w = 0;
    for (int i = 0; i < c->count_modes; i++) {
        if (!hz_allowed(mode_hz(&c->modes[i])))
            continue;
        /* 原地压实是安全的：w <= i 恒成立 */
        c->modes[w++] = c->modes[i];
    }
    flog("drmfmt: conn %u 模式 %d → %d（只留 %s）\n",
         connector_id, c->count_modes, w, getenv("DRM_MODE_KEEP_HZ"));
    c->count_modes = w;
    return c;
}

/* ── 构造探针：确认 shim 真的被加载进了目标进程 ──────────────────────
 * 实测教训：shim 出现在 /proc/<pid>/maps 里**不代表**它拦到了调用 ——
 * KWin 可能根本不走 libdrm 的 drmModeGetConnector（或者走了别的符号）。
 * 有了这行构造日志，就能一眼区分"没加载"和"加载了但没拦到"。
 *
 * ★ 同时往 stderr 写一份：flog 走 open()+write()，而 kwinwrap 会给
 *   kwin_wayland 装 **seccomp 过滤器**（KWINWRAP_SECCOMP=1），open 可能
 *   被挡掉 —— 那时日志文件不会出现，但 write(2) 到 stderr 仍能出去
 *   （kwin.log 就是重定向的 stderr）。两条路都走，才能区分
 *   "没加载" / "加载了但 open 被 seccomp 挡" / "加载了但没拦到调用"。 */
__attribute__((constructor)) static void drmfmt_init(void)
{
    flog("drmfmt: 已加载（pid=%d）KEEP_HZ=%s LOG=%s\n", (int)getpid(),
         getenv("DRM_MODE_KEEP_HZ") ? getenv("DRM_MODE_KEEP_HZ") : "(未设)",
         getenv("DRM_MODE_LOG") ? getenv("DRM_MODE_LOG") : "(未设)");
}

/* ── 探针：drmModeGetResources —— KWin 必然要调它，用来确认 libdrm 路径 ── */
drmModeResPtr drmModeGetResources(int fd)
{
    static drmModeResPtr (*real)(int);
    if (!real)
        real = dlsym(RTLD_NEXT, "drmModeGetResources");
    if (!real)
        return NULL;
    drmModeResPtr r = real(fd);
    flog("drmfmt: drmModeGetResources(fd=%d) → %s (conns=%d crtcs=%d)\n",
         fd, r ? "ok" : "null", r ? r->count_connectors : -1,
         r ? r->count_crtcs : -1);
    return r;
}

/* ── 探针：drmSetClientCap —— 用来确认 KWin 的 DRM 调用确实经过 libdrm ── */
int drmSetClientCap(int fd, uint64_t capability, uint64_t value)
{
    static int (*real)(int, uint64_t, uint64_t);
    if (!real)
        real = dlsym(RTLD_NEXT, "drmSetClientCap");
    if (!real)
        return -1;
    int r = real(fd, capability, value);
    flog("drmfmt: drmSetClientCap(fd=%d cap=%llu val=%llu) = %d\n", fd,
         (unsigned long long)capability, (unsigned long long)value, r);
    return r;
}

/* ── 也拦 drmModeGetConnectorCurrent（部分调用方走这条）────────────── */
drmModeConnectorPtr drmModeGetConnectorCurrent(int fd, uint32_t connector_id)
{
    static drmModeConnectorPtr (*real)(int, uint32_t);
    if (!real)
        real = dlsym(RTLD_NEXT, "drmModeGetConnectorCurrent");
    if (!real)
        return NULL;

    drmModeConnectorPtr c = real(fd, connector_id);
    if (!c || !c->modes || c->count_modes <= 0)
        return c;

    parse_hz();
    if (g_nhz == 0)
        return c;

    int keep = 0;
    for (int i = 0; i < c->count_modes; i++)
        if (hz_allowed(mode_hz(&c->modes[i])))
            keep++;
    if (!keep)
        return c;

    int w = 0;
    for (int i = 0; i < c->count_modes; i++) {
        if (!hz_allowed(mode_hz(&c->modes[i])))
            continue;
        c->modes[w++] = c->modes[i];
    }
    flog("drmfmt: conn %u(Current) 模式 %d → %d\n", connector_id, c->count_modes, w);
    c->count_modes = w;
    return c;
}

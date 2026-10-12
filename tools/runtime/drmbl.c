/* drmbl —— 通过 kwinwrap 的 master fd 写 DRM 连接器属性（本机是面板背光）
 *
 * ══════════════════ 为什么需要这个工具（2026-10-13 实测） ══════════════════
 *
 * 用户需求：「电源键锁屏**并熄灭面板**」。实测发现本机面板的背光**只能**由
 * DRM 连接器 67 的 `brightness` 属性（prop id 82）控制，其它路全是死的：
 *
 *   ① sysfs /sys/class/backlight/panel0-backlight 是**假的**。
 *      内核 dmesg 原话：
 *          [drm:dsi_panel_set_backlight [msm_drm]] [msm-dsi-info]: bypass bl 0
 *      驱动把写入直接 bypass 掉了。实测 brightness=0 + bl_power=4（POWERDOWN）
 *      屏幕**照样亮**（用户确认"亮屏"）。
 *      ⇒ 上游 opd2413 的 drm-powerkey.py 靠写 sysfs 熄屏，在**本机不成立**
 *        （上游 max_brightness=2047，本机 4095 —— 是不同面板）。
 *
 *   ② KWin 自己的亮度控制（kscreen-doctor output.DSI-1.brightness.N）
 *      **走的就是 sysfs**（实测设 0 后 sysfs 变 5、设 dimming 0 后变 1），
 *      而驱动把亮度 clamp 到最低档 ⇒ 这正是用户说的
 *      「最低亮度不是黑屏」。
 *      kscreen-doctor -o 里那句 "Brightness control: supported, set to 50%"
 *      只是 KWin 的**内部状态**，不代表面板真的变了。
 *
 *   ③ 那个 DRM 属性的 flags=0x00000002（DRM_MODE_PROP_RANGE），
 *      **没有** DRM_MODE_PROP_ATOMIC ⇒ 不能塞进 atomic 提交
 *      （塞了会被判 EINVAL，把整次提交打成 -22 —— DPMS 属性同理，
 *       见 kwinwrap.c 里 KWINWRAP_DPMS_INJECT 那段注释）
 *      ⇒ 只能用**非原子** ioctl DRM_IOCTL_MODE_OBJ_SETPROPERTY，
 *        而它要求调用者是 DRM master。
 *
 *   ④ master 在 KWin 手里 ⇒ 任何外部进程写都得到
 *      `set 0 -> -1 (Permission denied)`（setbright/setprop 实测如此）。
 *
 *   ⑤ **Android 关屏做的正是这件事** —— kwinwrap.c 里的原注释：
 *          "Android blanking writes connector brightness=0 before dying"
 *      ⇒ 这就是"真正的关屏"在本机的唯一含义。
 *
 * ══════════════════ 怎么拿到 master（关键洞察） ══════════════════
 *
 * kwinwrap 是 DRM 交接桥。它在 exec KWin **之前**：
 *     DRMFD = open("/dev/dri/card0", O_RDWR|O_CLOEXEC);   ← 自动成为 master
 *     dup2(DRMFD, HIJACK_FD);                             ← HIJACK_FD = 250
 * 然后把 KWin 的 open("/dev/dri/card0") **改写成 dup(250)**
 * （见 kwinwrap.c 的 hijack_entry()）。
 *
 * ⇒ KWin 拿到的 fd 和 kwinwrap 的 fd 250 指向**同一个 file description**
 *   ⇒ 它们共享 DRM_MASTER
 *   ⇒ **kwinwrap 的 fd 250 现在仍然是 master**，即使它自己以为
 *     "DROP_MASTER 之后就没权限了"。
 *
 * 实测证据：
 *     /proc/19969/fd/250 -> /dev/dri/card0     (kwinwrap)
 *     /proc/19975/fd/250 -> /dev/dri/card0     (kwin，同一个 fd 号)
 *
 * 于是用 pidfd_getfd(2)（Linux 5.6+，本机内核 6.1.177）从 kwinwrap 那里
 * **复制**一份 fd 出来，就能以 master 身份写属性。
 * 不需要改 kwinwrap、不需要重启 KWin、不需要碰 atomic 提交。
 *
 * ══════════════════ 用法 ══════════════════
 *   drmbl show                 打印当前 brightness / DPMS
 *   drmbl set <0..4095>        设 brightness
 *   drmbl blank                熄灭面板（brightness=0，记住原值）
 *   drmbl unblank              恢复（读回记住的原值）
 *   drmbl props                列出连接器全部属性（id / flags / 范围 / 当前值）
 *   drmbl prop <名> <值>       设任意属性（排查用）
 *   drmbl dpms on|off          ★ 真正关/开面板（必须非原子写，KWin 做不到）
 *   drmbl probe                只做探测，报告能不能拿到 master fd
 *
 * ★ 真正的全黑 = `drmbl blank`（brightness=0）**加上** `drmbl dpms off`。
 *   缺一不可：单独 brightness=0 只是「很暗但看得见」（面板硬件下限），
 *   单独 dpms off 是「画面黑但背光还亮」。
 *
 * ★ `kscreen-doctor --dpms off` 在本机**无效**：本内核的 DPMS 属性
 *   flags=0x08 只有 DRM_MODE_PROP_ENUM，**没有 ATOMIC 位**，而 KWin 只会把它
 *   塞进原子提交 ⇒ 内核一律判 EINVAL ⇒ 日志刷 "Setting dpms mode failed!"，
 *   DPMS 纹丝不动（实测连查 12 秒仍是 On），屏幕只闪一下。
 *   ⇒ DPMS 只能用非原子 ioctl 写，这正是本工具用 pidfd_getfd 借 master fd 的理由。
 *   安卓走的是另一条路（CRTC ACTIVE=0，原子属性，合法），我们照抄不了，
 *   因为那个 CRTC 的原子状态在 KWin 手里。
 *
 * 退出码：0 成功；1 失败（原因打到 stderr）
 *
 * ══════════════════ 安全 ══════════════════
 *   · 只读 /proc 和写一个 DRM 属性，不碰 rfkill / 网络 / 容器配置。
 *   · `blank` 会把原亮度存到 /run/drmbl.saved，`unblank` 读它。
 *     存 0 视为无效（防止把"已熄灭"当成原值存下来 ⇒ 永远恢复不了）。
 *   · 拿不到 master fd 时**不猜**，直接报错退出。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define SAVED "/run/drmbl.saved"
/* crtc-off 时把 CRTC 的 MODE_ID blob 存这儿，crtc-on 要写回去（见 crtc-on）。
 * ★ 必须是**单独的**文件：SAVED 里放的是亮度，两者生命周期不同。 */
#define SAVED_CRTC "/run/drmbl.crtc"

/* 面板 connector / 属性名。可由环境变量覆盖，方便换设备。 */
static unsigned CONN = 0;               /* 0 = 自动发现 */

static int verbose;

/* ── pidfd 系统调用（glibc 未必有包装） ── */
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif

static int pidfd_open_(pid_t pid, unsigned flags)
{
    return (int)syscall(SYS_pidfd_open, pid, flags);
}

static int pidfd_getfd_(int pidfd, int targetfd, unsigned flags)
{
    return (int)syscall(SYS_pidfd_getfd, pidfd, targetfd, flags);
}

/* ── 前置声明 ──
 * 这些辅助函数的定义在下面（顺序按"先讲清楚为什么，再给实现"排的），
 * 而 borrow_master_fd 要用它们，所以这里先声明。 */
struct cand { pid_t pid; int fd; };
static int collect_cands(struct cand *out, int max);
static int steal_fd(pid_t pid, int targetfd);
static unsigned find_conn(int fd);
static unsigned find_prop(int fd, unsigned conn, const char *name);
static unsigned long long get_prop(int fd, unsigned conn, const char *name);

/* ── 借一个**真的是 master** 的 fd ──
 *
 * 做法（见 collect_cands 上面的长注释）：
 *   ① 收集 kwin_wayland / kwinwrap 所有指向 cardN 的 fd
 *   ② 用第一个 fd 只读地枚举 connector + 属性 id（读不需要 master）
 *   ③ 逐个 fd 试着**写**一个无害的、值不变的自赋值（brightness = 当前值）
 *      —— 成功就说明这个 fd 是 master，返回它
 *
 * ★ 为什么用"自赋值"当探针：它不改任何状态（写进去的就是读出来的值），
 *   但**权限检查照样会跑**，所以能准确区分 EACCES 和成功。
 *   比"直接写 0 然后看失败没"安全得多 —— 万一第一个 fd 恰好是 master，
 *   直接写 0 就把屏幕灭了。
 */
static int borrow_master_fd(void)
{
    struct cand cs[64];
    int n, i, first = -1;
    int conn;
    unsigned prop;
    unsigned long long cur;

    n = collect_cands(cs, 64);
    if (n <= 0) {
        fprintf(stderr, "drmbl: 找不到 kwin_wayland/kwinwrap 打开的 /dev/dri/cardN\n"
                        "       （KWin 不是由 kwinwrap 拉起的？或者 DRM 节点路径不同）\n");
        return -1;
    }
    if (verbose) {
        fprintf(stderr, "drmbl: 找到 %d 个候选 fd：\n", n);
        for (i = 0; i < n; i++)
            fprintf(stderr, "        pid=%d fd=%d\n", cs[i].pid, cs[i].fd);
    }

    /* ① 先偷一个出来做只读枚举 */
    first = steal_fd(cs[0].pid, cs[0].fd);
    if (first < 0) {
        fprintf(stderr, "drmbl: pidfd_getfd(pid=%d, fd=%d) 失败: %s\n"
                        "       （需要 root + CAP_SYS_PTRACE）\n",
                cs[0].pid, cs[0].fd, strerror(errno));
        return -1;
    }

    conn = find_conn(first);
    if (!conn) {
        fprintf(stderr, "drmbl: 找不到带 brightness 属性的已连接 connector\n");
        close(first);
        return -1;
    }
    prop = find_prop(first, conn, "brightness");
    if (!prop) {
        fprintf(stderr, "drmbl: conn%u 上没有 brightness 属性\n", conn);
        close(first);
        return -1;
    }
    cur = get_prop(first, conn, "brightness");

    /* ② 逐个试：写"当前值"（不改状态，但会走权限检查） */
    for (i = 0; i < n; i++) {
        int fd = (i == 0) ? first : steal_fd(cs[i].pid, cs[i].fd);
        struct drm_mode_obj_set_property sp;
        int r;

        if (fd < 0)
            continue;

        memset(&sp, 0, sizeof sp);
        sp.obj_id = conn;
        sp.obj_type = DRM_MODE_OBJECT_CONNECTOR;
        sp.prop_id = prop;
        sp.value = cur;

        errno = 0;
        r = ioctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
        if (r == 0) {
            if (verbose)
                fprintf(stderr, "drmbl: ★ pid=%d fd=%d 是 master（自赋值探针通过）\n",
                        cs[i].pid, cs[i].fd);
            /* 关掉其他候选的副本，避免 fd 泄漏 */
            if (i != 0)
                close(first);
            return fd;
        }
        if (verbose)
            fprintf(stderr, "drmbl: pid=%d fd=%d 不是 master（%s）\n",
                    cs[i].pid, cs[i].fd, strerror(errno));
        if (i != 0)
            close(fd);
    }

    close(first);
    fprintf(stderr, "drmbl: 所有候选 fd 都不是 DRM master\n"
                    "       （KWin 可能用了别的 fd 持有 master；"
                    "用 DRMBL_VERBOSE=1 看逐个尝试的结果）\n");
    return -1;
}

/* ── 找候选进程 ──
 *
 * ★★★★ 2026-10-13 实测修正：**必须优先从 kwin_wayland 偷，不是 kwinwrap** ★★★★
 *
 * 原来的假设（错的）：kwinwrap 把 KWin 的 open("/dev/dri/card0") 改写成
 * dup(HIJACK_FD=250)，所以两者的 fd 250 是同一个 file description，共享
 * DRM_MASTER，从 kwinwrap 那里借就行。
 *
 * 实测打脸：
 *     /proc/19969/fdinfo/250  mnt_id 12051  ino 1595   (kwinwrap)
 *     /proc/19975/fdinfo/250  mnt_id 12051  ino 1595   (kwin)
 *     /proc/19975/fdinfo/17   mnt_id  786   ino 1595   (kwin)
 * 前两个确实是同一个 file description（mnt_id+ino 相同），**但它不是 master**：
 * 用借来的 fd 写 brightness 和 DPMS 都是 EACCES。
 * 而 KWin 的 fd 17 走的是另一个挂载视图（mnt_id 786），它才是 master ——
 * 也就是说 hijack 那条路在本机**没有生效**，KWin 是自己 open 的 card0
 * 并 SET_MASTER 的，kwinwrap 的 250 早就 DROP_MASTER 了。
 *
 * ⇒ 正确做法：从 kwin_wayland 偷。它有好几个 card0 fd（实测 6 个），
 *   master 是 per-file 的，只有一个（或共享同一 file 的几个）是。
 *   所以**逐个试**：拿一个 fd 试着写属性，成功就用它。
 *   这也顺带自证了"到底哪个 fd 是 master"，不用猜。
 */
static const char *CAND_COMMS[] = { "kwin_wayland", "kwinwrap", NULL };

/* 找出所有候选进程里所有指向 /dev/dri/cardN 的 fd。
 * 返回个数；out 里存 pid/fd 对。 */
static int collect_cands(struct cand *out, int max)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    int n = 0;
    int rank;

    if (!d)
        return 0;
    /* 按 CAND_COMMS 的顺序收集：先 kwin_wayland 的所有 fd，再 kwinwrap 的 */
    for (rank = 0; CAND_COMMS[rank] && n < max; rank++) {
        rewinddir(d);
        while ((e = readdir(d)) && n < max) {
            char commp[400], buf[64], fddir[400];
            DIR *fd_d;
            struct dirent *fe;
            int cfd;
            ssize_t k;

            if (!isdigit((unsigned char)e->d_name[0]))
                continue;
            snprintf(commp, sizeof commp, "/proc/%s/comm", e->d_name);
            cfd = open(commp, O_RDONLY);
            if (cfd < 0)
                continue;
            k = read(cfd, buf, sizeof buf - 1);
            close(cfd);
            if (k <= 0)
                continue;
            buf[k] = 0;
            if (strncmp(buf, CAND_COMMS[rank], strlen(CAND_COMMS[rank])) != 0)
                continue;

            snprintf(fddir, sizeof fddir, "/proc/%s/fd", e->d_name);
            fd_d = opendir(fddir);
            if (!fd_d)
                continue;
            while ((fe = readdir(fd_d)) && n < max) {
                char link[800], tgt[320];
                ssize_t m;

                if (!isdigit((unsigned char)fe->d_name[0]))
                    continue;
                snprintf(link, sizeof link, "%s/%s", fddir, fe->d_name);
                m = readlink(link, tgt, sizeof tgt - 1);
                if (m <= 0)
                    continue;
                tgt[m] = 0;
                if (strncmp(tgt, "/dev/dri/card", 13) != 0)
                    continue;
                out[n].pid = (pid_t)atoi(e->d_name);
                out[n].fd = atoi(fe->d_name);
                n++;
            }
            closedir(fd_d);
        }
    }
    closedir(d);
    return n;
}

/* 从一个进程偷一个 fd 出来（复制同一个 file description）。 */
static int steal_fd(pid_t pid, int targetfd)
{
    int pfd = pidfd_open_(pid, 0);
    int fd;

    if (pfd < 0)
        return -1;
    fd = pidfd_getfd_(pfd, targetfd, 0);
    close(pfd);
    return fd;
}

/* ── 找面板 connector ── */
static unsigned find_conn(int fd)
{
    drmModeRes *res;
    unsigned i, best = 0;

    if (CONN)
        return CONN;
    res = drmModeGetResources(fd);
    if (!res) {
        fprintf(stderr, "drmbl: drmModeGetResources 失败: %s\n", strerror(errno));
        return 0;
    }
    for (i = 0; i < (unsigned)res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c)
            continue;
        /* 要"已连接且有模式"的那个（本机是 DSI-1） */
        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            /* 再确认它有 brightness 属性 */
            drmModeObjectProperties *p =
                drmModeObjectGetProperties(fd, c->connector_id,
                                           DRM_MODE_OBJECT_CONNECTOR);
            if (p) {
                unsigned k;
                for (k = 0; k < p->count_props; k++) {
                    drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[k]);
                    if (pr && strcmp(pr->name, "brightness") == 0) {
                        best = c->connector_id;
                        drmModeFreeProperty(pr);
                        break;
                    }
                    if (pr)
                        drmModeFreeProperty(pr);
                }
                drmModeFreeObjectProperties(p);
            }
        }
        drmModeFreeConnector(c);
        if (best)
            break;
    }
    drmModeFreeResources(res);
    return best;
}

/* ── 找属性 id ──
 *
 * ★ 2026-10-13 泛化：原来只认 CONNECTOR，现在带 obj_type 参数，
 *   因为要用同一套代码操作 CRTC 的 ACTIVE / MODE_ID（见 crtc-off/on）。
 */
static unsigned find_prop_t(int fd, unsigned obj, uint32_t obj_type,
                            const char *name)
{
    drmModeObjectProperties *p;
    unsigned id = 0, k;

    p = drmModeObjectGetProperties(fd, obj, obj_type);
    if (!p)
        return 0;
    for (k = 0; k < p->count_props; k++) {
        drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[k]);
        if (pr) {
            if (strcmp(pr->name, name) == 0)
                id = pr->prop_id;
            drmModeFreeProperty(pr);
        }
        if (id)
            break;
    }
    drmModeFreeObjectProperties(p);
    return id;
}

static unsigned long long get_prop_t(int fd, unsigned obj, uint32_t obj_type,
                                     const char *name)
{
    drmModeObjectProperties *p;
    unsigned k;
    unsigned long long v = 0;

    p = drmModeObjectGetProperties(fd, obj, obj_type);
    if (!p)
        return 0;
    for (k = 0; k < p->count_props; k++) {
        drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[k]);
        if (pr) {
            if (strcmp(pr->name, name) == 0)
                v = p->prop_values[k];
            drmModeFreeProperty(pr);
        }
    }
    drmModeFreeObjectProperties(p);
    return v;
}

static unsigned find_prop(int fd, unsigned conn, const char *name)
{
    return find_prop_t(fd, conn, DRM_MODE_OBJECT_CONNECTOR, name);
}

static unsigned long long get_prop(int fd, unsigned conn, const char *name)
{
    return get_prop_t(fd, conn, DRM_MODE_OBJECT_CONNECTOR, name);
}

/* ── 找面板 connector 当前接在哪个 CRTC 上 ──
 *
 * 走 connector -> encoder_id -> encoder -> crtc_id。本机是 67 -> 66 -> 200。
 * 为什么要动态查而不是写死 200：换设备/换拓扑时 CRTC 号会变，写死必然踩坑。
 */
static unsigned find_crtc(int fd, unsigned conn)
{
    drmModeConnector *c;
    drmModeEncoder *e;
    unsigned crtc = 0;

    c = drmModeGetConnector(fd, conn);
    if (!c)
        return 0;
    if (c->encoder_id) {
        e = drmModeGetEncoder(fd, c->encoder_id);
        if (e) {
            crtc = e->crtc_id;
            drmModeFreeEncoder(e);
        }
    }
    drmModeFreeConnector(c);
    return crtc;
}

/* ── 写属性（非原子） ──
 *
 * ★ 必须用 DRM_IOCTL_MODE_OBJ_SETPROPERTY，不能用 drmModeObjectSetProperty()
 *   —— 后者在新版 libdrm 里也走 OBJ_SETPROPERTY，但为了行为确定这里直接写。
 */
static int set_prop_t(int fd, unsigned obj, uint32_t obj_type,
                      const char *name, unsigned long long val)
{
    unsigned pid_ = find_prop_t(fd, obj, obj_type, name);
    struct drm_mode_obj_set_property sp;
    int r;

    if (!pid_) {
        fprintf(stderr, "drmbl: 对象 %u(type=%u) 上找不到属性 '%s'\n",
                obj, obj_type, name);
        return -1;
    }
    memset(&sp, 0, sizeof sp);
    sp.obj_id = obj;
    sp.obj_type = obj_type;
    sp.prop_id = pid_;
    sp.value = val;

    errno = 0;
    r = ioctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
    if (r != 0) {
        fprintf(stderr, "drmbl: 写 %s=%llu 失败: %s\n",
                name, val, strerror(errno));
        return -1;
    }
    if (verbose)
        fprintf(stderr, "drmbl: 写 %s=%llu OK (prop=%u)\n", name, val, pid_);
    return 0;
}

static int set_prop(int fd, unsigned conn, const char *name, unsigned long long val)
{
    return set_prop_t(fd, conn, DRM_MODE_OBJECT_CONNECTOR, name, val);
}

static int read_saved(void)
{
    FILE *f = fopen(SAVED, "r");
    int v = -1;
    if (!f)
        return -1;
    if (fscanf(f, "%d", &v) != 1)
        v = -1;
    fclose(f);
    return v;
}

static void write_saved(int v)
{
    FILE *f = fopen(SAVED, "w");
    if (!f) {
        fprintf(stderr, "drmbl: 警告：写 %s 失败: %s（恢复时要用默认值）\n",
                SAVED, strerror(errno));
        return;
    }
    fprintf(f, "%d\n", v);
    fclose(f);
}

static void usage(void)
{
    fprintf(stderr,
        "用法：drmbl <子命令>\n"
        "\n"
        "  show                  打印 connector 的 brightness / DPMS\n"
        "  set <0..4095>         设 brightness（0 = 面板下限，配合 DPMS off 才全黑）\n"
        "  blank                 熄面板（brightness=0，记住原值到 " SAVED "）\n"
        "  unblank               恢复面板（读回记住的原亮度）\n"
        "  props                 列出 connector 的所有属性（含 id / flags / 范围 / 当前值）\n"
        "  prop <名> <值>        设任意属性（排查用，如 prop bl_scale 0）\n"
        "  dpms on|off           ★ 真正关/开面板。必须非原子写 —— KWin 做不到（见源码注释）\n"
        "  crtcprops             列出面板所绑 CRTC 的属性（含 [ATOMIC] 标记）\n"
        "  crtcprop <名> <值>    设 CRTC 的任意属性（排查用，如 dim_layer_v1）\n"
        "  planes [all]          转储平面状态（crtc/fb/dst/src/zpos），查「左半屏黑」用\n"
        "  crtc-off              ★★ 把 CRTC 的 ACTIVE 置 0 —— **这才是安卓的息屏方式**，\n"
        "                           整个 CRTC 停摆、DSI 面板进睡眠，比 dpms off 更彻底\n"
        "  crtc-on               ★★ MODE_ID 写回 + ACTIVE=1 ⇒ **完整 modeset**，\n"
        "                           两条 DSI 链路都会重新初始化（修「唤醒后只亮半边」）\n"
        "  probe                 只探测能否借到 master fd\n"
        "\n"
        "★ 全黑 = `crtc-off`（推荐，安卓同款）+ `blank`（brightness=0）。\n"
        "  · 单独 brightness=0 只是「很暗但看得见」（面板硬件下限）\n"
        "  · 单独 dpms off 是「画面黑但背光仍亮」，而且**唤醒后会只亮半边**\n"
        "    （双 DSI 面板，DPMS 不重init 链路）⇒ 唤醒请用 crtc-on\n"
        "★ `kscreen-doctor --dpms` 在本机**无效**（DPMS 属性没有 ATOMIC 位，KWin 提交\n"
        "  一律被判 EINVAL，日志刷 'Setting dpms mode failed!'）。必须用本工具的 dpms。\n"
        "\n"
        "环境变量：\n"
        "  DRMBL_CONN=<id>       指定 connector（默认自动找有 brightness 的已连接口）\n"
        "  DRMBL_VERBOSE=1       打印借 fd 的过程\n"
        "  DRMBL_DEFAULT_BL=<n>  unblank 时没有记住值就用它（默认 2048）\n");
    exit(2);
}

int main(int argc, char **argv)
{
    const char *cmd;
    int fd, conn;
    const char *ce;
    const char *de;
    int defbl;

    if (argc < 2)
        usage();
    cmd = argv[1];

    ce = getenv("DRMBL_CONN");
    if (ce && *ce)
        CONN = (unsigned)strtoul(ce, NULL, 0);
    de = getenv("DRMBL_VERBOSE");
    verbose = (de && *de && *de != '0');
    de = getenv("DRMBL_DEFAULT_BL");
    defbl = (de && *de) ? atoi(de) : 2048;

    fd = borrow_master_fd();
    if (fd < 0)
        return 1;

    conn = find_conn(fd);
    if (!conn) {
        fprintf(stderr, "drmbl: 找不到带 brightness 属性的已连接 connector\n");
        close(fd);
        return 1;
    }

    if (strcmp(cmd, "probe") == 0) {
        printf("kwinwrap master fd 借用成功（fd=%d），connector=%u\n", fd, conn);
        printf("brightness=%llu  DPMS=%llu\n",
               get_prop(fd, conn, "brightness"), get_prop(fd, conn, "DPMS"));
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "show") == 0) {
        printf("connector %u  brightness=%llu  DPMS=%llu\n",
               conn, get_prop(fd, conn, "brightness"),
               get_prop(fd, conn, "DPMS"));
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "set") == 0) {
        unsigned long long v;
        if (argc < 3)
            usage();
        v = strtoull(argv[2], NULL, 0);
        if (set_prop(fd, conn, "brightness", v) != 0) {
            close(fd);
            return 1;
        }
        printf("brightness=%llu\n", get_prop(fd, conn, "brightness"));
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "blank") == 0) {
        unsigned long long cur = get_prop(fd, conn, "brightness");
        /* ★ 只在原值可用时保存。cur==0 说明已经熄着，别把 0 当原值存下来。 */
        if (cur > 0) {
            int s = read_saved();
            if (s <= 0)
                write_saved((int)cur);
        }
        if (set_prop(fd, conn, "brightness", 0) != 0) {
            close(fd);
            return 1;
        }
        printf("已熄灭面板（brightness 0，原值 %llu 存于 %s）\n", cur, SAVED);
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "unblank") == 0) {
        int v = read_saved();
        if (v <= 0)
            v = defbl;
        if (set_prop(fd, conn, "brightness", (unsigned long long)v) != 0) {
            close(fd);
            return 1;
        }
        printf("已点亮面板（brightness %d）\n", v);
        close(fd);
        return 0;
    }

    /* ★★★★ DPMS：本机唯一能真正关掉面板的手段，**必须用非原子 ioctl** ★★★★
     *
     * ══ 为什么不能交给 KWin / kscreen-doctor（2026-10-13 查清）══
     *
     * `kscreen-doctor --dpms off` 返回 rc=0，但 KWin 日志刷屏：
     *     kwin_wayland_drm: Setting dpms mode failed!
     * 结果 DPMS 纹丝不动（实测连查 12 秒都是 DPMS=0），屏幕只闪一下。
     *
     * 根因在**本内核的属性定义**（见 kwinwrap.c 第 1597 / 2213 行同样的结论）：
     *     conn67 "DPMS"  flags=0x00000008   ← 只有 DRM_MODE_PROP_ENUM
     * 没有 DRM_MODE_PROP_ATOMIC。而 KWin 只会把 DPMS 塞进 **atomic** 提交，
     * 内核因此一律判 EINVAL ⇒ KWin 在这台设备上**永远关不掉屏**。
     * （kwinwrap 试过往提交里注入 DPMS，同样失败，注释留在那里了。）
     *
     * ⇒ 结论：DPMS 只能用**非原子** DRM_IOCTL_MODE_OBJ_SETPROPERTY 写，
     *   而它要求 master 权限 —— 这正是本工具存在的理由（pidfd_getfd 借 fd）。
     *
     * ══ 安卓是怎么做到的（同一个驱动、同一块屏）══
     *
     * 安卓不走 DPMS，走 **CRTC 的 ACTIVE=0**（SurfaceFlinger → HWC/sde）。
     * ACTIVE 是**原子**属性，合法，于是整个 CRTC 停摆、DSI 面板进睡眠 ——
     * 比 DPMS 更彻底。我们没法照抄：KWin 持有那个 CRTC 的原子状态。
     *
     * ══ 已知副作用与应对 ══
     *
     * 从旁边写 DPMS 会让 KWin 的内部状态和内核不一致。熄屏期间无害
     * （屏幕本来就黑），但**唤醒时必须让 KWin 重新提交一次**，否则可能
     * 只亮半边（双 DSI 面板实测踩过：左半屏黑，见下）。
     *
     * ⇒ 因此 lockscreen.sh 的 panel-on 在 dpms on + unblank 之后，
     *   还会补一发 `kscreen-doctor --dpms on` 逼 KWin 重画；
     *   万一还是半边，用 display/kwin-restart.sh 重启 KWin（已验证可恢复）。
     *
     * 用法：drmbl dpms on | off
     */
    if (strcmp(cmd, "dpms") == 0) {
        const char *w = (argc >= 3) ? argv[2] : NULL;
        if (!w || (strcmp(w, "on") && strcmp(w, "off"))) {
            fprintf(stderr, "用法：drmbl dpms on|off\n");
            close(fd);
            return 2;
        }
        /* DRM_MODE_DPMS_ON == 0，DRM_MODE_DPMS_OFF == 3 */
        unsigned long long v = strcmp(w, "off") == 0 ? 3ULL : 0ULL;
        if (set_prop(fd, conn, "DPMS", v) != 0) {
            close(fd);
            return 1;
        }
        unsigned long long got = get_prop(fd, conn, "DPMS");
        printf("DPMS=%llu（%s）%s\n", got, got == v ? "已生效" : "★ 未生效",
               got == v ? "" : "  ⇒ 面板不会真正关闭");
        close(fd);
        return got == v ? 0 : 1;
    }

    if (strcmp(cmd, "props") == 0) {
        drmModeObjectProperties *p =
            drmModeObjectGetProperties(fd, conn, DRM_MODE_OBJECT_CONNECTOR);
        unsigned k;
        if (!p) {
            fprintf(stderr, "drmbl: 读属性表失败: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        for (k = 0; k < p->count_props; k++) {
            drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[k]);
            if (pr) {
                char rng[64] = "";
                if ((pr->flags & DRM_MODE_PROP_RANGE) && pr->count_values >= 2)
                    snprintf(rng, sizeof rng, " range [%llu..%llu]",
                             (unsigned long long)pr->values[0],
                             (unsigned long long)pr->values[1]);
                printf("%4u  %-24s flags 0x%08x  val %llu%s\n",
                       pr->prop_id, pr->name, pr->flags,
                       (unsigned long long)p->prop_values[k], rng);
                drmModeFreeProperty(pr);
            }
        }
        drmModeFreeObjectProperties(p);
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "prop") == 0) {
        unsigned long long v;
        if (argc < 4)
            usage();
        v = strtoull(argv[3], NULL, 0);
        if (set_prop(fd, conn, argv[2], v) != 0) {
            close(fd);
            return 1;
        }
        printf("%s=%llu\n", argv[2], get_prop(fd, conn, argv[2]));
        close(fd);
        return 0;
    }

    /* ★★★★ CRTC 开关：**这才是安卓真正的息屏方式** ★★★★
     *
     * ══ 为什么必须再加这一层（2026-10-13 实测结论）══
     *
     * `drmbl dpms off` 确实能把面板关黑（DPMS=3 稳定保持），但**唤醒后会
     * 只亮一半** —— 这块面板是**双 DSI + DSC**，左半走 DSI0、右半走 DSI1。
     * DPMS off/on 只切换 connector 的电源状态，**不重新初始化 DSI 链路**，
     * 于是唤醒后有一条链路没起来 ⇒ 物理上就是半块屏是黑的。
     *
     * 实测排除了"plane 没重建"这个方向：kwinwrap 在 `do_split` 为真时本来
     * 就会把 4 条 plane 全部补齐（缺失的段用同一个 FB 裁出来），所以不是
     * 平面的问题。唯一能修好的是**完整 modeset** —— 实测重启 KWin 100% 恢复，
     * 而 plane 级、scale 级、rotation 级、Compositing 级的折腾全部无效。
     *
     * ══ 安卓走的就是这条路 ══
     *
     * SurfaceFlinger → HWC/sde 息屏时把 **CRTC 的 ACTIVE 置 0**，整个 CRTC
     * 停摆、DSI 面板进睡眠；亮屏时重新 ACTIVE=1 + MODE_ID ⇒ 完整 modeset
     * ⇒ 两条 DSI 链路都会重新初始化。这正好就是我们要的语义。
     *
     * ══ 和 DPMS 的关系 ══
     *
     * ACTIVE 是普通属性（有 RANGE/ENUM，非原子写合法），所以同样用
     * DRM_IOCTL_MODE_OBJ_SETPROPERTY 写，同样需要 master fd。
     * 两个都留着：`crtc-off` 关得更彻底（CRTC 停摆，最省电），
     * `dpms off` 作为兜底（万一某些内核不允许非原子改 ACTIVE）。
     * lockscreen.sh 现在两个都发，唤醒时先 crtc-on 再 dpms on。
     *
     * 用法：drmbl crtcprops | crtc-off | crtc-on
     */
    if (strcmp(cmd, "crtcprops") == 0) {
        unsigned crtc = find_crtc(fd, conn);
        drmModeObjectProperties *p;
        unsigned k;
        if (!crtc) {
            fprintf(stderr, "drmbl: connector %u 没绑 CRTC\n", conn);
            close(fd);
            return 1;
        }
        p = drmModeObjectGetProperties(fd, crtc, DRM_MODE_OBJECT_CRTC);
        if (!p) {
            fprintf(stderr, "drmbl: 读 crtc%u 属性失败: %s\n", crtc, strerror(errno));
            close(fd);
            return 1;
        }
        printf("crtc%u（connector %u 当前所绑）%u 个属性\n", crtc, conn, p->count_props);
        for (k = 0; k < p->count_props; k++) {
            drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[k]);
            if (pr) {
                printf("%4u  %-24s flags 0x%08x  val %llu%s\n",
                       pr->prop_id, pr->name, pr->flags,
                       (unsigned long long)p->prop_values[k],
                       (pr->flags & DRM_MODE_PROP_ATOMIC) ? "  [ATOMIC]" : "");
                drmModeFreeProperty(pr);
            }
        }
        drmModeFreeObjectProperties(p);
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "crtc-off") == 0) {
        unsigned crtc = find_crtc(fd, conn);
        unsigned long long mode;
        FILE *f;
        if (!crtc) {
            fprintf(stderr, "drmbl: connector %u 没绑 CRTC\n", conn);
            close(fd);
            return 1;
        }
        /* ★ 先把 MODE_ID 记下来 —— 亮屏时必须写回去，否则 ACTIVE=1 也点不亮。
         *   只保存一次：重复调用不能把 0 覆盖进去。 */
        mode = get_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
        if (mode) {
            f = fopen(SAVED_CRTC, "r");
            if (f) {
                unsigned long long old = 0;
                if (fscanf(f, "%llu", &old) == 1 && old)
                    mode = old;            /* 已有记录，保持原值 */
                fclose(f);
            }
            f = fopen(SAVED_CRTC, "w");
            if (f) {
                fprintf(f, "%llu\n", mode);
                fclose(f);
            }
        }
        if (set_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 0) != 0) {
            close(fd);
            return 1;
        }
        printf("crtc%u ACTIVE=0（MODE_ID %llu 存于 %s）\n", crtc, mode, SAVED_CRTC);
        close(fd);
        return 0;
    }

    if (strcmp(cmd, "crtc-on") == 0) {
        unsigned crtc = find_crtc(fd, conn);
        unsigned long long mode = 0;
        uint32_t blob = 0;
        drmModeConnector *c = NULL;
        FILE *f;
        if (!crtc) {
            fprintf(stderr, "drmbl: connector %u 没绑 CRTC\n", conn);
            close(fd);
            return 1;
        }
        /* ★★★★ 必须**现做一个** MODE_ID blob，不能用缓存/读回的旧 id ★★★★
         *
         * 实测（2026-10-13）：
         *     drmbl: 写 MODE_ID=314 失败: Invalid argument
         *     crtc200 ACTIVE=1 MODE_ID=314（已生效）
         * 即 ACTIVE 写成功了，但 MODE_ID 没写进去 —— CRTC 在**没有有效 mode**
         * 的情况下被激活，结果就是**只亮半边**（这条错误以前被淹没在
         * "ACTIVE 已生效"的乐观输出里，极难发现）。
         *
         * 根因：DRM 的 property blob 是**随创建它的 fd 一起失效**的。KWin 建了
         * blob 314，它销毁/重启后那个 id 就成了悬空引用，再写回去内核判 EINVAL。
         *
         * ⇒ 所以这里用 connector 的**首选模式**现建一个 blob，保证一定有效。
         *   首选模式就是面板的 3200x2000@144（drmModeGetConnector 的
         *   DRM_MODE_TYPE_PREFERRED），和 KWin/安卓用的是同一个。
         */
        c = drmModeGetConnector(fd, conn);
        if (c) {
            unsigned k;
            drmModeModeInfo *mi = NULL;
            for (k = 0; k < (unsigned)c->count_modes; k++) {
                if (c->modes[k].type & DRM_MODE_TYPE_PREFERRED) {
                    mi = &c->modes[k];
                    break;
                }
            }
            if (!mi && c->count_modes)
                mi = &c->modes[0];
            if (mi) {
                if (drmModeCreatePropertyBlob(fd, mi, sizeof *mi, &blob) != 0) {
                    fprintf(stderr, "drmbl: 创建 MODE_ID blob 失败: %s\n",
                            strerror(errno));
                    blob = 0;
                } else if (verbose) {
                    fprintf(stderr, "drmbl: 新建 MODE_ID blob=%u（%ux%u@%u）\n",
                            blob, mi->hdisplay, mi->vdisplay, mi->vrefresh);
                }
            }
        }
        if (!blob) {
            /* 退路：用记录下来的旧 id（可能已失效，但聊胜于无） */
            f = fopen(SAVED_CRTC, "r");
            if (f) {
                if (fscanf(f, "%llu", &mode) != 1)
                    mode = 0;
                fclose(f);
            }
            if (!mode)
                mode = get_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            blob = (uint32_t)mode;
        }
        /* ★ 顺序要紧：先 MODE_ID 再 ACTIVE=1。
         *   反过来的话内核会先激活一个没有模式的 CRTC，直接 EINVAL。 */
        if (blob && set_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC,
                               "MODE_ID", blob) != 0) {
            fprintf(stderr, "drmbl: 写 MODE_ID=%u 失败 —— CRTC 会"
                    "在没有有效模式的情况下激活（症状：只亮半边）\n", blob);
        }
        if (set_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 1) != 0) {
            if (c) drmModeFreeConnector(c);
            close(fd);
            return 1;
        }
        {
            unsigned long long a =
                get_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE");
            unsigned long long m =
                get_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            printf("crtc%u ACTIVE=%llu MODE_ID=%llu（blob %u，%s）\n",
                   crtc, a, m, blob,
                   (a == 1 && m == blob) ? "已生效" :
                   (a == 1 ? "★ ACTIVE 生效但 MODE_ID 没写进去 ⇒ 可能只亮半边"
                           : "★ 未生效"));
            if (c) drmModeFreeConnector(c);
            close(fd);
            return (a == 1 && m == blob) ? 0 : 1;
        }
    }

    if (strcmp(cmd, "crtcprop") == 0) {
        unsigned crtc = find_crtc(fd, conn);
        unsigned long long v;
        if (argc < 4)
            usage();
        if (!crtc) {
            fprintf(stderr, "drmbl: connector %u 没绑 CRTC\n", conn);
            close(fd);
            return 1;
        }
        v = strtoull(argv[3], NULL, 0);
        if (set_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, argv[2], v) != 0) {
            close(fd);
            return 1;
        }
        printf("crtc%u %s=%llu\n", crtc, argv[2],
               get_prop_t(fd, crtc, DRM_MODE_OBJECT_CRTC, argv[2]));
        close(fd);
        return 0;
    }

    /* ★★★★ 平面转储：查「左半屏黑」时对比健康/坏掉两种状态 ★★★★
     *
     * 只打印挂在 CRTC 上的、或者我们关心的那几条（有 FB 的）平面，
     * 每条列出 CRTC_ID / FB_ID / CRTC_X,Y,W,H / SRC_X,Y,W,H / zpos。
     * 用法：drmbl planes [all]     （all = 连没启用的也打）
     */
    if (strcmp(cmd, "planes") == 0) {
        int all = (argc >= 3 && strcmp(argv[2], "all") == 0);
        drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
        unsigned i;
        if (!pr) {
            fprintf(stderr, "drmbl: 取平面列表失败: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        printf("共 %u 条平面%s\n", pr->count_planes, all ? "" : "（只列已启用）");
        for (i = 0; i < pr->count_planes; i++) {
            drmModePlane *pl = drmModeGetPlane(fd, pr->planes[i]);
            drmModeObjectProperties *pp;
            unsigned k;
            unsigned long long crtc_id = 0, fb_id = pl ? pl->fb_id : 0;
            unsigned long long cx = 0, cy = 0, cw = 0, ch = 0;
            unsigned long long sx = 0, sy = 0, sw = 0, sh = 0, zp = 0;
            if (!pl)
                continue;
            pp = drmModeObjectGetProperties(fd, pl->plane_id,
                                            DRM_MODE_OBJECT_PLANE);
            if (pp) {
                for (k = 0; k < pp->count_props; k++) {
                    drmModePropertyPtr p2 = drmModeGetProperty(fd, pp->props[k]);
                    if (!p2)
                        continue;
                    if (!strcmp(p2->name, "CRTC_ID")) crtc_id = pp->prop_values[k];
                    else if (!strcmp(p2->name, "FB_ID")) fb_id = pp->prop_values[k];
                    else if (!strcmp(p2->name, "CRTC_X")) cx = pp->prop_values[k];
                    else if (!strcmp(p2->name, "CRTC_Y")) cy = pp->prop_values[k];
                    else if (!strcmp(p2->name, "CRTC_W")) cw = pp->prop_values[k];
                    else if (!strcmp(p2->name, "CRTC_H")) ch = pp->prop_values[k];
                    else if (!strcmp(p2->name, "SRC_X")) sx = pp->prop_values[k];
                    else if (!strcmp(p2->name, "SRC_Y")) sy = pp->prop_values[k];
                    else if (!strcmp(p2->name, "SRC_W")) sw = pp->prop_values[k];
                    else if (!strcmp(p2->name, "SRC_H")) sh = pp->prop_values[k];
                    else if (!strcmp(p2->name, "zpos")) zp = pp->prop_values[k];
                    drmModeFreeProperty(p2);
                }
                drmModeFreeObjectProperties(pp);
            }
            if (all || (crtc_id && fb_id)) {
                printf("  plane %-4u crtc=%-4llu fb=%-4llu "
                       "dst=%llu,%llu %llux%llu  src=%llu,%llu %llux%llu  z=%llu\n",
                       pl->plane_id, crtc_id, fb_id,
                       cx, cy, cw, ch, sx >> 16, sy >> 16, sw >> 16, sh >> 16, zp);
            }
            drmModeFreePlane(pl);
        }
        drmModeFreePlaneResources(pr);
        close(fd);
        return 0;
    }

    usage();
    return 2;
}

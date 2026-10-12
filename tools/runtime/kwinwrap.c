/* kwinwrap — ptrace supervisor that logs every DRM_IOCTL_MODE_ATOMIC issued
 * by a child process tree (and eventually can rewrite them).
 *
 * usage: kwinwrap --out LOG [--] prog args...
 * run as root; child drops uid/gid via env KWINWRAP_UID/KWINWRAP_GID.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <time.h>
#include <sys/ptrace.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <poll.h>
#include <linux/elf.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/syscall.h>
#include <linux/major.h>
#include <asm-generic/statfs.h>
#include <stdint.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>

static long long nsnow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

struct ptregs { unsigned long long regs[31]; unsigned long long sp, pc, pstate; };

static FILE *LOG;
static int DRMFD = -1;
static int RELAYFD = -1;   /* dup of the lease fd — kwin's FB/blob namespace */
static int LEASE = 0;      /* KWINWRAP_LEASE=1 to enable (default OFF:
                            * v6.6 drm_lease_held() returns true for non-master
                            * files, so kwin's auth=0 side-file sees through
                            * the lease; blobs there then miss on the lease
                            * relay fd. GetResources rewriting replaced it.) */
static char propnames[512][16];

/* ══ split 几何（双 DSI 面板的左右半屏）═══════════════════════════════════
 * ★ 这些原来是编译期 #define，写死的是 piano（小米平板 8 Pro）的值：
 *     SPLIT_CRTC 200 / SPLIT_CONN 67 / SPLIT_W 1600 / SPLIT_H 2000
 *   换到任何别的设备上它们全错，而且**不会报错** —— 只会往错误的对象上写，
 *   现象是"kwin 起来了、也有 master、就是花屏或不出画"，极难定位。
 *
 *   现在：优先运行时发现（init_split），结果可被 KWINWRAP_SPLIT_* 覆盖；
 *   发现失败时**大声告警**而不是静默用错值。
 *   `kwinwrap --probe-split` 可把结果打印成 shell 可 eval 的形式。
 *
 * ⚠️ PLANES 是唯一无法可靠自动发现的一项：需要两个"能驱动该 CRTC 且属于
 *    同一 SSPP 组"的 plane，纯靠 possible_crtcs 枚举可能挑错。
 *    上新设备请用 --probe-split 的候选列表配合 display/drm-diag-once.sh
 *    的输出人工确认，然后用 KWINWRAP_SPLIT_PLANES 固定。
 *
 * 声明放在这里（而不是下面的大段注释处），是因为 keep_prop / init_keep /
 * probe_split 都比它早出现。
 */
/* ★★ 分屏改成 N 段（N = SPLIT_NSEG）。
 *
 * 为什么不是 2 段 —— 本机面板 conn67 的 topology_name = 13 =
 * **sde_quadpipe_dscmerge**（IMMUTABLE，驱动按面板能力定），
 * 即"四管 + DSC 合并"。Android 侧实测（容器里 kmsdump 读，不需要 master）
 * 它在 CRTC 200 上同时挂 **4 个 Primary 平面**，每个 CRTC_W=800。
 *
 * ★ 注意 kmsdump 读到的是**驱动归一化之后**的值：驱动会把全局 CRTC_X 里
 *   ≥1600 的那些减掉 1600（见下面 _sde_crtc_check_plane_layout），
 *   所以读回来才显示成"链路内"的 0/800：
 *
 *     PLANE 131   提交 CRTC_X=0     读回 0     SRC_X=0
 *     PLANE 127   提交 CRTC_X=800   读回 800   SRC_X=800
 *     PLANE 123   提交 CRTC_X=1600  读回 0     SRC_X=1600
 *     PLANE 92    提交 CRTC_X=2400  读回 800   SRC_X=2400
 *
 * 也就是双 DSI **每条链路 2 管**；提交时给的是整块 3200 面板的全局坐标，
 * 由驱动自己拆成两条链路的本地 0/800。源坐标就是整幅帧缓冲上的真实列。
 *
 * 之前实现用 2 个 Overlay 平面各 1600 宽 —— 四管里两管拿不到数据，
 * 屏幕就是细密交织噪声（实测照片：满屏横条纹 + 彩虹色偏，无任何图形）。
 *
 * 几何规则（对任意 N 段、段宽 SPLIT_W 通用）：
 *     SRC_X  = i * SPLIT_W           源：整幅图里的第 i 段
 *     CRTC_X = i * SPLIT_W           目的：**整屏全局、单调递增**
 * N = 2 时正好退化成旧行为，所以老设备配置不用改。
 *
 * ★ 目的坐标为什么**必须**是整屏全局的单调值（2026-10-12 定论）：
 *   拿到厂商驱动源码后彻底搞清了。SM8650/pineapple 的 SDE 在
 *   quadpipe 拓扑下有一条硬规则 —— `_sde_crtc_check_plane_layout()`
 *   （sde_crtc.c，设备日志行号 6221，与本机 dmesg 完全对上）：
 *
 *       if (!sde_rm_topology_is_group(rm, crtc_state, QUADPIPE))
 *           return 0;                                 // 非四管拓扑直接跳过
 *       sde_crtc_get_resolution(crtc, crtc_state, mode, &crtc_width, ...);
 *                                     // = mode->hdisplay = 3200，**整块面板**
 *       layout_split = crtc_width >> 1;               // 1600
 *       if (plane_state->crtc_x >= layout_split) {    // ★ 入口是全局坐标
 *           plane_state->crtc_x -= layout_split;      // 驱动自己减 1600
 *           pstate->layout_offset = layout_split;
 *           pstate->layout = SDE_LAYOUT_RIGHT;
 *       } else {
 *           pstate->layout_offset = -1;
 *           pstate->layout = SDE_LAYOUT_LEFT;
 *       }
 *       if (CHECK_LAYER_BOUNDS(plane_state->crtc_x, plane_state->crtc_w,
 *                              layout_split))        // 减完必须落 0~1600
 *           return -E2BIG;
 *
 *   然后 `_sde_crtc_blend_setup_mixer()` 用 layout 选 LM 组：
 *       if (pstate->layout <= SDE_LAYOUT_LEFT) layout_idx = 0;  // LM0/LM1
 *       else                                   layout_idx = 1;  // LM2/LM3
 *   sde_plane.h 的 enum sde_layout 注释也直说 "LEFT: staged on left two LMs /
 *   RIGHT: staged on right two LMs"；最后 `_sde_crtc_blend_setup()` 按
 *   lm_layout = mixer_idx / MAX_MIXERS_PER_LAYOUT 把 stage_cfg[0] 发给
 *   LM0/LM1、stage_cfg[1] 发给 LM2/LM3。
 *
 *   ⇒ 给链路内的 (0,800,0,800) 会让 4 条平面**全部 < 1600** ⇒ 全部判成
 *     SDE_LAYOUT_LEFT ⇒ 全塞进 LM0/LM1 ⇒ 只有 DSI0 有图层，LM2/LM3
 *     （右半屏）永远空着 ⇒ **右半屏全黑**。用户报的正是这个。
 *   ⇒ 给整屏全局的 (0,800,1600,2400)：减完 1600 后是 (0,800,0,800)，
 *     131/127 判 LEFT、123/92 判 RIGHT ⇒ 左右各两条 ⇒ 两块 LM 组都有图层。
 *
 *   ⚠️ 曾经记的"1600~3200 超出单条 DSI 链路本地地址范围、跑 20s 会 panic"
 *      是**误判**：kmsdump 读到的 0/800/0/800 是驱动**减完之后**的值
 *      （get 取的就是 plane_state->crtc_x），把它当"安卓提交的原样"反推，
 *      因果正好搞反。安卓提交的就是全局坐标，驱动减完才变成 0/800。
 *      驱动自己的 evtlog 也证实了这点：安卓 4 条 logo 平面的 layout_idx
 *      是 1,1,0,0（按源段 3,2 → RIGHT），而 src/dst 与我们完全一致。
 *
 * ⚠️ 平面顺序必须与 SRC_X 递增一致：数组下标 i 同时决定 SRC_X=i*W，
 *    所以 SPLIT_PLANE[] 要按源列从左到右排。 */
#define SPLIT_MAX_SEG 4
static unsigned SPLIT_PLANE[SPLIT_MAX_SEG] = { 131u, 127u, 123u, 92u };
static int      SPLIT_NSEG        = 4;
static unsigned SPLIT_CRTC        = 200u;
static unsigned SPLIT_CONN        = 67u;
static unsigned SPLIT_W           = 800u;
static unsigned SPLIT_H           = 2000u;
static unsigned SPLIT_W_FULL      = 3200u;  /* 面板整宽（发现时从 mode 读） */
static int SPLIT_DISCOVERED;               /* 1 = 运行时发现成功 */
/* 目的坐标方案：
 *   0 = ✔**唯一正确**：单调 i*SPLIT_W（0,800,1600,2400）—— 整块面板的全局坐标
 *   1 = ✘禁用：链路内地址 (i%2)*SPLIT_W（0,800,0,800）
 * 为什么 1 是错的：见文件头"目的坐标"那段 —— 驱动靠 crtc_x >= 1600 判
 * SDE_LAYOUT_RIGHT（右半屏那对 LM）。给链路内坐标会让 4 条平面全判 LEFT，
 * 全挤进 LM0/LM1，右半屏（LM2/LM3 → DSI1）永远拿不到图层 ⇒ 右半屏全黑。
 * 这个开关留着只为了能做 A/B 对照复现症状，正式配置必须是 0。 */
static int SPLIT_DST_INTERLEAVE;

/* ★★ zpos 分组模式（KWINWRAP_SPLIT_ZPOS）—— 决定 SDE 的 **stage** 归属。
 *
 * 背景（2026-10-12 定论，依据厂商驱动源码 + 设备 evtlog）：
 *   SDE 的 `_sde_crtc_check_zpos()` 把 **zpos 属性值**换算成 stage：
 *       pstate->stage = zpos + SDE_STAGE_0        （SDE_STAGE_0 == 1）
 *   并强制 **每个 (stage, layout) 最多 2 条平面**，超了直接 -EINVAL。
 *   layout 也参与分组 —— 它由 `_sde_crtc_check_plane_layout()` 按
 *   "整屏全局 CRTC_X 是否 ≥ 面板半宽(1600)"判定（见文件头）。
 *
 *   `_sde_crtc_validate_src_split_order()` 只校验**同一 stage 且同一 layout**
 *   的相邻平面：按 CRTC_X 排序后配对，要求 right.x == left.x + left.w。
 *
 *   0 = 不动 zpos（由 DRM core 的 normalized_zpos 决定）
 *   1 = 每 2 段一个 zpos：s/2（131,127 → 0；123,92 → 1）
 *       实测（2026-10-12）：能过校验、面板**出画面**，但那时 dst 还是
 *       链路内坐标 ⇒ 4 条平面全判 LEFT ⇒ 全挤进 LM0/LM1 ⇒
 *       现象"只有左半屏、右半内容跑到左边、右半不亮"。
 *   2 = 每段一个 zpos：s（0,1,2,3）
 *   3 = **全部 0** —— 与安卓 logo 图层**完全同形**：4 条同 stage，
 *       按 layout 分成 LEFT{131,127} 与 RIGHT{123,92} 两组，
 *       组内 CRTC_X 减完 1600 后是 0/800，"左<右" ⇒ 校验通过；
 *       同时会触发 SDE 的 source-split 配对（131↔127、123↔92）。
 *       旧记录说这个组合会 panic，但那是在"链路内坐标"的误判下做的，
 *       归因不可信；若模式 5 不成，这是第一顺位的对照实验。
 *   4 = 反转配对：zv = (NSEG-1-s)/2
 *   5 = **当前采用**：zv = NSEG-1-s（NSEG=4 → {131,127,123,92} = 3,2,1,0）
 *       4 条各占一个 stage ⇒ 没有任何"同 stage 同 layout"的相邻对 ⇒
 *       不做 source-split 配对，每条 SSPP 都是单 LM 取数。
 *       这与"已经证明能正确出左半屏"的形态只差 dst 一个变量，改动面最小。
 *
 *   ── 安卓现场基准的正确读法（2026-10-12 修正）──
 *   debug/dump 里 _sde_crtc_blend_setup_mixer 第二条 EVT32 的字段是
 *   （对应 sde_crtc.c:1977）：
 *       crtc, plane, stage_idx, sspp, stage, multirect_index,
 *       multirect_mode, format, modifier, layout_idx
 *   安卓 4 条 logo 平面解出来：
 *       plane 92  sspp=VIG0 stage=1 stage_idx=0 layout=1
 *       plane 123 sspp=VIG1 stage=1 stage_idx=1 layout=1
 *       plane 127 sspp=VIG2 stage=1 stage_idx=0 layout=0
 *       plane 131 sspp=VIG3 stage=1 stage_idx=1 layout=0
 *   ⇒ **stage 全是 1**（raw zpos 全是 0），而之前当成"stage 顺序"的
 *     0/1/2/3 其实是 **stage_idx**（同 stage 内的第几条，按 plane id 发号）。
 *   ⇒ 同时证实 layout_idx 才是左右半屏的开关：123/92 → RIGHT(LM2/LM3)、
 *     131/127 → LEFT(LM0/LM1)，与 src 段号 0/1 vs 2/3 完全对应。 */
static int SPLIT_ZPOS_MODE;
/* 逐帧调试痕迹总开关。默认关：FBSCAN / DROP-CAND / NOACTIVE / EVDROP /
 * BUILT 这些每帧都会打，正常运行时会把 kwinatomic.log 撑到几十 MB。
 * 真机上没法接调试器，所以不删掉，改成 KWINWRAP_TRACE=1 按需打开。 */
static int TRACE;

static unsigned split_dst_x(int i) {
    return SPLIT_DST_INTERLEAVE ? (unsigned)(i % 2) * SPLIT_W
                                : (unsigned)i * SPLIT_W;
}

static int is_split_plane(unsigned id) {
    for (int i = 0; i < SPLIT_NSEG; i++)
        if (SPLIT_PLANE[i] == id) return 1;
    return 0;
}
static int split_seg_index(unsigned id) {
    for (int i = 0; i < SPLIT_NSEG; i++)
        if (SPLIT_PLANE[i] == id) return i;
    return -1;
}

static void init_split(void);


static const char *pname(unsigned id) {
    if (id >= 512) return "?";
    if (propnames[id][0]) return propnames[id];
    if (DRMFD >= 0) {
        drmModePropertyRes *p = drmModeGetProperty(DRMFD, id);
        if (p) { snprintf(propnames[id], 16, "%s", p->name); drmModeFreeProperty(p);
                 return propnames[id]; }
    }
    snprintf(propnames[id], 16, "prop%u", id);
    return propnames[id];
}

static int getregs(pid_t t, struct ptregs *r) {
    struct iovec io = { .iov_base = r, .iov_len = sizeof *r };
    return ptrace(PTRACE_GETREGSET, t, (void *)NT_PRSTATUS, &io) ? -1 : 0;
}

static __u32 find_prop(unsigned obj, uint32_t obj_type, const char *name) {
    drmModeObjectProperties *p =
        drmModeObjectGetProperties(DRMFD, obj, obj_type);
    if (!p) return 0;
    __u32 id = 0;
    for (uint32_t i = 0; i < p->count_props && !id; i++) {
        drmModePropertyRes *q = drmModeGetProperty(DRMFD, p->props[i]);
        if (q) {
            if (!strcmp(q->name, name)) id = q->prop_id;
            drmModeFreeProperty(q);
        }
    }
    drmModeFreeObjectProperties(p);
    return id;
}

static ssize_t readmem(pid_t t, unsigned long long addr, void *buf, size_t n) {
    /* AT_SECURE tracees (capability binaries) are non-dumpable, so
     * process_vm_readv / /proc/pid/mem fail with EPERM; PEEKDATA through the
     * existing ptrace link still works. */
    unsigned char *dst = buf;
    size_t orig_n = n;
    unsigned long long a = addr & ~7ULL;
    long first = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
    if (first == -1 && errno) return -1;
    unsigned char *src = (unsigned char *)&first + (addr - a);
    size_t head = 8 - (size_t)(addr - a);
    if (head > n) head = n;
    memcpy(dst, src, head);
    dst += head; a += 8; n -= head;
    while (n) {
        long w = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
        if (w == -1 && errno) return -1;
        size_t chunk = n < 8 ? n : 8;
        memcpy(dst, &w, chunk);
        dst += chunk; a += 8; n -= chunk;
    }
    return (ssize_t)orig_n;
}

static void dump_commit(pid_t t, unsigned long long uptr) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) {
        fprintf(LOG, "ATOMIC: readmem struct failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    __u32 cnts[64], objs[64];
    __u32 nobj = a.count_objs > 64 ? 64 : a.count_objs;
    if (readmem(t, a.objs_ptr, objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, cnts, nobj * 4) < 0) {
        fprintf(LOG, "ATOMIC: readmem arrays failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    unsigned total = 0;
    for (__u32 i = 0; i < nobj; i++) total += cnts[i];
    if (total > 2048) total = 2048;
    static __u32 props[2048];
    static __u64 vals[2048];
    if (readmem(t, a.props_ptr, props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, vals, total * 8) < 0) {
        fprintf(LOG, "ATOMIC: readmem props failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    fprintf(LOG, "=== ATOMIC tid=%d nobjs=%u flags=0x%x%s ===\n",
            t, a.count_objs, a.flags,
            (a.flags & DRM_MODE_ATOMIC_TEST_ONLY) ? " TEST_ONLY" : "");
    unsigned off = 0;
    for (__u32 o = 0; o < nobj; o++) {
        fprintf(LOG, "  obj=%u n=%u\n", objs[o], cnts[o]);
        for (__u32 i = 0; i < cnts[o] && off + i < 2048; i++)
            fprintf(LOG, "    %-18s = 0x%llx\n",
                    pname(props[off + i]), (unsigned long long)vals[off + i]);
        off += cnts[o];
    }
    fflush(LOG);
}

struct phase { pid_t t; int p; int sub; unsigned long long nr;
               long long hret; long long e_ns; char path[96]; };

static int setregs(pid_t t, struct ptregs *r) {
    struct iovec io = { .iov_base = r, .iov_len = sizeof *r };
    return ptrace(PTRACE_SETREGSET, t, (void *)NT_PRSTATUS, &io) ? -1 : 0;
}

#define NR_IOCTL   29
#define NR_OPENAT  56

/* ---- targeted interception (KWINWRAP_SECCOMP=1) ------------------------
 * Plain PTRACE_SYSCALL stops the tracee on EVERY syscall of every thread:
 * freedreno GL submits hundreds of ioctls per frame, the tracer saturates a
 * core processing stops, and commit dt/exec balloons to 100+ ms (~9 fps).
 * Installing a seccomp RET_TRACE filter in the child makes it stop only at
 * the four syscalls we actually rewrite/log: ioctl(ATOMIC|GETRESOURCES),
 * openat, openat2.  Tracer then arms the matching exit with one
 * PTRACE_SYSCALL and resumes everything else with PTRACE_CONT. */
static int SECCMODE;
static int nattempt;
#ifndef PTRACE_EVENT_SECCOMP
#define PTRACE_EVENT_SECCOMP 7
#endif

static int install_drm_filter(void) {
    static struct sock_filter f[] = {
        /* 0 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, arch)),
        /* 1 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 0, 10),
        /* 2 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, nr)),
        /* 3 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 29, 2, 0),
        /* 4 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 56, 6, 0),
        /* 5 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 437, 5, 6),
        /* 6 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, args) + 8),
        /* 7 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                         DRM_IOCTL_MODE_ATOMIC, 1, 0),
        /* 8 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                         DRM_IOCTL_MODE_GETRESOURCES, 1, 3),
        /* 9 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x10),
        /*10 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x11),
        /*11 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x12),
        /*12 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog fp = { sizeof f / sizeof f[0], f };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &fp) == 0) return 0;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fp) == 0) return 0;
    return -1;
}
#define DRM_SET_MASTER_REQ 0x4004641EULL
#define DRM_DROP_MASTER_REQ 0xC004641FULL

/* --- fd hijack (Plan C, dup flavor) ---
 * ptraced-context SET_MASTER is policy-denied on this vendor kernel, so root
 * kwinwrap acquires master BEFORE fork. At the ENTRY stop of every
 * openat(*card*), the syscall itself is rewritten to dup(HIJACK_FD): the
 * tracee never touches the card node and receives a fresh, real fd that
 * shares the master file_priv (all close()/fd-number bookkeeping stays
 * natural — return-value rewriting would alias when kwin opens the same
 * node twice, cf. DrmDevice::openWithAuthentication re-opening).
 */
#define HIJACK_FD 250
#define NR_DUP    99
static int HIJACK;
static int MASTERFD = -1;
/* -1 = unknown (probe mode: kwin owns real card fds after our DROP_MASTER),
 *  1 = kwin commits natively (passthrough),  0 = relay through kwinwrap's fd */
static int NATIVE = -1;

static int hijack_entry(pid_t t, struct ptregs *R, const char *path) {
    /* kwin commits atomics on the RENDER node fd (regs[0]==-2 proved it) —
     * render files can never be master -> every commit -13. Redirect card
     * AND render opens onto our master file. */
    if (!strstr(path, "card") && !strstr(path, "render")) return 0;
    struct ptregs d = *R;
    d.regs[8] = NR_DUP;
    d.regs[0] = HIJACK_FD;
    if (setregs(t, &d)) {
        fprintf(LOG, "HIJACK setregs failed (%s)\n", strerror(errno));
        return 0;
    }
    fprintf(LOG, "HIJACK openat(%s) tid=%d -> dup(%d)\n", path, t, HIJACK_FD);
    fflush(LOG);
    return 1;
}

static void log_hijack_result(pid_t t, long long fd) {
    fprintf(LOG, "HIJACK -> fd=%lld %s\n", fd,
            fd < 0 ? strerror((int)-fd) : "OK");
    fflush(LOG);
}

static void log_card_open(pid_t t, long fd, const char *path) {
    if (!strstr(path, "card") && !strstr(path, "render")) return;
    fprintf(LOG, "openat tid=%d fd=%ld %s\n", t, fd,
            path[0] ? path : "(unreadable)");
    fflush(LOG);
}

static void peekstr(pid_t t, unsigned long long addr, char *out, size_t max) {
    size_t i = 0;
    long w = 0;
    unsigned long long cur = ~0ULL;
    while (i + 1 < max) {
        unsigned long long a = addr + i;
        if ((a & ~7ULL) != cur) {
            errno = 0;
            w = ptrace(PTRACE_PEEKDATA, t, (void *)(a & ~7ULL), NULL);
            if (w == -1 && errno) break;
            cur = a & ~7ULL;
        }
        unsigned char c = ((unsigned char *)&w)[a & 7];
        out[i++] = (char)c;
        if (!c) { out[i - 1] = 0; return; }
    }
    out[i] = 0;
}

static struct phase phases[512];
static int nphase;

/* Signal-stop merges (a pending signal reported at a syscall boundary) can
 * flip a p-toggle parity, after which "entry" handlers run on exit stops and
 * vice versa — dmesg proved kwin's original ioctls still executed despite
 * the x8=-1 skip. Ask the kernel for the true direction instead. */
#ifndef PTRACE_GET_SYSCALL_INFO
#define PTRACE_GET_SYSCALL_INFO 0x4209
#endif
struct ksyscall_info {
    unsigned char op; unsigned char pad[3]; unsigned int arch;
    unsigned long long ip, sp;
    union {
        struct { unsigned long long nr, args[6]; } entry;
        struct { long long ret; unsigned long long flags, data1, data2; } exit_;
    };
};
/* returns 1=entry, 2=exit, 0=unknown */
static int syscall_dir(pid_t t) {
    struct ksyscall_info si;
    errno = 0;
    long n = ptrace(PTRACE_GET_SYSCALL_INFO, t, (long)sizeof si, &si);
    if (n <= 0 || si.op == 0 || si.op > 3) return 0;
    return si.op;   /* PTRACE_SYSCALL_INFO_ENTRY=1 EXIT=2 */
}

/* ---- rewrite mode: strip kwin's phantom outputs, keep only real panel ---- */
static int FILTER;
/* ★ 原默认值是 { 67, 206, 97 }（piano 的 conn/crtc/virtual-plane）。
 *   现在留空，由 init_keep() 在 init_split() 之后用**发现出来的**值填。 */
static unsigned KEEP_OBJS[8];
static int NKEEP;

static void init_keep(void) {
    char *e = getenv("KWINWRAP_KEEP");
    int n = 0;
    if (e) {
        for (char *s = strtok(e, ","); s && n < 8; s = strtok(NULL, ","))
            KEEP_OBJS[n++] = (unsigned)strtoul(s, NULL, 0);
    }
    if (!n) {
        /* 默认保留：真面板 connector + 它的 crtc + kwin 会挑的那个 plane */
        KEEP_OBJS[n++] = SPLIT_CONN;
        KEEP_OBJS[n++] = SPLIT_CRTC;
        KEEP_OBJS[n++] = SPLIT_PLANE[0];
    }
    NKEEP = n;
}

static int keep_obj(unsigned id) {
    for (int i = 0; i < NKEEP; i++)
        if (KEEP_OBJS[i] == id) return 1;
    return 0;
}

static int keep_prop(unsigned obj, const char *name) {
    /* ★ 原来这里写死 67 / 206（piano 的 connector 与 crtc id）。
     *   换设备后这两个分支永远不命中，属性过滤行为静默改变。 */
    if (obj == SPLIT_CONN) return !strcmp(name, "CRTC_ID");   /* link-status kills it */
    if (obj == SPLIT_CRTC) return !strcmp(name, "MODE_ID") || !strcmp(name, "ACTIVE");
    return 1;  /* plane: pass through */
}

/* ---- 运行时 split 几何发现 ----------------------------------------------
 * 必须在 DRMFD 打开之后、HIJACK 块之前调用。
 *
 * 发现顺序：
 *   1. 环境变量 KWINWRAP_SPLIT_* （最高优先级，设备适配层用 --probe-split 固化）
 *   2. 从 DRM 现读：
 *        CONN   = 已连接、有 modes、且非 VIRTUAL/WRITEBACK 的 connector
 *        CRTC   = 该 connector 当前链到的 crtc；没有就取 encoder 的
 *                 possible_crtcs 里最低位对应的 crtc
 *        W/H    = 该 connector 首选 mode 的 hdisplay/vdisplay，
 *                 再按 PLANES 数量等分宽度
 *        PLANES = 能驱动该 CRTC 的 plane，按 id 升序取前两个
 *   3. 都失败 → 保留编译期兜底值，并把 SPLIT_DISCOVERED 留 0，
 *      调用方据此**大声告警**（绝不再静默使用 piano 常量）
 */
static void init_split(void)
{
    const char *e;
    int from_env = 0;

    if ((e = getenv("KWINWRAP_SPLIT_CONN")))  { SPLIT_CONN = (unsigned)strtoul(e, NULL, 0); from_env = 1; }
    if ((e = getenv("KWINWRAP_SPLIT_CRTC")))  { SPLIT_CRTC = (unsigned)strtoul(e, NULL, 0); from_env = 1; }
    if ((e = getenv("KWINWRAP_SPLIT_W")))     { SPLIT_W    = (unsigned)strtoul(e, NULL, 0); from_env = 1; }
    if ((e = getenv("KWINWRAP_SPLIT_H")))     { SPLIT_H    = (unsigned)strtoul(e, NULL, 0); from_env = 1; }
    if ((e = getenv("KWINWRAP_SPLIT_W_FULL"))){ SPLIT_W_FULL = (unsigned)strtoul(e, NULL, 0); from_env = 1; }
    if ((e = getenv("KWINWRAP_SPLIT_DST_INTERLEAVE")))
        SPLIT_DST_INTERLEAVE = atoi(e) ? 1 : 0;
    if ((e = getenv("KWINWRAP_SPLIT_ZPOS")))
        SPLIT_ZPOS_MODE = atoi(e);
    if ((e = getenv("KWINWRAP_SPLIT_PLANES"))) {
        /* 接受任意段数（1..SPLIT_MAX_SEG）的逗号列表，按**源列从左到右**排列。
         * 旧的 "L,R" 两段写法自然兼容：N=2 时几何退化成 0/1600 与 0/1600。 */
        unsigned v[SPLIT_MAX_SEG]; int n = 0;
        for (char *s = strtok((char *)e, ","); s && n < SPLIT_MAX_SEG;
             s = strtok(NULL, ","))
            v[n++] = (unsigned)strtoul(s, NULL, 0);
        if (n >= 1) {
            for (int i = 0; i < n; i++) SPLIT_PLANE[i] = v[i];
            SPLIT_NSEG = n;
            from_env = 1;
        }
    }
    /* ★ 段宽永远由"整宽 / 段数"决定，**不要**用环境变量里那个可能过期的值。
     *   实测踩过：设备层只把平面列表覆盖成 2 个（想要 2×1600），但
     *   KWINWRAP_SPLIT_W 仍是探针按 4 段算出的 800 —— 结果两个平面各 800
     *   只盖住面板左半 1600，右半全黑。 */
    if (SPLIT_W_FULL && SPLIT_NSEG > 0)
        SPLIT_W = SPLIT_W_FULL / (unsigned)SPLIT_NSEG;

    if (from_env) {
        SPLIT_DISCOVERED = 1;
        fprintf(LOG, "split: 来自环境变量 conn=%u crtc=%u planes=", SPLIT_CONN,
                SPLIT_CRTC);
        for (int i = 0; i < SPLIT_NSEG; i++)
            fprintf(LOG, "%s%u", i ? "," : "", SPLIT_PLANE[i]);
        fprintf(LOG, " (%d 段) %ux%u\n", SPLIT_NSEG, SPLIT_W, SPLIT_H);
    }

    if (DRMFD < 0) return;

    drmModeRes *res = drmModeGetResources(DRMFD);
    if (!res) { fprintf(LOG, "split: GetResources 失败，保留兜底值\n"); return; }

    /* ── connector ── */
    if (!(e = getenv("KWINWRAP_SPLIT_CONN"))) {
        unsigned best = 0, best_modes = 0;
        for (int i = 0; i < res->count_connectors; i++) {
            drmModeConnector *c = drmModeGetConnector(DRMFD, res->connectors[i]);
            if (!c) continue;
            int virt = (c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
                        c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK);
            if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0 && !virt &&
                c->count_modes > best_modes) {
                best = c->connector_id;
                best_modes = c->count_modes;
            }
            drmModeFreeConnector(c);
        }
        if (best) {
            SPLIT_CONN = best;
            SPLIT_DISCOVERED = 1;
            fprintf(LOG, "split: 发现 connector %u (%u modes)\n", best, best_modes);
        }
    }

    /* ── crtc + 面板尺寸 ── */
    drmModeConnector *c = drmModeGetConnector(DRMFD, SPLIT_CONN);
    if (!c) {
        fprintf(LOG, "split: connector %u 打不开\n", SPLIT_CONN);
        drmModeFreeResources(res);
        return;
    }
    if (!(e = getenv("KWINWRAP_SPLIT_CRTC"))) {
        unsigned crtc = 0;
        /* drmModeConnector 只有 encoder_id；当前链着的 crtc 在 encoder 上。 */
        if (c->encoder_id) {
            drmModeEncoder *enc = drmModeGetEncoder(DRMFD, c->encoder_id);
            if (enc) {
                crtc = enc->crtc_id;
                if (!crtc)
                    for (int b = 0; b < 32 && !crtc; b++)
                        if (enc->possible_crtcs & (1u << b)) crtc = res->crtcs[b];
                drmModeFreeEncoder(enc);
            }
        }
        if (crtc) {
            SPLIT_CRTC = crtc;
            SPLIT_DISCOVERED = 1;
            fprintf(LOG, "split: 发现 crtc %u\n", crtc);
        } else {
            fprintf(LOG, "split: connector %u 没链到 crtc，也没 encoder\n", SPLIT_CONN);
        }
    }
    if (c->count_modes > 0) {
        SPLIT_W_FULL = c->modes[0].hdisplay;   /* 面板整宽，供后面按段数等分 */
        if (!(e = getenv("KWINWRAP_SPLIT_H"))) SPLIT_H = c->modes[0].vdisplay;
        if (!(e = getenv("KWINWRAP_SPLIT_W"))) {
            /* 段宽先按当前段数算；平面发现后若段数变了会重算（见下） */
            SPLIT_W = SPLIT_W_FULL / (SPLIT_NSEG ? (unsigned)SPLIT_NSEG : 1u);
        }
        SPLIT_DISCOVERED = 1;
        fprintf(LOG, "split: 面板 mode %ux%u → 每段 %ux%u（%d 段）\n",
                c->modes[0].hdisplay, c->modes[0].vdisplay, SPLIT_W, SPLIT_H,
                SPLIT_NSEG);
    }
    drmModeFreeConnector(c);

    /* ── planes ── */
    if (!(e = getenv("KWINWRAP_SPLIT_PLANES"))) {
        drmModePlaneRes *pr = drmModeGetPlaneResources(DRMFD);
        if (pr) {
            unsigned cand[64]; int nc = 0;
            unsigned prim[64]; int nprim = 0;   /* type==Primary 的子集 */
            int crtc_idx = -1;
            for (int i = 0; i < res->count_crtcs; i++)
                if (res->crtcs[i] == SPLIT_CRTC) { crtc_idx = i; break; }
            if (crtc_idx >= 0) {
                for (uint32_t i = 0; i < pr->count_planes && nc < 64; i++) {
                    drmModePlane *p = drmModeGetPlane(DRMFD, pr->planes[i]);
                    if (!p) continue;
                    if (p->possible_crtcs & (1u << crtc_idx)) {
                        cand[nc++] = p->plane_id;
                        /* ★ 只把 type==Primary 的挑出来。
                         *   实测教训：纯按 id 升序挑前两个，在本机挑到的是
                         *   Overlay(DMA) 平面 143/147，而面板要的是
                         *   sde_quadpipe_dscmerge —— 四管必须由 **Primary
                         *   (VIG)** 平面驱动。挑错类型 → 屏幕是交织噪声。 */
                        drmModeObjectPropertiesPtr op = drmModeObjectGetProperties(
                            DRMFD, p->plane_id, DRM_MODE_OBJECT_PLANE);
                        if (op) {
                            for (uint32_t k = 0; k < op->count_props; k++) {
                                drmModePropertyPtr pp = drmModeGetProperty(DRMFD, op->props[k]);
                                if (pp) {
                                    if (!strcmp(pp->name, "type") &&
                                        op->prop_values[k] == DRM_PLANE_TYPE_PRIMARY &&
                                        nprim < 64)
                                        prim[nprim++] = p->plane_id;
                                    drmModeFreeProperty(pp);
                                }
                            }
                            drmModeFreeObjectProperties(op);
                        }
                    }
                    drmModeFreePlane(p);
                }
            }
            /* 按 id 升序，便于跨次运行稳定 */
            for (int i = 0; i < nc; i++)
                for (int j = i + 1; j < nc; j++)
                    if (cand[j] < cand[i]) { unsigned t = cand[i]; cand[i] = cand[j]; cand[j] = t; }
            for (int i = 0; i < nprim; i++)
                for (int j = i + 1; j < nprim; j++)
                    if (prim[j] < prim[i]) { unsigned t = prim[i]; prim[i] = prim[j]; prim[j] = t; }

            fprintf(LOG, "split: 能驱动 crtc%u 的 plane 候选（%d 个）:", SPLIT_CRTC, nc);
            for (int i = 0; i < nc; i++) fprintf(LOG, " %u", cand[i]);
            fprintf(LOG, "\n");
            fprintf(LOG, "split: 其中 Primary(VIG) 平面 %d 个:", nprim);
            for (int i = 0; i < nprim; i++) fprintf(LOG, " %u", prim[i]);
            fprintf(LOG, "\n");

            /* ★ 优先用 Primary：段数取 min(Primary 数, SPLIT_MAX_SEG)。
             *   段宽 = 面板宽 / 段数。取不到 Primary 才退回全部候选。 */
            unsigned *use = nprim >= 2 ? prim : cand;
            int nu = nprim >= 2 ? nprim : nc;
            if (nu >= 2) {
                int nseg = nu > SPLIT_MAX_SEG ? SPLIT_MAX_SEG : nu;
                for (int i = 0; i < nseg; i++) SPLIT_PLANE[i] = use[i];
                SPLIT_NSEG = nseg;
                SPLIT_W = SPLIT_W_FULL / (unsigned)nseg;
                SPLIT_DISCOVERED = 1;
                fprintf(LOG, "split: 选中 %d 段 %s 平面:", nseg,
                        nprim >= 2 ? "Primary(VIG)" : "（无 Primary，退回候选）");
                for (int i = 0; i < nseg; i++)
                    fprintf(LOG, " %u(src_x=%u)", SPLIT_PLANE[i], i * SPLIT_W);
                fprintf(LOG, "  每段 %ux%u —— 请用 --probe-split 核对\n",
                        SPLIT_W, SPLIT_H);
            } else {
                fprintf(LOG, "split: 候选 plane 不足 2 个，保留兜底配置\n");
            }
            drmModeFreePlaneResources(pr);
        }
    }

    drmModeFreeResources(res);

    if (!SPLIT_DISCOVERED) {
        fprintf(LOG,
            "split: ⚠️⚠️ 运行时发现失败，正在使用编译期兜底值 "
            "conn=%u crtc=%u %ux%u —— 请跑 `kwinwrap --probe-split` "
            "并用 KWINWRAP_SPLIT_* 显式指定。\n",
            SPLIT_CONN, SPLIT_CRTC, SPLIT_W, SPLIT_H);
    }
}

/* --probe-split：把发现结果按 shell 可 eval 的格式打印出来。
 * 设备适配层这样用：
 *     eval "$(kwinwrap --probe-split)"
 * 然后 KWINWRAP_SPLIT_* 就固化进环境，下次不必再发现。 */
static int probe_split(void)
{
    if (!LOG) LOG = stderr;   /* 发现过程的日志走 stderr，stdout 留给 eval */
    DRMFD = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (DRMFD < 0) { perror("open /dev/dri/card0"); return 1; }
    /* ★ 必须先设 UNIVERSAL_PLANES，否则看不到 Primary 平面（见 main 里那段） */
    drmSetClientCap(DRMFD, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    drmSetClientCap(DRMFD, DRM_CLIENT_CAP_ATOMIC, 1);
    init_split();
    /* 发现过程写日志，结果写 stdout（两者分开，方便 eval） */
    printf("KWINWRAP_SPLIT_CONN=%u\n", SPLIT_CONN);
    printf("KWINWRAP_SPLIT_CRTC=%u\n", SPLIT_CRTC);
    printf("KWINWRAP_SPLIT_W=%u\n", SPLIT_W);
    printf("KWINWRAP_SPLIT_W_FULL=%u\n", SPLIT_W_FULL);
    printf("KWINWRAP_SPLIT_H=%u\n", SPLIT_H);
    printf("KWINWRAP_SPLIT_PLANES=");
    for (int i = 0; i < SPLIT_NSEG; i++)
        printf("%s%u", i ? "," : "", SPLIT_PLANE[i]);
    printf("\n");
    /* ⚠️ card0 的"首个打开者自动成为 master"规则意味着上面这次 open
     * 可能已经把 master 拿走了。显式 DROP 掉，别让一次探针影响随后
     * 真正的交接时序（关 fd 也会释放，但显式更确定）。 */
    ioctl(DRMFD, DRM_DROP_MASTER_REQ, 0);
    close(DRMFD);
    DRMFD = -1;
    return SPLIT_DISCOVERED ? 0 : 3;
}

static int writeto(pid_t t, unsigned long long addr, const void *buf, size_t n) {
    const unsigned char *src = buf;
    unsigned long long a = addr & ~7ULL;
    size_t pre = (size_t)(addr - a);
    if (pre || n < 8) {
        long w = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
        if (w == -1 && errno) return -1;
        unsigned char *wb = (unsigned char *)&w;
        size_t k = 8 - pre; if (k > n) k = n;
        memcpy(wb + pre, src, k);
        if (ptrace(PTRACE_POKEDATA, t, (void *)a, (void *)w)) return -1;
        src += k; n -= k; a += 8;
    }
    while (n) {
        unsigned char b[8] = {0};
        size_t k = n < 8 ? n : 8;
        memcpy(b, src, k);
        long w;
        memcpy(&w, b, 8);
        if (k < 8) {
            long old = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
            if (old == -1 && errno) return -1;
            memcpy(b + k, (unsigned char *)&old + k, 8 - k);
            memcpy(&w, b, 8);
        }
        if (ptrace(PTRACE_POKEDATA, t, (void *)a, (void *)w)) return -1;
        src += k; n -= k; a += 8;
    }
    return 0;
}

static void filter_commit(pid_t t, unsigned long long uptr,
                          struct ptregs *r) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) return;
    if (a.count_objs > 64) return;
    __u32 objs[64], cnts[64];
    __u32 nobj = a.count_objs;
    if (readmem(t, a.objs_ptr, objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, cnts, nobj * 4) < 0) return;
    unsigned total = 0;
    for (__u32 i = 0; i < nobj; i++) total += cnts[i];
    if (total > 2048) return;
    static __u32 props[2048];
    static __u64 vals[2048];
    if (readmem(t, a.props_ptr, props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, vals, total * 8) < 0) return;

    __u32 nobjs2 = 0, nprops2 = 0;
    __u32 objs2[64], cnts2[64], props2[2048];
    __u64 vals2[2048];
    unsigned off = 0;
    for (__u32 o = 0; o < nobj; o++) {
        unsigned kept = 0;
        if (keep_obj(objs[o])) {
            for (__u32 i = 0; i < cnts[o]; i++)
                if (keep_prop(objs[o], pname(props[off + i]))) {
                    props2[nprops2] = props[off + i];
                    vals2[nprops2]  = vals[off + i];
                    nprops2++; kept++;
                }
        }
        if (kept) { objs2[nobjs2] = objs[o]; cnts2[nobjs2] = kept; nobjs2++; }
        off += cnts[o];
    }
    if (nobjs2 == nobj && nprops2 == total) return;  /* nothing to strip */

    /* scratch: below this thread's stack pointer, 8-byte aligned */
    unsigned long long sp = (r->sp - 0x4000) & ~0xFULL;
    unsigned long long p_objs = sp;
    unsigned long long p_cnts = sp + 64 * 4;
    unsigned long long p_props = sp + 2 * 64 * 4;
    unsigned long long p_vals = sp + 2 * 64 * 4 + 2048 * 4;
    if (writeto(t, p_objs, objs2, nobjs2 * 4) ||
        writeto(t, p_cnts, cnts2, nobjs2 * 4) ||
        writeto(t, p_props, props2, nprops2 * 4) ||
        writeto(t, p_vals, vals2, (size_t)nprops2 * 8)) {
        fprintf(LOG, "FILTER: writeto failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    a.count_objs = nobjs2;
    a.objs_ptr = p_objs;
    a.count_props_ptr = p_cnts;
    a.props_ptr = p_props;
    a.prop_values_ptr = p_vals;
    if (writeto(t, uptr, &a, sizeof a)) {
        fprintf(LOG, "FILTER: poke struct failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    fprintf(LOG, ">>> FILTER: nobjs %u->%u nprops %u->%u\n",
            nobj, nobjs2, total, nprops2);
    for (__u32 o = 0; o < nobjs2; o++) fprintf(LOG, "    kept obj=%u n=%u\n", objs2[o], cnts2[o]);
    fflush(LOG);
}

/* ---- ATOMIC relay -------------------------------------------------------
 * dmesg showed kwin's MODE_ATOMIC ioctls executing with auth=0 — they are
 * not on the hijacked master file (render-node/join fd, cf. Anland kwin +
 * vendor kernel that permits atomic-on-render), hence the -13. So execute
 * the request HERE, in kwinwrap's own untraced root context on
 * DRMFD (same file as the hijacked dups: object/blob/FB namespace shared),
 * and hand the result back to the child by skipping its syscall (x8 = -1
 * at true entry stop -> -ENOSYS at its exit stop, which we overwrite with
 * the relay's raw ret).
 * Sanitize for the context switch: IN_FENCE_FD values are child fd numbers
 * -> rewrite to -1 (kernel treats -1 as "no fence"); user_data
 * (out_fence_ptr) -> 0. When FILTER is on, phantom objects/props are
 * dropped from the LOCAL copy only — the child's memory stays untouched.
 */
static __u32 r_objs[64], r_cnts[64], r_props[2048];
static __u64 r_vals[2048];

static int build_local_atomic(pid_t t, unsigned long long uptr,
                              struct drm_mode_atomic *la) {
    if (readmem(t, uptr, la, sizeof *la) != (ssize_t)sizeof *la) return -1;
    struct drm_mode_atomic src = *la;
    if (src.count_objs > 64) return -1;
    __u32 objs[64], cnts[64];
    if (readmem(t, src.objs_ptr, objs, src.count_objs * 4) < 0 ||
        readmem(t, src.count_props_ptr, cnts, src.count_objs * 4) < 0)
        return -1;
    unsigned total = 0;
    for (__u32 i = 0; i < src.count_objs; i++) total += cnts[i];
    if (total > 2048) return -1;
    __u32 props[2048];
    __u64 vals[2048];
    if (readmem(t, src.props_ptr, props, total * 4) < 0 ||
        readmem(t, src.prop_values_ptr, vals, total * 8) < 0)
        return -1;

    /* Dynamic target: kwin probes the real connector against different crtcs;
     * whatever CRTC this request links it to (T) must itself survive the
     * filter, else the kernel sees "enabled/connectors mismatch" -22.
     * ★ 原版这里写死 67（piano 的 connector id）。 */
    unsigned T = 0;
    int dyn = 0;
    __u64 crtc_of[64];
    int has_mode[64];
    if (FILTER) {
        unsigned o2 = 0;
        for (__u32 o = 0; o < src.count_objs; o++) {
            crtc_of[o] = ~0ULL; has_mode[o] = 0;
            for (__u32 i = 0; i < cnts[o]; i++, o2++) {
                const char *nm = pname(props[o2]);
                if (!strcmp(nm, "CRTC_ID")) crtc_of[o] = vals[o2];
                else if (!strcmp(nm, "MODE_ID")) has_mode[o] = 1;
                else if (!strcmp(nm, "link-status") || !strcmp(nm, "CONNECTORS_ID"))
                    has_mode[o] = 2;   /* connector-ish, never a plane */
            }
        }
        for (__u32 o = 0; o < src.count_objs; o++)
            if (objs[o] == SPLIT_CONN && crtc_of[o] != ~0ULL) { T = (unsigned)crtc_of[o]; dyn = 1; }
    }

    __u32 nobjs2 = 0, nprops2 = 0;
    unsigned off = 0;
    for (__u32 o = 0; o < src.count_objs; o++) {
        int is_conn = objs[o] == SPLIT_CONN;
        int keepobj = !dyn || is_conn || (dyn && T && objs[o] == T) ||
                      (dyn && T && crtc_of[o] == T && !has_mode[o]);
        unsigned kept = 0;
        for (__u32 i = 0; i < cnts[o]; i++, off++) {
            const char *nm = pname(props[off]);
            if (dyn && !keepobj) continue;
            if (dyn && is_conn && strcmp(nm, "CRTC_ID")) continue;
            if (dyn && T && objs[o] == T &&
                strcmp(nm, "MODE_ID") && strcmp(nm, "ACTIVE")) continue;
            r_props[nprops2] = props[off];
            r_vals[nprops2] = !strcmp(nm, "IN_FENCE_FD") ? ~0ULL : vals[off];
            nprops2++; kept++;
        }
        if (kept) { r_objs[nobjs2] = objs[o]; r_cnts[nobjs2] = kept; nobjs2++; }
    }
    la->count_objs = nobjs2;
    la->objs_ptr = (unsigned long long)(uintptr_t)r_objs;
    la->count_props_ptr = (unsigned long long)(uintptr_t)r_cnts;
    la->props_ptr = (unsigned long long)(uintptr_t)r_props;
    la->prop_values_ptr = (unsigned long long)(uintptr_t)r_vals;
    la->reserved = 0;
    /* kernel treats user_data as an opaque event cookie; keep the child's
     * value so flip completion events carry the pointer kwin expects */
    la->user_data = src.user_data;
    return 0;
}

/* dmesg-proven: this kernel validates atomic flags with the 0x100/0x200/
 * 0x400 encoding (same as the container headers) — kwin's 0x500 reaches the
 * driver; only our translated 0x5 was rejected as "invalid flag". Relay raw. */
static long relay_atomic(struct drm_mode_atomic *la) {
    int ret = ioctl(RELAYFD >= 0 ? RELAYFD : DRMFD, DRM_IOCTL_MODE_ATOMIC, la);
    int e = errno;
    return ret < 0 ? -e : 0;
}

/* ---- primary-plane dual-pipe split --------------------------------------
 * 双 DSI 面板无法由单个 legacy pipe 驱动：kwin 会挑一个 virtual plane，
 * 扫出来是花屏。厂商 composer 与我们的 band commit 用的是两个 SSPP plane
 * （左半 + 右半）喂同一个 framebuffer。所以把 kwin 每一个碰到该 plane 的
 * commit **原地**重写成那个双 plane 布局（scratch 放在线程 SP 之下——
 * 它正在自己 syscall 里，那段栈没人用）。kwin 随后在它自己的 master fd 上
 * 执行被改写过的 commit：返回值、flip 事件、fence 全走原生路径。
 *
 * ══ ★ 本次重构改掉了什么 ══
 * 这些 ID 原来是编译期 #define，写死的是 piano（小米平板 8 Pro）的值：
 *     SPLIT_CRTC 200 / SPLIT_CONN 67 / SPLIT_W 1600 / SPLIT_H 2000
 * 换到任何别的设备上它们全错，而且**不会报错**——只会往错误的对象上写，
 * 现象是"kwin 起来了、也有 master、就是花屏或不出画"，极难定位。
 *
 * 现在：优先运行时发现（init_split），发现结果可被
 * KWINWRAP_SPLIT_{CRTC,CONN,W,H,PLANES} 覆盖；发现失败时**大声告警**
 * 而不是静默用错值。`kwinwrap --probe-split` 可以把结果打印出来。
 *
 * ⚠️ PLANES 是唯一无法可靠自动发现的一项：需要两个"能驱动该 CRTC 且属于
 *    同一 SSPP 组"的 plane，纯靠 possible_crtcs 枚举可能挑错。
 *    首次上新设备请用 --probe-split 的候选列表配合 display/drm-diag-once.sh
 *    的输出人工确认，然后用 KWINWRAP_SPLIT_PLANES 固定下来。
 *
 * （SPLIT_* 变量与 init_split 的声明在本文件靠上的位置，因为
 *   keep_prop / init_keep / probe_split 都早于这里引用它们。）
 */
static __u32 s_objs[64], s_cnts[64], s_props[2048], s_props2[2048];
static __u64 s_vals[2048], s_vals2[2048];
static __u32 pl_fb, pl_crtc, pl_sx, pl_sy, pl_sw, pl_sh, pl_cx, pl_cy, pl_cw, pl_ch;
static __u32 pl_zpos;   /* ★ stage 分组的关键，见 SPLIT_ZPOS_MODE */
/* ★★ connector DPMS 属性 id + "本次提交里见过 SPLIT_CONN" 标记。
 *
 * 为什么必须自己注入 DPMS（实测根因，2026-10-12）：
 *   pre-disable 提交把 conn.CRTC_ID 置 0（解链接），内核**随即把该 connector
 *   的 DPMS 置成 Off**。之后 KWin 重新链接时只写 CRTC_ID=SPLIT_CRTC，
 *   **从不带 DPMS 属性** —— 这个 vendor KMS 不会因为 CRTC_ID 由 0 变非 0
 *   就自动把 DPMS 改回 On。结果：KWin 提交全部 ret=0、亮度也写对了 2048、
 *   session.report 全绿，**但面板 DPMS 停在 Off，屏幕纯黑**。
 *
 *   而 KWin 是 DRM master（kwinwrap DROP_MASTER 后它按"首开者"规则成为
 *   master），所以事后再用 setprop/setbright 去救一律 EACCES：
 *       setprop: set DPMS=0 -> -1 (Permission denied)
 *       setbright 2048     -> -1 (Permission denied)
 *   ⇒ drm_force_display_on 是死路。**唯一能写的时间窗就是这里**：
 *     kwinwrap 正在改写 KWin 的提交、且提交由 KWin 的 master fd 发出。
 *
 *   只在 connector 确实链接到 CRTC 时注入：解链接的提交上设 DPMS=On
 *   有些内核对会直接 EINVAL，那会把整次提交打回 -22，比不设更糟。 */
static __u32 conn_dpms_prop;
static int saw_conn, conn_crtc_val;
/* 本帧是否为"拆解配置"提交（KWin 周期性发的、自身不自洽的那种）。
 * 见 split_commit 里的 SKIP-BAD 段：这类提交要改写成空提交，
 * 让内核返回 0，否则 KWin 会卡在重试死循环里。 */
static int skip_bad;
/* ★ 最近一次见到的**有效 MODE_ID blob**（CRTC 的显示模式）。
 *
 * 为什么要缓存：KWin 的真·页翻转提交（flags=0x201）是**增量**提交 ——
 * 它只带变化过的属性，CRTC 那一项可能只有 VRR_ENABLED，
 * 既没有 ACTIVE 也没有 MODE_ID（因为内核里已经是那个值了，不必重申）。
 * 但 kwinwrap 必须往 SPLIT_CRTC 上写 ACTIVE=1 + MODE_ID 才能把面板点亮，
 * 而此时**提交里根本没有 MODE_ID 可取** ⇒ 必须靠之前 TEST_ONLY 提交里
 * 见过的那个 blob 兜底（实测是 0x13a）。 */
static __u64 last_mode_blob;
/* forensics: last poked scratch, so the exit-stop handler can dump what
 * the kernel actually consumed when a rebuilt commit still fails */
static pid_t sc_tid = -1;
static unsigned long long sc_sp;
static __u32 sc_no, sc_np;
static int sc_dumped;

/* ══════════════════ DPMS-STRIP（2026-10-13 新增）══════════════════
 *
 * 干什么：把面板 connector 的 `DPMS` 属性从 KWin 的原子提交里**摘掉**。
 *
 * ══ 为什么必须摘（这条是"左半屏没画面 + 亮度写不进去"的总根因）══
 *
 * 本内核的 DPMS 属性**没有 DRM_MODE_PROP_ATOMIC 位**：
 *     conn67 "DPMS"  flags=0x00000008   ← 只有 DRM_MODE_PROP_ENUM
 * 而 KWin 只会把 DPMS 塞进 **atomic** 提交。内核的
 * `drm_atomic_set_property()` 一看到"属性不支持原子"就直接 EINVAL，
 * 于是**整个提交**（不只是 DPMS 那一条）全部失败。
 *
 * 后果是连锁的，而且症状完全不指向 DPMS，极难查：
 *   ① CRTC 从未被真正激活 ⇒ 4 条 split plane 没重建
 *      ⇒ **双 DSI 面板只有右半有画面，左半是黑的**
 *   ② 面板的 `dsi_panel` 状态一直停在 off ⇒ `dsi_panel_set_backlight()`
 *      走 bypass 分支（dmesg: `bypass bl 0`）⇒ **brightness 怎么写都读回旧值**
 *   ③ KWin 日志刷屏 `atomic commit failed: 无效的参数` /
 *      `Setting dpms mode failed!`
 *
 * 实测排除过的错路（都试过、都无效，别再走）：
 *   · `kscreen-doctor --dpms off` —— 返回 rc=0 但 DPMS 纹丝不动
 *     （连查 12 秒都是 On），屏幕只"闪一下"
 *   · `kscreen-doctor output.DSI-1.disable` —— 被拒：
 *     "不允许通过配置更改禁用所有输出"
 *   · 改 mode/scale/rotation —— 要么报 "Output mode not found"，
 *     要么反而把 DPMS 又拉回 Off
 *   · `KWINWRAP_DPMS_INJECT=1` —— 往提交里**加** DPMS，同样 EINVAL（见下）
 *
 * ══ 摘掉之后为什么反而全好了 ══
 *
 *   · KWin 的提交恢复 ret=0 ⇒ CRTC 激活、plane 重建 ⇒ **左右两半都有画面**
 *   · 面板进入正常 on 状态 ⇒ `set_backlight` 不再 bypass ⇒ **亮度可写**
 *   · 提交里不再带 DPMS ⇒ KWin **不会覆盖**我们外部设的 DPMS
 *     ⇒ `drmbl dpms off` 能稳定保持关闭，直到我们主动开回来
 *   · KWin 以为自己管着 DPMS、且持续正常渲染 ⇒ 唤醒后它自己就会把
 *     画面重新提交好，不需要重启 KWin
 *
 * ⇒ 所以真正关/开面板的职责移交给了 `tools/runtime/drmbl`（非原子 ioctl，
 *   用 pidfd_getfd 借 KWin 的 master fd）。安卓走的是另一条路
 *   （CRTC ACTIVE=0，原子属性合法），我们照抄不了 —— 那个 CRTC 的原子状态
 *   在 KWin 手里，但"把非原子属性从提交里摘掉"我们做得到。
 *
 * ══ 副作用（已知、可接受）══
 *
 * KWin 自己的"空闲熄屏"从此失效（它的 DPMS 请求被丢弃）。这是本机原本
 * 就有的状态 —— 在加这段之前 KWin 的 DPMS 从来没有成功过。熄屏由
 * input/drm-keys.py + input/lockscreen.sh + drmbl 负责。
 */
static __u32 conn_dpms_strip_prop;   /* DPMS 属性 id，0 = 还没查 */
static int dpms_stripped;            /* 本次提交摘掉了几条（仅用于日志） */

/* 这条属性要不要从提交里摘掉？返回 1 = 摘掉（调用方必须跳过它）。
 * 只摘面板 connector 的 DPMS，别的对象/属性一律不动。 */
static int dpms_should_strip(__u32 obj, __u32 prop)
{
    if (!SPLIT_CONN || obj != SPLIT_CONN)
        return 0;
    if (!conn_dpms_strip_prop)
        conn_dpms_strip_prop = find_prop(SPLIT_CONN,
                                         DRM_MODE_OBJECT_CONNECTOR, "DPMS");
    if (conn_dpms_strip_prop && prop == conn_dpms_strip_prop) {
        dpms_stripped++;
        return 1;
    }
    return 0;
}

static void split_commit(pid_t t, unsigned long long uptr, struct ptregs *r) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) return;
    /* This vendor KMS accepts TEST_ONLY only with ALLOW_MODESET.  KWin's
     * nonblocking probe omits it, which makes every otherwise valid split
     * layout fail with -EINVAL before the first frame can be scanned out. */
    __u32 original_flags = a.flags;
    if ((a.flags & DRM_MODE_ATOMIC_TEST_ONLY) &&
        (a.flags & DRM_MODE_ATOMIC_NONBLOCK)) {
        a.flags = (a.flags | DRM_MODE_ATOMIC_ALLOW_MODESET) &
                  ~DRM_MODE_ATOMIC_NONBLOCK;
    } else if (!(a.flags & DRM_MODE_ATOMIC_TEST_ONLY) &&
               (a.flags & DRM_MODE_PAGE_FLIP_EVENT)) {
        /* ★ 真·页翻转提交（0x201 = NONBLOCK|PAGE_FLIP_EVENT）也必须带
         *   ALLOW_MODESET：分屏改写会把 SPLIT_CRTC 从 ACTIVE=0 拉成 1
         *   （把 connector 链上、给 CRTC 装 mode），这是**真正的 modeset**。
         *   内核规定：提交若需要 modeset 而没带 ALLOW_MODESET，一律 -EINVAL。
         *   实测就是这一条让每一帧的页翻转都失败、屏幕永远全黑。 */
        a.flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
    }
    if (a.flags != original_flags) {
        if (writeto(t, uptr, &a, sizeof a)) {
            fprintf(LOG, "FLAGS: 0x%x -> 0x%x writeback failed\n",
                    original_flags, a.flags);
            fflush(LOG);
            return;
        }
        fprintf(LOG, "FLAGS: 0x%x -> 0x%x\n", original_flags, a.flags);
        fflush(LOG);
    }
    __u32 nobj = a.count_objs;
    if (nobj == 0 || nobj > 60) return;
    if (readmem(t, a.objs_ptr, s_objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, s_cnts, nobj * 4) < 0) return;
    int p97 = -1, pdup = -1;
    unsigned total = 0, eoff[64];
    for (__u32 i = 0; i < nobj; i++) {
        eoff[i] = total;
        if (is_split_plane(s_objs[i])) {
            if (p97 < 0) p97 = (int)i;
            else if (pdup < 0) pdup = (int)i;
        }
        total += s_cnts[i];
    }
    if (total > 2000) return;
    if (readmem(t, a.props_ptr, s_props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, s_vals, (size_t)total * 8) < 0) return;

    saw_conn = 0;          /* 每帧重置：DPMS 注入只针对**本次**提交里的 connector */
    conn_crtc_val = -1;
    skip_bad = 0;          /* 每帧重置：本帧是否为"拆解配置"提交（见下） */

    /* Inventory. kwin's choice of plane/crtc varies round to round (it
     * re-probes and falls back to REAL planes 133/141 on REAL crtcs
     * 271/280/298 when a test fails — that raw phase showed black garbage:
     * one full-width plane cannot drive the split DSI panel). So never
     * assume the fake plane or crtc 206 were picked: steal the framebuffer
     * from whichever plane is active, force halves onto crtc 206, and
     * re-home whatever connector/crtc the commit lights up. */
    __u64 fb = 0, kblob = 0;
    int kact = -1, i206 = -1, iconn = -1, areal = -1;
    int areal_fb = -1, areal_crtc = -1, kact_act = -1, kact_mode = -1;
    int i206_act = -1, i206_mode = -1, iconn_crtc = -1;
    for (__u32 o = 0; o < nobj; o++) {
        if ((int)o == p97 || (int)o == pdup) continue;
        unsigned base = eoff[o];
        __u32 oc = s_cnts[o];
        int i_act = -1, i_mode = -1, i_crtc = -1, i_fb = -1;
        for (__u32 i = 0; i < oc; i++) {
            const char *nm = pname(s_props[base + i]);
            if (!strcmp(nm, "ACTIVE")) i_act = (int)i;
            else if (!strcmp(nm, "MODE_ID")) i_mode = (int)i;
            else if (!strcmp(nm, "CRTC_ID")) i_crtc = (int)i;
            else if (!strcmp(nm, "FB_ID")) i_fb = (int)i;
        }
        if (s_objs[o] == SPLIT_CRTC) {
            /* ★ 去掉原来的 `&& i_act >= 0` 限制：KWin 的增量提交里
             *   SPLIT_CRTC 可能只有 VRR_ENABLED（无 ACTIVE/MODE_ID），
             *   加了这个限制 i206 就恒为 -1，后面的 ACTIVE/MODE_ID 注入
             *   整段不执行 —— CRTC 永远激活不了。 */
            i206 = (int)o; i206_act = i_act; i206_mode = i_mode;
            if (i_mode >= 0 && s_vals[base + i_mode])
                last_mode_blob = s_vals[base + i_mode];
            continue;
        }
        if (i_act >= 0 && s_vals[base + i_act]) {   /* crtc kwin lights up */
            kact = (int)o; kact_act = i_act; kact_mode = i_mode;
            kblob = i_mode >= 0 ? s_vals[base + i_mode] : 0;
            if (kblob) last_mode_blob = kblob;
            continue;
        }
        if (s_objs[o] == SPLIT_CONN) {
            /* 记下 connector 与它本次被链到的 CRTC，供后面注入 DPMS 判据用。
             * iconn 只在 CRTC_ID != SPLIT_CRTC 时才置位，而实测 KWin 稳定后
             * CRTC_ID 恰好 == SPLIT_CRTC ⇒ iconn 一直是 -1，connector 走
             * 默认路径被原样透传 —— 这就是 DPMS 永远没人设的原因。 */
            saw_conn = 1;
            conn_crtc_val = (i_crtc >= 0) ? (int)s_vals[base + i_crtc] : -1;
            if (i_crtc >= 0 && s_vals[base + i_crtc] != SPLIT_CRTC) {
                iconn = (int)o; iconn_crtc = i_crtc;
            }
            continue;
        }
        /* ★ 取 fb 的判据放宽：原来是 `i_crtc >= 0 && s_vals[base+i_crtc]`，
         *   要求 plane 必须已绑 CRTC。但 KWin 的增量提交里那个 3200 全宽
         *   plane（实测 obj 92）常常**带非零 FB_ID 却没有 CRTC_ID**，
         *   于是 areal 恒为 -1、fb 恒为 0、do_split=0，整个分屏改写不执行，
         *   全宽 plane 原样透传给单个 CRTC → SDE 判超宽 EINVAL。
         *   现在只要 plane 带非零 FB_ID 就认它，CRTC_ID 允许缺失。 */
        if (i_fb >= 0 && s_vals[base + i_fb] && areal < 0) {
            areal = (int)o; areal_fb = i_fb; areal_crtc = i_crtc;
            fb = s_vals[base + i_fb];
        }
    }
    if (p97 >= 0) {
        unsigned base = eoff[p97];
        for (__u32 i = 0; i < s_cnts[p97]; i++)
            if (!strcmp(pname(s_props[base + i]), "FB_ID") && s_vals[base + i]) {
                fb = s_vals[base + i];
                break;
            }
    }
    int do_split = fb != 0;
    /* ★ 增量提交里 CRTC 项可能不带 MODE_ID ⇒ 用缓存的上一个有效 blob 兜底，
     *   否则往 SPLIT_CRTC 上写 ACTIVE=1 却没有 MODE_ID，内核仍判无效。 */
    if (!kblob) kblob = last_mode_blob;
    /* ★★ 识别并跳过 KWin 的"拆解配置"提交。
     *
     * 实测根因（2026-10-12，OPD2511）—— KWin 会周期性发一种提交，内容是
     * **把已有的分屏配置拆掉**，且它自身就不自洽：
     *
     *   FBSCAN: nobj=3 fb=0 p97=0 areal=-1 kact=-1 i206=-1 do_split=0
     *      o=0 obj=143 oc=3  FB_ID=有 CRTC_ID=有   ← 虚拟半屏 plane
     *      o=1 obj=92  oc=11 FB_ID=有 CRTC_ID=-    ← 全宽 plane：有 fb 却不绑 crtc
     *      o=2 obj=200 oc=1  (仅 VRR_ENABLED)      ← CRTC 缺 MODE_ID/ACTIVE
     *
     * 这种提交有三重问题：
     *   1) `areal` 要求 plane 的 CRTC_ID 非 0，而 plane 92 的 CRTC_ID 是 0
     *      ⇒ `fb` 拿不到（fb=0）⇒ `do_split=0`，分屏改写整段不执行；
     *   2) 于是走 "strip only"，把 plane 92 带着 FB_ID 原样留给一个
     *      **没有 ACTIVE 的 CRTC** —— 内核判 EINVAL（-22）；
     *   3) 内核 dmesg 同时报超宽：
     *        [_sde_crtc_check_plane_layout] invalid horizontal destination
     *        x:0 w:3200 hdisp:1600  →  crtc200 failed plane layout check -7
     *      印证 plane 92 是 3200 全宽，而 SDE 每个 CRTC 上限 1600。
     *
     * 后果：KWin 卡在 `nobj=4 成功 → nobj=3 失败 → 重试` 的死循环，
     * CRTC 200 永远激活不了（kmsdump: ACTIVE=0 fb=0），从来没有帧被扫出来，
     * 屏幕纯黑，kwin.log 一直刷 "atomic commit failed: 无效的参数"。
     *
     * 处理：这类提交**没有可用的显示配置**（既没点亮任何 CRTC，也没法
     * 安全改写），直接改写成**空提交**让内核返回 0 —— KWin 拿到成功就不会
     * 卡在重试里，能继续走到它后面那些真正带 ACTIVE 的提交
     * （那些会走正常的分屏改写路径）。
     *
     * ⚠️ 判据要害（第一版踩过坑，务必按这个来）：
     *    **只看"提交里有没有 ACTIVE=1 的 CRTC"**，有就一律放行。
     *
     *    第一版判据是"只要存在'有非零 FB_ID 却不绑 CRTC'的 plane 就跳过"，
     *    结果**误伤了 KWin 的正常页翻转提交**：那种提交里有
     *        plane 92 FB_ID=0 CRTC_ID=0      ← 合法的空闲 plane
     *        obj 200  ACTIVE=1 MODE_ID=0x13a ← 真正点亮的 CRTC
     *    它是完全健康的配置，却因为别的对象被判 bad_plane 而整体改成空提交，
     *    于是页翻转全失败（20 次 ret=-22），KWin 依然黑屏。
     *
     *    改成"没有 ACTIVE=1 的 CRTC 才跳过"后：
     *      · nobj=2 flags=0x201（有 obj200 ACTIVE=1）→ 放行，正常页翻转 ✅
     *      · nobj=3 flags=0x300（obj200 只有 VRR_ENABLED，无 ACTIVE）
     *        → 跳过，正是那个把 KWin 拖进重试死循环的拆解配置 ✅ */
    {
        int bad_plane = 0, has_active_crtc = 0;
        for (__u32 o = 0; o < nobj && !has_active_crtc; o++) {
            if ((int)o == p97 || (int)o == pdup) continue;
            unsigned b2 = eoff[o];
            int f2 = -1, c2 = -1, a2 = -1;
            for (__u32 i = 0; i < s_cnts[o]; i++) {
                const char *nm = pname(s_props[b2 + i]);
                if (!strcmp(nm, "FB_ID")) f2 = (int)i;
                else if (!strcmp(nm, "CRTC_ID")) c2 = (int)i;
                else if (!strcmp(nm, "ACTIVE")) a2 = (int)i;
            }
            if (a2 >= 0 && s_vals[b2 + a2] == 1) { has_active_crtc = 1; break; }
            /* plane（有 FB_ID 属性）带非零 fb，却没绑任何 CRTC */
            if (f2 >= 0 && s_vals[b2 + f2] != 0 &&
                (c2 < 0 || s_vals[b2 + c2] == 0))
                bad_plane = 1;
        }
        /* ⚠️ 这里**只记录，不再改写**。
         *   曾经把这类提交改成空提交来绕开重试死循环，但那只是治标：
         *   真正的病根是 areal 判据太严 + i206 分支被 kact>=0 挡住，
         *   已在本函数上面修好。现在这类提交会走正常分屏改写路径，
         *   被正确补上 ACTIVE/MODE_ID 并拆成两个半屏。
         *   留着这段日志是为了将来换设备时能一眼看出提交形态。 */
        if (!has_active_crtc && TRACE) {
            static int nlogbad;
            if (++nlogbad <= 5) {
                fprintf(LOG, "NOACTIVE: 增量提交（本帧无 ACTIVE CRTC，坏plane=%d）"
                        " nobj=%u flags=0x%x —— 由分屏改写补 ACTIVE/MODE_ID\n",
                        bad_plane, nobj, a.flags);
                fflush(LOG);
            }
        }
    }
    /* ★ 追踪 do_split 的判据：fb 为什么是 0？
     *   实测 nobj=3 的真提交里 plane 92 明明带 FB_ID=0x13b，但
     *   SPLIT 行显示 fb=0 / split=0，于是走"strip only"路径、
     *   全宽 plane 原样透传给单个 CRTC → SDE 判超宽 EINVAL。 */
    {
        static int nfs;
        if (TRACE && nfs < 30) {
            nfs++;
            fprintf(LOG, "FBSCAN: nobj=%u fb=%llu p97=%d pdup=%d areal=%d kact=%d "
                    "iconn=%d i206=%d do_split=%d\n",
                    nobj, fb, p97, pdup, areal, kact, iconn, i206, do_split);
            for (__u32 o = 0; o < nobj && o < 12; o++) {
                unsigned b2 = eoff[o];
                int f2 = -1, c2 = -1;
                for (__u32 i = 0; i < s_cnts[o]; i++) {
                    const char *nm = pname(s_props[b2 + i]);
                    if (!strcmp(nm, "FB_ID")) f2 = (int)i;
                    else if (!strcmp(nm, "CRTC_ID")) c2 = (int)i;
                }
                fprintf(LOG, "   o=%u obj=%u oc=%u FB_ID=%s CRTC_ID=%s\n",
                        o, s_objs[o], s_cnts[o],
                        f2 >= 0 ? "有" : "-", c2 >= 0 ? "有" : "-");
            }
            fflush(LOG);
        }
    }
    /* ★★ KWINWRAP_NO_SPLIT=1：**禁用分屏改写，让 KWin 的原始提交透传**。
     *
     * 为什么要这个开关（实测 2026-10-12，OPD2511）：
     *   安卓侧内核日志显示这块 DSI 面板是**完整宽度单模式**：
     *       dsi_display_set_mode: hactive=3200, vactive=2000, fps=144
     *       modes = 3200x2000x{120,144,90,60}vid
     *   也就是说安卓用一个 CRTC + 一个 3200 宽平面就能点亮它。
     *   而分屏改写把面板当成两个 1600 宽半屏（SPLIT_W=1600，
     *   半屏 plane 143/147 各覆盖一半）来驱动 —— 这是历史包袱，
     *   文件里"一个全宽平面无法驱动该面板"那句注释与安卓实测矛盾。
     *
     *   分屏改写的实际后果（kwinatomic.log）：KWin 的 nobj=3 真提交被
     *   改写成只剩 2 个对象（丢了 connector 和 CRTC 的 MODE_ID/ACTIVE），
     *   内核判 EINVAL；于是 CRTC 200 永远激活不了（kmsdump: ACTIVE=0 fb=0），
     *   **从来没有帧被扫描出来**，KWin 一直刷
     *   "kwin_wayland_drm: atomic commit failed: 无效的参数"。
     *
     *   打开这个开关后 kwinwrap 仍然做它必须做的事（pre-disable 清安卓
     *   遗留状态、写亮度/DPMS、DROP_MASTER、降权、exec kwin），
     *   只是**不再改写 atomic 提交** —— 让 KWin 按它自己的全宽平面走，
     *   与安卓一致。 */
    if (getenv("KWINWRAP_NO_SPLIT")) do_split = 0;
    if (do_split && kact >= 0 && !kblob) {
        __u32 mp = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
        drmModeObjectProperties *cp =
            drmModeObjectGetProperties(DRMFD, SPLIT_CRTC,
                                       DRM_MODE_OBJECT_CRTC);
        if (mp && cp) {
            for (uint32_t i = 0; i < cp->count_props; i++)
                if (cp->props[i] == mp) { kblob = cp->prop_values[i]; break; }
            drmModeFreeObjectProperties(cp);
        }
    }
    if (p97 < 0 && areal < 0 && kact < 0 && iconn < 0) {
        static int np97;
        if (++np97 <= 3) {
            fprintf(LOG, "SPLIT: nothing to steal (nobj=%u objs:", nobj);
            for (__u32 i = 0; i < nobj && i < 16; i++)
                fprintf(LOG, " %u", s_objs[i]);
            fprintf(LOG, "\n");
            fflush(LOG);
        }
        /* ★ 例外：如果是被判定的"拆解配置"提交，**不要**在这里返回 ——
         *   要继续往下走，让构建循环产出一个**空提交**（no=0）写回 child，
         *   内核收到空提交返回 0，KWin 才不会卡在重试死循环里。
         *   见上面 SKIP-BAD 段的完整说明。 */
        if (!skip_bad) return;
    }
    __u32 virt_id = p97 >= 0 ? s_objs[p97] :
                    (areal >= 0 ? s_objs[areal] : 0);
    if (getenv("KWINWRAP_NO_SPLIT")) {
        /* ★ 完全不改写，KWin 的原始提交透传（flags 的 ALLOW_MODESET 改写
         * 已经在函数开头写回 child 了，那一条要保留）。 */
        static int nopass;
        if (++nopass <= 3) {
            fprintf(LOG, "NO-SPLIT: 透传 KWin 原始提交（nobj=%u flags=0x%x）\n",
                    nobj, a.flags);
            fflush(LOG);
        }
        return;
    }
    if (!do_split) {
        static int nskip;
        if (++nskip <= 3) {
            fprintf(LOG, "SPLIT: idle virt, strip only (#%d) virt=%u\n",
                    nskip, virt_id);
            fflush(LOG);
        }
    }
    if (do_split) {
        if (!pl_crtc) {
            pl_crtc = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "CRTC_ID");
            pl_fb = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "FB_ID");
            if (!pl_fb) pl_fb = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "FB");
            pl_sx = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "SRC_X");
            pl_sy = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "SRC_Y");
            pl_sw = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "SRC_W");
            pl_sh = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "SRC_H");
            pl_cx = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "CRTC_X");
            pl_cy = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "CRTC_Y");
            pl_cw = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "CRTC_W");
            pl_ch = find_prop(SPLIT_PLANE[0], DRM_MODE_OBJECT_PLANE, "CRTC_H");
            fprintf(LOG, "SPLIT: prop ids fb=%u crtc=%u src=%u/%u/%u/%u dst=%u/%u/%u/%u\n",
                    pl_fb, pl_crtc, pl_sx, pl_sy, pl_sw, pl_sh, pl_cx, pl_cy, pl_cw, pl_ch);
            fflush(LOG);
        }
        if (!pl_fb || !pl_crtc || !pl_sx || !pl_cw) return;
    }

    /* If a half-pipe plane is already an object in this commit (kwin lists all
     * idle planes every frame), rewriting it in place beats appending a
     * duplicate — duplicate plane objects collide in kernel state (src_h=0
     * garbage -> check failure / E2BIG). */
    __u32 no = 0, np = 0;
    unsigned off = 0;
    int hfound[SPLIT_MAX_SEG];
    memset(hfound, 0, sizeof hfound);
    /* dmesg-proven: on a real commit carrying PAGE_FLIP_EVENT the kernel
     * creates a vblank event for EVERY crtc state in the commit; an event on
     * an off pipe fails drm_atomic_crtc_check ("requesting event but off",
     * -EINVAL) while TEST_ONLY commits never get here. So never carry a
     * crtc that stays off (271's VRR-only no-op entries, kact shutdowns). */
    int evdrop = !(a.flags & DRM_MODE_ATOMIC_TEST_ONLY) &&
                 (a.flags & DRM_MODE_PAGE_FLIP_EVENT);
    for (__u32 o = 0; o < nobj; o++) {
        __u32 oc = s_cnts[o];   /* snapshot: s_cnts[no] write may alias s_cnts[o] */
        if ((int)o == p97 || (int)o == pdup) { off += oc; continue; }
        if (evdrop) {
            int is_crtc = 0, lit = 0;
            for (__u32 i = 0; i < oc; i++) {
                const char *nm = pname(s_props[off + i]);
                int crtcy = !strcmp(nm, "ACTIVE") || !strcmp(nm, "MODE_ID") ||
                            !strcmp(nm, "VRR_ENABLED");
                is_crtc |= crtcy;
                if (crtcy && s_vals[off + i]) lit = 1;
            }
            if (is_crtc && !lit) {
                static int nevd;
                if (TRACE && ++nevd <= 3) {
                    fprintf(LOG, "EVDROP: off crtc %u stripped from 0x%x (#%d)\n",
                            s_objs[o], a.flags, nevd);
                    fflush(LOG);
                }
                off += oc;
                continue;
            }
        }
        int hidx = split_seg_index(s_objs[o]);
        if (do_split && hidx >= 0) {
            __u32 n0 = np;
            s_props2[np] = pl_crtc; s_vals2[np++] = SPLIT_CRTC;
            s_props2[np] = pl_fb;   s_vals2[np++] = fb;
            /* 几何规则（与 Android 基线一致）：
             *   源列 = 段号 * 段宽（整幅 3200 图上的真实列）
             *   目的 = 段号 * 段宽（**整屏全局**坐标 0,800,1600,2400）
             *     —— 驱动 _sde_crtc_check_plane_layout() 靠 crtc_x >= 1600
             *        判定 SDE_LAYOUT_RIGHT（右半屏那对 LM2/LM3），并自己减掉
             *        1600 得到链路内地址；kmsdump 读回的就是减完的值。
             * Android 实测：131→提交(0,0) 127→(800,800) 123→(1600,1600) 92→(2400,2400)
             * 正是 (crtc_x, src_x)，完全吻合。 */
            s_props2[np] = pl_sx; s_vals2[np++] = (__u64)hidx * SPLIT_W << 16;
            s_props2[np] = pl_sy; s_vals2[np++] = 0;
            s_props2[np] = pl_sw; s_vals2[np++] = (__u64)SPLIT_W << 16;
            s_props2[np] = pl_sh; s_vals2[np++] = (__u64)SPLIT_H << 16;
            s_props2[np] = pl_cx; s_vals2[np++] = (__u64)split_dst_x(hidx);
            s_props2[np] = pl_cy; s_vals2[np++] = 0;
            s_props2[np] = pl_cw; s_vals2[np++] = SPLIT_W;
            s_props2[np] = pl_ch; s_vals2[np++] = SPLIT_H;
            s_objs[no] = s_objs[o];
            s_cnts[no] = np - n0;
            no++;
            hfound[hidx] = 1;
            off += oc;
            continue;
        }
        if (do_split && (int)o == areal) {
            /* 把取 fb 的那个全宽 plane 关掉。
             *
             * ★★ 关键：**必须显式补 CRTC_ID=0**，不能只置 FB_ID=0。
             *   实测踩坑：KWin 的增量提交里 plane 92 常常**根本没有 CRTC_ID
             *   属性**（它没打算改绑定），于是原来的代码只写 FB_ID=0，
             *   内核那边 plane 92 仍然挂在 CRTC 200 上、且保留着
             *   CRTC_W=3200 —— `_sde_crtc_check_plane_layout` 照样检查它，
             *   报 "invalid horizontal destination / x:0 w:3200 hdisp:1600"，
             *   整个提交 EINVAL。补上 CRTC_ID=0 才是真正解除绑定。 */
            __u32 nc = 0;
            s_props2[np] = s_props[off + areal_fb]; s_vals2[np++] = 0; nc++;
            __u32 cp = (areal_crtc >= 0)
                           ? s_props[off + areal_crtc]
                           : find_prop(s_objs[o], DRM_MODE_OBJECT_PLANE, "CRTC_ID");
            if (cp) { s_props2[np] = cp; s_vals2[np++] = 0; nc++; }
            s_objs[no] = s_objs[o];
            s_cnts[no] = nc;
            no++;
            off += oc;
            continue;
        }
        if (do_split && (int)o == kact) {
            /* kwin lit crtc K (271/280/298...): shut it down, 206 takes over */
            for (__u32 i = 0; i < oc; i++, off++) {
                s_props2[np] = s_props[off];
                s_vals2[np++] = ((int)i == kact_act || (int)i == kact_mode)
                                    ? 0 : s_vals[off];
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = oc;
            no++;
            continue;
        }
        /* ★ 去掉原来的 `&& kact >= 0` 限制。
         *   这是黑屏的**最后一环**：KWin 的真·页翻转提交里 CRTC 200 只有
         *   VRR_ENABLED（增量提交，不重申 ACTIVE/MODE_ID），于是 kact=-1，
         *   整个分支不执行 ⇒ 面板永远没人把它 ACTIVE 起来。
         *   现在无条件进入，并在缺属性时**补上** ACTIVE=1 与 MODE_ID。 */
        if (do_split && (int)o == i206) {
            for (__u32 i = 0; i < oc; i++, off++) {
                __u64 v = s_vals[off];
                if ((int)i == i206_act) v = 1;
                else if (i206_mode >= 0 && (int)i == i206_mode) v = kblob;
                s_props2[np] = s_props[off];
                s_vals2[np++] = v;
            }
            if (i206_act < 0) {
                __u32 pa = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "ACTIVE");
                if (pa) { s_props2[np] = pa; s_vals2[np++] = 1; oc++; }
            }
            if (i206_mode < 0 && kblob) {
                __u32 mp = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
                if (mp) { s_props2[np] = mp; s_vals2[np++] = kblob; oc++; }
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = oc;
            no++;
            continue;
        }
        if (do_split && (int)o == iconn) {
            __u32 n0 = np;
            for (__u32 i = 0; i < oc; i++, off++) {
                if (dpms_should_strip(s_objs[o], s_props[off]))
                    continue;                    /* ★ DPMS-STRIP */
                s_props2[np] = s_props[off];
                s_vals2[np++] = (int)i == iconn_crtc ? SPLIT_CRTC : s_vals[off];
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = np - n0;
            no++;
            continue;
        }
        /* Drop no-op plane entries (FB=0, CRTC=0, no live fence): kwin lists all
         * idle planes every commit; sde atomic_check time scales with objects,
         * and these entries cannot change kernel state (only 157/161 ever got
         * enabled by us; those hit the in-place branch above when listed). */
        if (hidx < 0) {
            int planeish = 0, active = 0;
            for (__u32 i = 0; i < oc; i++) {
                const char *nm = pname(s_props[off + i]);
                __u64 v = s_vals[off + i];
                if (!strcmp(nm, "FB_ID") || !strcmp(nm, "CRTC_ID")) {
                    planeish = 1;
                    if (v) { active = 1; break; }
                } else if (!strcmp(nm, "IN_FENCE_FD") && v != 0 &&
                           v != 0xffffffffffffffffULL) {
                    planeish = 1; active = 1; break;
                }
            }
            /* ★ 追踪：这条"丢弃 no-op plane"规则到底吃掉了什么对象。
             *   实测分屏下 KWin 会发 nobj=3 的真提交，改写后只剩 2 个对象、
             *   内核判 EINVAL，CRTC 永远激活不了（kmsdump: ACTIVE=0 fb=0）。
             *   这里把被丢弃对象的身份与关键属性记下来，才能确定它是不是 plane。 */
            static int ndrop;
            if (TRACE && ndrop < 30) {
                ndrop++;
                fprintf(LOG, "DROP-CAND: obj=%u oc=%u planeish=%d active=%d => %s | props:",
                        s_objs[o], oc, planeish, active,
                        (planeish && !active) ? "丢弃" : "保留");
                for (__u32 i = 0; i < oc && i < 14; i++)
                    fprintf(LOG, " %s#%u=0x%llx", pname(s_props[off + i]),
                            s_props[off + i], s_vals[off + i]);
                fprintf(LOG, "\n");
                fflush(LOG);
            }
            if (planeish && !active) { off += oc; continue; }
        }
        {
            /* ★★★★ DPMS-STRIP ★★★★
             * 摘掉 connector 的 DPMS 属性，否则整条提交被内核判 EINVAL
             * （该属性没有 DRM_MODE_PROP_ATOMIC 位）。
             * 后果连锁到"左半屏没画面 + 亮度写不进去"，详见本文件
             * 顶部 DPMS-STRIP 那段注释。
             * ★ 计数必须跟着改：s_cnts 是**摘完之后**的条数，
             *   否则内核会读到越界的属性值。 */
            __u32 n0 = np;
            for (__u32 i = 0; i < oc; i++, off++) {
                if (dpms_should_strip(s_objs[o], s_props[off]))
                    continue;
                s_props2[np] = s_props[off];
                s_vals2[np]  = s_vals[off];
                np++;
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = np - n0;
            no++;
        }
    }
    if (do_split) {
        for (int h = 0; h < SPLIT_NSEG; h++) {
            if (hfound[h]) continue;
            __u32 n0 = np;
            s_props2[np] = pl_crtc; s_vals2[np++] = SPLIT_CRTC;
            s_props2[np] = pl_fb;   s_vals2[np++] = fb;
            s_props2[np] = pl_sx; s_vals2[np++] = (__u64)h * SPLIT_W << 16;
            s_props2[np] = pl_sy; s_vals2[np++] = 0;
            s_props2[np] = pl_sw; s_vals2[np++] = (__u64)SPLIT_W << 16;
            s_props2[np] = pl_sh; s_vals2[np++] = (__u64)SPLIT_H << 16;
            s_props2[np] = pl_cx; s_vals2[np++] = (__u64)split_dst_x(h);
            s_props2[np] = pl_cy; s_vals2[np++] = 0;
            s_props2[np] = pl_cw; s_vals2[np++] = SPLIT_W;
            s_props2[np] = pl_ch; s_vals2[np++] = SPLIT_H;
            s_objs[no] = SPLIT_PLANE[h];
            s_cnts[no] = np - n0;
            no++;
        }
        if (kact >= 0 && i206 < 0 && kblob) {
            __u32 pa = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "ACTIVE");
            __u32 pm = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            if (pa && pm) {
                __u32 n0 = np;
                s_props2[np] = pa; s_vals2[np++] = 1;
                s_props2[np] = pm; s_vals2[np++] = kblob;
                s_objs[no] = SPLIT_CRTC;
                s_cnts[no] = np - n0;
                no++;
            }
        }
    }

    /* ★★★ 面板 connector 必须在提交里，而且必须带 CRTC_ID。
     *
     * 为什么（2026-10-12 定论，厂商源码 + 设备实测双重印证）：
     *
     *   `_sde_crtc_check_plane_layout()`（sde_crtc.c）的**第一件事**就是
     *       if (!sde_rm_topology_is_group(&kms->rm, crtc_state,
     *               SDE_RM_TOPOLOGY_GROUP_QUADPIPE))
     *           return 0;
     *   而 `sde_rm_topology_is_group()` 是**遍历 crtc_state 上的 connector**
     *   去问每个 connector state 的 topology：
     *       for (i = 0; i < cstate->num_connectors; i++) {
     *           conn_state = drm_atomic_get_new_connector_state(state->state, conn);
     *           if (!conn_state) continue;              ← 没有 state 就跳过
     *           sde_connector_state_get_topology(conn_state, &topology);
     *           if (TOPOLOGY_QUADPIPE_MODE(name)) return true;
     *       }
     *       return false;
     *
     *   而 `cstate->num_connectors` 来自 `crtc_state->connector_mask`，后者
     *   **只在提交里真的写了 connector 的 CRTC_ID 时**才会被
     *   `drm_atomic_set_crtc_for_connector()` 置位。KWin 的页翻转提交是
     *   纯 plane+CRTC 的增量提交，**不带 connector** ⇒ mask=0 ⇒
     *   num_connectors=0 ⇒ 拓扑判 false ⇒ 布局检查整段 return 0。
     *
     *   后果（kmsdump 实证，2026-10-12 16:0x）：
     *       plane 92  CRTC_X=2400  SRC_X=2400<<16   ← 提交什么就读回什么，
     *       plane 123 CRTC_X=1600  SRC_X=1600<<16      驱动**没有**减 1600
     *       plane 127 CRTC_X=800   SRC_X=800<<16
     *       plane 131 CRTC_X=0     SRC_X=0
     *   ⇒ `pstate->layout` 恒为 SDE_LAYOUT_NONE/LEFT ⇒ 4 条平面全进
     *     `stage_cfg[0]` ⇒ 只有 LM0/LM1 拿到图层，LM2/LM3（DSI1=右半屏）
     *     空转；同时 dst 1600/2400 的平面落在 LM0/LM1 的 ROI(0..1600) 之外，
     *     取数越界 ⇒ evtlog 出现 399 次 underrun、整屏彩色噪声。
     *   evtlog 旁证：安卓侧 `sde_encoder_virt_atomic_check` 出现 82 次，
     *   我们这边 **0 次** —— 编码器的 atomic_check 也是靠"提交里有
     *   connector"才会被 DRM core 调起来的，同一个缺席原因。
     *
     * 修法：本次提交里若没有 SPLIT_CONN，就补一个只带 CRTC_ID 的对象；
     * 若有但它这条没带 CRTC_ID，就在它属性末尾插一条。这样内核才会为
     * connector 建 state、置 connector_mask，拓扑与布局检查才会真正执行，
     * `_sde_crtc_check_plane_layout()` 才能把 123/92 判成 SDE_LAYOUT_RIGHT
     * 并把 CRTC_X 各减 1600（变回链路内 0/800），交给 LM2/LM3。
     *
     * ⚠️ 只写 CRTC_ID：DPMS 在本内核 flags 里没有 DRM_MODE_PROP_ATOMIC，
     *    塞进原子提交会被判 EINVAL（见下面 DPMS-INJECT 那段血泪注释）。 */
    if (SPLIT_CONN && np < 2048 && no < 64) {
        static __u32 conn_crtc_prop;
        if (!conn_crtc_prop)
            conn_crtc_prop = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR,
                                       "CRTC_ID");
        if (conn_crtc_prop) {
            int ci = -1;
            for (__u32 i = 0; i < no && ci < 0; i++)
                if (s_objs[i] == SPLIT_CONN) ci = (int)i;
            if (ci < 0) {
                /* 提交里完全没有 connector —— 追加一个只带 CRTC_ID 的对象 */
                s_props2[np] = conn_crtc_prop;
                s_vals2[np++] = SPLIT_CRTC;
                s_objs[no] = SPLIT_CONN;
                s_cnts[no] = 1;
                no++;
                static int nadd;
                if (TRACE && ++nadd <= 5) {
                    fprintf(LOG, "CONN-ADD: 提交无 conn%u，已追加 CRTC_ID=%u"
                            "（prop=%u）\n", SPLIT_CONN, SPLIT_CRTC,
                            conn_crtc_prop);
                    fflush(LOG);
                }
            } else {
                /* connector 在，但本帧没带 CRTC_ID ⇒ connector_mask 仍为 0 */
                unsigned begin = 0, end;
                for (int i = 0; i < ci; i++) begin += s_cnts[i];
                end = begin + s_cnts[ci];
                int has = 0;
                for (unsigned k = begin; k < end; k++)
                    if (s_props2[k] == conn_crtc_prop) {
                        if (s_vals2[k] != SPLIT_CRTC) s_vals2[k] = SPLIT_CRTC;
                        has = 1;
                        break;
                    }
                if (!has) {
                    for (unsigned k = np; k > end; k--) {
                        s_props2[k] = s_props2[k - 1];
                        s_vals2[k] = s_vals2[k - 1];
                    }
                    s_props2[end] = conn_crtc_prop;
                    s_vals2[end] = SPLIT_CRTC;
                    np++;
                    s_cnts[ci]++;
                    static int ncrtc;
                    if (TRACE && ++ncrtc <= 5) {
                        fprintf(LOG, "CONN-CRTC: conn%u 本帧缺 CRTC_ID，已插 "
                                "CRTC_ID=%u（prop=%u）\n", SPLIT_CONN,
                                SPLIT_CRTC, conn_crtc_prop);
                        fflush(LOG);
                    }
                }
            }
        }
    }

    /* ★★ 给本次提交里的面板 connector 补一个 DPMS=On。
     *
     * ⚠️ 默认**关闭**，因为在本机内核上试过并且**失败**：
     *   本内核的 DPMS 属性 flags=0x00000008，只有 DRM_MODE_PROP_ENUM，
     *   **没有 DRM_MODE_PROP_ATOMIC**。往 atomic 提交里塞它会被判 EINVAL，
     *   把原本 ret=0 的提交打成 -22（实测 23 次 -22 / 4 次 0，KWin 一直重试）。
     *   ⇒ 本机的 DPMS 只能在 DROP_MASTER 之前用**非原子** ioctl 写一次，
     *     见下面 "DPMS=On(conn...)" 那段。
     *
     * 这段保留是因为它对**支持 atomic DPMS 的内核**（DRM_MODE_PROP_ATOMIC
     * 置位）是正确且更鲁棒的做法：能在 KWin 每帧提交里持续纠正 DPMS，
     * 不依赖"只在交接那一刻写一次"的时序。换设备若发现 DPMS 老是被关，
     * 用 KWINWRAP_DPMS_INJECT=1 打开它。
     *
     * 触发条件（两条都必要）：
     *   · 本次提交里确实有 SPLIT_CONN
     *   · 它的 CRTC_ID 非 0（真被链上了）。解链接的提交上设 DPMS 有些内核
     *     直接 EINVAL，那会把整次提交打回 -22，比不设更糟。
     *
     * 只做一次属性查找（find_prop 要遍历对象属性，别每帧做）。 */
    if (getenv("KWINWRAP_DPMS_INJECT") && saw_conn && conn_crtc_val > 0) {
        if (!conn_dpms_prop)
            conn_dpms_prop = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
        if (conn_dpms_prop) {
            int done = 0, o2 = 0;
            for (__u32 i = 0; i < no && !done; i++) {
                if (s_objs[i] == SPLIT_CONN) {
                    unsigned end = (unsigned)o2 + s_cnts[i];
                    int has = 0;
                    for (unsigned k = (unsigned)o2; k < end; k++)
                        if (s_props2[k] == conn_dpms_prop) {
                            if (s_vals2[k] != 0) s_vals2[k] = 0;
                            has = 1;
                            break;
                        }
                    if (!has) {
                        /* 属性数组按对象顺序连续存放，只需在本对象属性末尾插一条，
                         * 后面对象的属性自然后移。 */
                        if (np < 2048) {
                            for (unsigned k = np; k > end; k--) {
                                s_props2[k] = s_props2[k - 1];
                                s_vals2[k] = s_vals2[k - 1];
                            }
                            s_props2[end] = conn_dpms_prop;
                            s_vals2[end] = 0;   /* DRM_MODE_DPMS_ON == 0 */
                            np++;
                            s_cnts[i]++;
                        }
                    }
                    done = 1;
                }
                o2 += s_cnts[i];
            }
            static int ndpms;
            if (ndpms < 4) {
                ndpms++;
                fprintf(LOG, "DPMS-INJECT: 注入 DPMS=On 到 conn%u（prop=%u，链接 crtc%u）%s\n",
                        SPLIT_CONN, conn_dpms_prop, conn_crtc_val,
                        done ? "" : " [没找到 conn 对象，跳过]");
                fflush(LOG);
            }
        }
    }

    static int ndebug;
    if (TRACE && ++ndebug <= 12) {
        fprintf(LOG, "BUILT: flags=0x%x no=%u np=%u total=%u cnts[", a.flags, no, np, total);
        for (__u32 i = 0; i < no; i++)
            fprintf(LOG, "%u,", s_cnts[i]);
        fprintf(LOG, "] objs:");
        unsigned o2 = 0;
        for (__u32 i = 0; i < no; i++) {
            fprintf(LOG, " %u[%u]", s_objs[i], s_cnts[i]);
            for (__u32 j = 0; j < s_cnts[i]; j++, o2++)
                fprintf(LOG, " %s#%u=0x%llx", pname(s_props2[o2]),
                        s_props2[o2], s_vals2[o2]);
        }
        fprintf(LOG, "\n");
        fflush(LOG);
    }

    unsigned long long sp = (r->sp - 0x8000) & ~0xFULL;
    unsigned long long p_objs = sp;
    unsigned long long p_cnts = sp + 64 * 4;
    unsigned long long p_props = sp + 2 * 64 * 4;
    unsigned long long p_vals = sp + 2 * 64 * 4 + 2048u * 4;
    if (writeto(t, p_objs, s_objs, no * 4) ||
        writeto(t, p_cnts, s_cnts, no * 4) ||
        writeto(t, p_props, s_props2, (size_t)np * 4) ||
        writeto(t, p_vals, s_vals2, (size_t)np * 8)) {
        fprintf(LOG, "SPLIT: writeback failed (%s)\n", strerror(errno));
        fflush(LOG);
        return;
    }
    a.count_objs = no;
    a.objs_ptr = p_objs;
    a.count_props_ptr = p_cnts;
    a.props_ptr = p_props;
    a.prop_values_ptr = p_vals;
    if (writeto(t, uptr, &a, sizeof a)) {
        fprintf(LOG, "SPLIT: poke struct failed (%s)\n", strerror(errno));
        fflush(LOG);
        return;
    }
    sc_tid = t; sc_sp = sp; sc_no = no; sc_np = np;
    {   /* verify the child really holds what we poked (counts + objs) */
        static __u32 vfy[64];
        if (readmem(t, p_cnts, vfy, no * 4) < 0 ||
            memcmp(vfy, s_cnts, no * 4) ||
            readmem(t, p_objs, vfy, no * 4) < 0 ||
            memcmp(vfy, s_objs, no * 4)) {
            fprintf(LOG, "SCRATCH MISMATCH no=%u: cnts=", no);
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", vfy[i]);
            fprintf(LOG, " objs=");
            if (readmem(t, p_objs, vfy, no * 4) == (ssize_t)(no * 4))
                for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", vfy[i]);
            fprintf(LOG, " (want cnts ");
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", s_cnts[i]);
            fprintf(LOG, " objs ");
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", s_objs[i]);
            fprintf(LOG, ")\n");
            fflush(LOG);
        }
    }
    if (dpms_stripped) {
        static int nstrip;
        if (++nstrip <= 5 || (nstrip & 127) == 1) {
            fprintf(LOG, "DPMS-STRIP: 摘掉 conn%u 的 DPMS（prop=%u）"
                    "—— 本内核该属性无 ATOMIC 位，不摘整条提交会被判 EINVAL\n",
                    SPLIT_CONN, conn_dpms_strip_prop);
            fflush(LOG);
        }
        dpms_stripped = 0;
    }
    static int nsplit;
    if (++nsplit <= 5 || (nsplit & 63) == 1) {
        fprintf(LOG, "SPLIT: virt=%u objs %u->%u fb=%llu split=%d kact=%d (#%d)\n",
                virt_id, nobj, no, fb, do_split, kact, nsplit);
        fflush(LOG);
    }
}

/* Every fd the child holds that could talk to DRM — dups of the lease all
 * readlink to /dev/dri/card0, so this catches side-opens (renderD etc.). */
static void dump_drm_fds(pid_t t) {
    char dir[64];
    snprintf(dir, sizeof dir, "/proc/%d/fd", t);
    DIR *d = opendir(dir);
    if (!d) { fprintf(LOG, "FDDUMP opendir failed\n"); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[300], tgt[256];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        ssize_t n = readlink(p, tgt, sizeof tgt - 1);
        if (n <= 0) continue;
        tgt[n] = 0;
        if (strstr(tgt, "drm") || strstr(tgt, "card") || strstr(tgt, "render"))
            fprintf(LOG, "FDDUMP tid=%d fd=%s -> %s\n", t, e->d_name, tgt);
    }
    closedir(d);
    fflush(LOG);
}

/* ---- GETRESOURCES rewrite -------------------------------------------------
 * Phantom Virtual-1/2 (writeback) connectors become kwin outputs and break
 * its layer configuration. The lease experiment failed to hide them (a
 * non-master file sees through leases), so we intercept the kernel's
 * GETRESOURCES reply at the child's exit stop and repack the connector id
 * array without VIRTUAL/WRITEBACK-typed ones. Works on whatever fd kwin
 * actually enumerates with. Both passes are handled: count query (id_ptr=0)
 * and the real fetch. */
static __u32 bad_conn[16];
static int nbad_conn = -1;   /* -1 = not computed yet; >=0 = cached count */
static __u32 good_conn[32];
static int ngood_conn;

static void mark_bad_conns(void) {
    if (nbad_conn >= 0) return;
    nbad_conn = 0; ngood_conn = 0;
    drmModeRes *r = drmModeGetResources(DRMFD);
    if (!r) { nbad_conn = -1; return; }   /* retry next time */
    for (int i = 0; i < r->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(DRMFD, r->connectors[i]);
        if (!c) continue;
        if (c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
            c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK) {
            if (nbad_conn < 16) bad_conn[nbad_conn++] = c->connector_id;
            fprintf(LOG, "GETRES: marking conn %u type %u bad\n",
                    c->connector_id, c->connector_type);
        } else if (ngood_conn < 32) {
            good_conn[ngood_conn++] = c->connector_id;
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(r);
    fflush(LOG);
}

/* kwin allocated its array from OUR patched count-query reply, so we know
 * the buffer holds exactly ngood_conn slots — regenerate the reply instead
 * of repacking what the kernel wrote (it fills from the top of its own
 * unfiltered walk and may have put bad ids in a short buffer). */
static void filter_getres(pid_t t, unsigned long long uptr) {
    mark_bad_conns();
    if (nbad_conn <= 0 || ngood_conn <= 0) return;
    struct drm_mode_card_res cr;
    if (readmem(t, uptr, &cr, sizeof cr) != (ssize_t)sizeof cr) return;
    if (cr.count_connectors == 0) return;
    unsigned oldc = cr.count_connectors;
    if (cr.connector_id_ptr) {
        if (writeto(t, cr.connector_id_ptr, good_conn, ngood_conn * 4)) {
            fprintf(LOG, "GETRES: poke ids failed (%s)\n", strerror(errno));
            return;
        }
    }
    cr.count_connectors = ngood_conn;
    if (writeto(t, uptr, &cr, sizeof cr)) {
        fprintf(LOG, "GETRES: poke struct failed (%s)\n", strerror(errno));
        return;
    }
    fprintf(LOG, "GETRES: conns %u->%d [%s]\n", oldc, ngood_conn,
            cr.connector_id_ptr ? "ids" : "count-only");
    fflush(LOG);
}

/* syscall-entry work, shared by the classic all-syscall stop and the
 * seccomp-event stop. */
static void handle_entry(pid_t t, struct phase *ph) {
    struct ptregs r;
    if (getregs(t, &r)) return;
    ph->nr = r.regs[8];
    ph->sub = 0;
    if (r.regs[8] == NR_OPENAT || r.regs[8] == 437 /*openat2*/) {
        peekstr(t, r.regs[1], ph->path, sizeof ph->path);
        /* In probe/native mode kwin must get a REAL card file
         * (auto-master on first open after our DROP_MASTER);
         * dup'ing our fd would keep it forever non-master.
         * Only after the probe proved EACCES (NATIVE==0) we
         * resume the dup hijack and relay again. */
        if (HIJACK && NATIVE == 0 &&
            hijack_entry(t, &r, ph->path))
            ph->sub = 3;
    }
    if (r.regs[8] == 29 && r.regs[1] == DRM_IOCTL_MODE_GETRESOURCES) {
        fprintf(LOG, "GETRES entry tid=%d fd=%llu\n", t, r.regs[0]);
        fflush(LOG);
        if (HIJACK) ph->sub = 5;
    }
    if (r.regs[8] == 29 && r.regs[1] == DRM_IOCTL_MODE_ATOMIC) {
        ph->e_ns = nsnow();
        {
            struct drm_mode_atomic hd = { 0 };
            if (readmem(t, r.regs[2], &hd, sizeof hd) == (ssize_t)sizeof hd) {
                ph->hret = hd.flags;
                fprintf(LOG, ">>> ATOMIC tid=%d flags=0x%x nobj=%u\n",
                        t, hd.flags, hd.count_objs);
            }
            fflush(LOG);
        }
        if (NATIVE == -1 && MASTERFD >= 0) {
            /* probe: run kwin's RAW commit to learn if its fd
             * is master; do NOT split yet (would corrupt the
             * modeset probe and give a false negative) */
            nattempt++;
            dump_commit(t, r.regs[2]);
            if (nattempt == 1) dump_drm_fds(t);
            ph->sub = 6;
        } else if (NATIVE == 1) {
            struct drm_mode_atomic hd2 = { 0 };
            int have_hd = readmem(t, r.regs[2], &hd2, sizeof hd2) ==
                              (ssize_t)sizeof hd2;
            int is_test = have_hd && (hd2.flags & DRM_MODE_ATOMIC_TEST_ONLY);
            static int flipdump, applydump, s14dump;
            if (have_hd && hd2.count_objs == 14 && !is_test &&
                s14dump < 2) {
                s14dump++;
                fprintf(LOG, "--- steady flip14 #%d ---\n", s14dump);
                dump_commit(t, r.regs[2]);
            } else if (have_hd && hd2.count_objs == 15 && flipdump < 3) {
                flipdump++;
                fprintf(LOG, "--- steady %s #%d ---\n",
                        is_test ? "test" : "flip", flipdump);
                dump_commit(t, r.regs[2]);
            } else if (have_hd && hd2.count_objs == 30 && !is_test &&
                       applydump < 1) {
                applydump++;
                fprintf(LOG, "--- working apply #1 ---\n");
                dump_commit(t, r.regs[2]);
            }
            if (have_hd) {
                split_commit(t, r.regs[2], &r);
            }
            ph->sub = 2;   /* passthrough, log ret at exit */
        } else if (MASTERFD >= 0) {
            if (nattempt < 3) dump_commit(t, r.regs[2]);
            if (nattempt == 0) { dump_drm_fds(t); }
            nattempt++;
            struct drm_mode_atomic la = { 0 };
            long rr = -EINVAL;
            if (build_local_atomic(t, r.regs[2], &la) == 0)
                rr = relay_atomic(&la);
            else
                fprintf(LOG, "RELAY: build failed (%s)\n",
                        strerror(errno));
            fprintf(LOG, "RELAY tid=%d fd=%llu flags=0x%x nobjs=%u -> ret=%ld %s\n",
                    t, r.regs[0], la.flags, la.count_objs, rr,
                    rr ? strerror((int)-rr) : "OK");
            fflush(LOG);
            ph->sub = 4;
            ph->hret = rr;
            static int flip_poll_done;
            if (rr == 0 && !flip_poll_done && (la.flags & 0x1)) {
                flip_poll_done = 1;
                struct pollfd pfd = { DRMFD, POLLIN, 0 };
                int pr = poll(&pfd, 1, 2000);
                fprintf(LOG, "RELAY: flip-event poll ret=%d revents=0x%x\n",
                        pr, pr > 0 ? pfd.revents : 0);
                fflush(LOG);
            }
            struct ptregs s = r;
            s.regs[8] = ~0ULL;   /* skip: -> -ENOSYS */
            setregs(t, &s);
        } else {
            ph->sub = 2;
            dump_commit(t, r.regs[2]);
            if (FILTER) filter_commit(t, r.regs[2], &r);
        }
    }
}

int main(int argc, char **argv) {
    char *out = "/tmp/kwinwrap.log";
    int di = 1;

    /* --probe-split：只做几何发现并把结果打印成可 eval 的形式，不 exec 任何东西。
     * 设备适配层用它把 split 几何固化下来（见 core/lib/display.sh）。 */
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--probe-split")) return probe_split();

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) { out = argv[++i]; di = i + 1; }
        else if (!strcmp(argv[i], "--")) { di = i + 1; break; }
        else if (i == 1 || di == i) di = i;
    }
    if (di >= argc) {
        fprintf(stderr, "usage: kwinwrap [--out LOG] -- prog args...\n"
                        "       kwinwrap --probe-split\n");
        return 1;
    }
    LOG = fopen(out, "we");
    if (!LOG) { perror("open log"); return 1; }
    setvbuf(stderr, NULL, _IOLBF, 0);
    FILTER = getenv("KWINWRAP_FILTER") ? 1 : 0;
    SECCMODE = getenv("KWINWRAP_SECCOMP") ? 1 : 0;
    LEASE = getenv("KWINWRAP_LEASE") ? 1 : 0;
    fprintf(LOG, "kwinwrap: FILTER=%d uid=%d euid=%d\n", FILTER, getuid(), geteuid());
    { char caps[128] = ""; FILE *f = fopen("/proc/self/status", "r");
      if (f) { char ln[256]; while (fgets(ln, sizeof ln, f))
                   if (!strncmp(ln, "CapEff", 6)) { snprintf(caps, sizeof caps, "%s", ln); break; }
               fclose(f); }
      fprintf(LOG, "kwinwrap: %s", caps); fflush(LOG); }
    DRMFD = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);

    /* ★★ 这两个能力必须在 init_split() **之前**设。
     *
     * 实测（OPD2511，2026-10-12）：不设 DRM_CLIENT_CAP_UNIVERSAL_PLANES 时，
     * 本机内核的 drmModeGetPlaneResources 只返回 **14 个 Overlay(DMA) 平面**，
     * 6 个 Primary(VIG) 平面（92/123/127/131/135/139）**完全不出现**。
     * 于是平面发现只能挑到 Overlay 143/147/151/155 —— 而本面板
     * topology_name=13=sde_quadpipe_dscmerge，四管必须由 Primary 驱动，
     * 挑错类型的结果就是屏幕交织噪声。
     *
     * kmsdump 一直能列全 20 个平面，就是因为它先调了
     * drmSetClientCap(UNIVERSAL_PLANES)（见 tools/probe/kmsdump.c）。
     * 原来这里把两个 setcap 放在 init_split() 之后，发现阶段看到的是
     * legacy 平面表 —— 一个"看不见 Primary"的静默陷阱。 */
    int cap_u = -1, cap_a = -1;
    if (DRMFD >= 0) {
        cap_u = drmSetClientCap(DRMFD, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
        cap_a = drmSetClientCap(DRMFD, DRM_CLIENT_CAP_ATOMIC, 1);
    }

    /* ★ split 几何必须在拿 master 之前定下来：它决定 KEEP_OBJS 与
     *   pre-disable 的目标对象。原版这里是编译期常量（piano 的）。 */
    init_split();
    init_keep();
    fprintf(LOG, "kwinwrap: split conn=%u crtc=%u %d 段 %ux%u discovered=%d dst=%s planes=",
            SPLIT_CONN, SPLIT_CRTC, SPLIT_NSEG, SPLIT_W, SPLIT_H,
            SPLIT_DISCOVERED,
            SPLIT_DST_INTERLEAVE ? "链路内(0,800,0,800)" : "单调(0,800,1600,2400)");
    for (int i = 0; i < SPLIT_NSEG; i++)
        fprintf(LOG, "%s%u", i ? "," : "", SPLIT_PLANE[i]);
    fprintf(LOG, "\n");
    fprintf(LOG, "kwinwrap: keep=%u,%u,%u (n=%d)\n",
            KEEP_OBJS[0], KEEP_OBJS[1], KEEP_OBJS[2], NKEEP);

    HIJACK = getenv("KWINWRAP_HIJACK") ? 1 : 0;
    TRACE  = getenv("KWINWRAP_TRACE")  ? 1 : 0;
    if (TRACE)
        fprintf(LOG, "kwinwrap: KWINWRAP_TRACE=1 —— 逐帧调试痕迹已开启\n");
    if (HIJACK && DRMFD >= 0) {
        /* The FIRST open of card0 auto-becomes master when master is free
         * (drm_master_open -> drm_new_set_master), so never SET_MASTER on a
         * second fd — that is EBUSY. Claim DRMFD itself. */
        int mret = ioctl(DRMFD, DRM_SET_MASTER_REQ, 0);
        fprintf(LOG, "kwinwrap: hijack SET_MASTER on openfd %d ret=%d %s\n",
                DRMFD, mret, mret ? strerror(errno) : "OK");
        if (mret == 0 && dup2(DRMFD, HIJACK_FD) == HIJACK_FD) {
            /* dup2 clears CLOEXEC on the new fd — child inherits master */
            MASTERFD = HIJACK_FD;
            /* relayed atomics hit file_priv->atomic / universal_planes caps
             * in the kernel handler — enable them on the shared file now,
             * before kwin's first TEST_ONLY commit arrives. */
            /* 能力已在 main 开头（init_split 之前）设过 —— 这里只报结果。
             * 放在发现之后设会让发现阶段看不到 Primary 平面，见那段注释。 */
            fprintf(LOG, "kwinwrap: caps universal=%d atomic=%d\n", cap_u, cap_a);
            /* The vendor composer left the panel ON (crtc active, connector
             * linked). Its DSI bridge refuses mode changes on an active
             * panel ("seamless" path -> -22 in atomic check), and kwin's
             * per-output test commits then never pass. A normal compositor
             * starts from VT-off; emulate that with a disable commit. */
            /* ★ 原来写死 67 / 200（piano）。现在用 init_split() 发现的值。 */
            unsigned dis_conn = SPLIT_CONN, dis_crtc = SPLIT_CRTC;
            __u32 p_link = find_prop(dis_conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
            __u32 p_act  = find_prop(dis_crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE");
            __u32 p_mode = find_prop(dis_crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            if (p_link && p_act && p_mode) {
                /* target crtc = whatever conn67 is linked to NOW (composer
                 * may have restored onto a different pipe); skip the crtc
                 * disable entirely if it is already unlinked */
                unsigned cur = 0;
                drmModeObjectProperties *cp =
                    drmModeObjectGetProperties(DRMFD, dis_conn, DRM_MODE_OBJECT_CONNECTOR);
                if (cp) {
                    for (uint32_t i = 0; i < cp->count_props; i++)
                        if (cp->props[i] == p_link) { cur = (unsigned)cp->prop_values[i]; break; }
                    drmModeFreeObjectProperties(cp);
                }
                __u32 objs[2] = { dis_conn, cur };
                __u32 cnts[2] = { 1, cur ? 2u : 0u };
                __u32 prs[3]  = { p_link, p_act, p_mode };
                __u64 vs[3]   = { 0, 0, 0 };
                struct drm_mode_atomic d = {
                    .flags = DRM_MODE_ATOMIC_ALLOW_MODESET,
                    .count_objs = cur ? 2 : 1,
                    .objs_ptr = (unsigned long long)(uintptr_t)objs,
                    .count_props_ptr = (unsigned long long)(uintptr_t)cnts,
                    .props_ptr = (unsigned long long)(uintptr_t)prs,
                    .prop_values_ptr = (unsigned long long)(uintptr_t)vs,
                };
                int dr = ioctl(DRMFD, DRM_IOCTL_MODE_ATOMIC, &d);
                fprintf(LOG, "kwinwrap: pre-disable conn%u(from crtc%u) ret=%d %s\n",
                        dis_conn, cur, dr, dr ? strerror(errno) : "OK");
            } else {
                fprintf(LOG, "kwinwrap: pre-disable props %u/%u/%u not found\n",
                        p_link, p_act, p_mode);
            }
            /* ---- DRM lease ------------------------------------------------
             * Phantom Virtual-1/2 writeback connectors show up as kwin outputs
             * ("Failed to find a working output layer configuration!").
             * ★ 原版额外写死跳过 conn 33/64（piano 的虚 connector id）；
             *   类型判断（VIRTUAL/WRITEBACK）已经覆盖了这件事，
             *   写死 id 只会让换设备后漏掉/误伤。 */
            if (LEASE) {
                static __u32 lobjs[256];
                int nl = 0;
                drmModeRes *lr = drmModeGetResources(DRMFD);
                drmModePlaneRes *plr = drmModeGetPlaneResources(DRMFD);
                if (lr && plr) {
                    for (int i = 0; i < lr->count_connectors && nl < 250; i++) {
                        drmModeConnector *c = drmModeGetConnector(DRMFD, lr->connectors[i]);
                        if (!c) continue;
                        int skip = c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
                                   c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK;
                        int cid = c->connector_id, cty = c->connector_type;
                        drmModeFreeConnector(c);
                        if (skip) { fprintf(LOG, "kwinwrap: lease SKIP conn=%d type=%d\n", cid, cty); continue; }
                        lobjs[nl++] = cid;
                    }
                    for (int i = 0; i < lr->count_crtcs && nl < 250; i++) lobjs[nl++] = lr->crtcs[i];
                    /* v6.6 drm_mode_object_lease_required: only FB/CONNECTOR/
                     * PLANE/CRTC are leaseable — encoders give EINVAL. */
                    for (uint32_t i = 0; i < plr->count_planes && nl < 250; i++) lobjs[nl++] = plr->planes[i];
                } else {
                    fprintf(LOG, "kwinwrap: lease GetResources failed (%s)\n", strerror(errno));
                }
                struct drm_mode_create_lease cl = {
                    .object_ids = (unsigned long long)(uintptr_t)lobjs,
                    .object_count = nl,
                    .flags = 0,
                };
                int lret = ioctl(DRMFD, DRM_IOCTL_MODE_CREATE_LEASE, &cl);
                fprintf(LOG, "kwinwrap: lease %d objs ret=%d fd=%u lessee_id=%u %s\n",
                        nl, lret, cl.fd, cl.lessee_id, lret ? strerror(errno) : "OK");
                if (lret == 0) {
                    int lfd = (int)cl.fd;
                    RELAYFD = dup(lfd);
                    drmSetClientCap(lfd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
                    drmSetClientCap(lfd, DRM_CLIENT_CAP_ATOMIC, 1);
                    drmSetClientCap(RELAYFD, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
                    drmSetClientCap(RELAYFD, DRM_CLIENT_CAP_ATOMIC, 1);
                    if (dup2(lfd, HIJACK_FD) == HIJACK_FD) {
                        MASTERFD = HIJACK_FD;   /* child gets the LEASE, not master */
                        fprintf(LOG, "kwinwrap: HIJACK_FD=%d is lease fd, relay fd=%d\n",
                                HIJACK_FD, RELAYFD);
                        /* Does this kernel filter GetResources by lease? */
                        drmModeRes *vr = drmModeGetResources(RELAYFD);
                        if (vr) {
                            fprintf(LOG, "kwinwrap: lease view: %d conns [", vr->count_connectors);
                            for (int i = 0; i < vr->count_connectors; i++)
                                fprintf(LOG, "%d ", vr->connectors[i]);
                            fprintf(LOG, "] %d crtcs %d encs\n",
                                    vr->count_crtcs, vr->count_encoders);
                            drmModeFreeResources(vr);
                        } else fprintf(LOG, "kwinwrap: lease view GetResources failed\n");
                        drmModePlaneRes *vpr = drmModeGetPlaneResources(RELAYFD);
                        fprintf(LOG, "kwinwrap: lease planes=%u\n",
                                vpr ? vpr->count_planes : 0u);
                        if (vpr) drmModeFreePlaneResources(vpr);
                    } else {
                        fprintf(LOG, "kwinwrap: dup2 lease->%d failed (%s), stay on master\n",
                                HIJACK_FD, strerror(errno));
                        close(lfd);
                    }
                }
            }
            fflush(LOG);
        } else {
            if (mret) perror("kwinwrap: SET_MASTER failed");
            HIJACK = 0;
        }
        fflush(LOG);
    } else if (HIJACK) {
        perror("kwinwrap: card0 open failed");
        HIJACK = 0;
    }

    if (HIJACK && MASTERFD >= 0) {
        /* Android blanking writes connector brightness=0 before dying; kwin
         * never touches the SDE "brightness" prop -> panel stays black.
         * We are the only master right now, so this is the last chance to
         * write it without EACCES (KWINWRAP_BRIGHTNESS=<0..4095>). */
        /* ★ 原来写死 connector 67（piano）。改用 init_split() 发现的值。 */
        char *be = getenv("KWINWRAP_BRIGHTNESS");
        if (be && *be) {
            __u32 pid_ = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR, "brightness");
            struct drm_mode_obj_set_property sp = {
                .obj_id = SPLIT_CONN, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                .prop_id = pid_, .value = strtoull(be, NULL, 0),
            };
            int r = pid_ ? ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp) : -1;
            fprintf(LOG, "kwinwrap: brightness %s prop=%u ret=%d %s\n",
                    be, pid_, r, r ? strerror(errno) : "OK");
            fflush(LOG);
        }

        /* ★★ 把面板 connector 的 DPMS 拉回 On —— **非原子**写。
         *
         * 为什么必须在这里、且必须用非原子 ioctl（实测 2026-10-12）：
         *
         *  1) pre-disable 提交把 conn.CRTC_ID 置 0（解链接），内核随即把该
         *     connector 的 DPMS 置成 Off。KWin 之后虽然把 CRTC_ID 设回 200，
         *     但**从不提交 DPMS 属性** —— 这个 vendor KMS 不会因为 CRTC_ID
         *     由 0 变非 0 就自动把 DPMS 改回 On。结果 KWin 提交全 ret=0、
         *     亮度也写对了 2048、session.report 全绿，**面板 DPMS 停在 Off，
         *     屏幕纯黑**。
         *
         *  2) 为什么不能"往 KWin 的 atomic 提交里注入 DPMS"（试过，失败）：
         *     本内核的 DPMS 属性 **flags=0x00000008，只有 DRM_MODE_PROP_ENUM，
         *     没有 DRM_MODE_PROP_ATOMIC**。往 atomic 提交里塞它会被内核判
         *     EINVAL，反而把原本能成功的提交打成 -22（实测 23 次 -22 / 4 次 0）。
         *     ⇒ 只能走非原子 DRM_IOCTL_MODE_OBJ_SETPROPERTY，
         *       这也正是上面 brightness 那行一直在用的接口（实测 ret=0 OK）。
         *
         *  3) 为什么现在写有效：此刻 KWin 还没 exec、master 还在我们手里
         *     （下一段才 DROP_MASTER）。等 KWin 起来再写一律 EACCES ——
         *     实测 setprop 报 "set DPMS=0 -> -1 (Permission denied)"，
         *     所以 core/lib/display.sh 里的 drm_force_display_on 救不了黑屏。 */
        __u32 dpms_prop = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
        if (dpms_prop) {
            struct drm_mode_obj_set_property dp = {
                .obj_id = SPLIT_CONN, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                .prop_id = dpms_prop, .value = 0,   /* DRM_MODE_DPMS_ON == 0 */
            };
            errno = 0;
            int dr = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &dp);
            fprintf(LOG, "kwinwrap: DPMS=On(conn%u prop=%u) ret=%d %s\n",
                    SPLIT_CONN, dpms_prop, dr, dr ? strerror(errno) : "OK");
            fflush(LOG);
        } else {
            fprintf(LOG, "kwinwrap: 找不到 conn%u 的 DPMS 属性\n", SPLIT_CONN);
            fflush(LOG);
        }

        /* ── DSC（Display Stream Compression）开关 ─────────────────────
         * 本机面板是 **DSC 面板**：
         *   - 内核 cmdline: msm_drm.dsi_display0=qcom,mdss_dsi_nt36532_wqhd_dual_dsi_dsc_vid
         *   - conn67 的 topology_name = 13 = sde_quadpipe_dscmerge（只读，驱动定）
         * 接管时 conn67 的 dsc_mode 停在 0(none)：DSI 链路按**未压缩**送数据，
         * 面板却按 DSC 解 → 满屏细密横条纹 + 彩虹色偏（实测照片，看不出任何图形）。
         *
         * dsc_mode 与 DPMS 一样 **flags 里没有 DRM_MODE_PROP_ATOMIC**，
         * 所以只能走非原子 DRM_IOCTL_MODE_OBJ_SETPROPERTY，
         * 且必须赶在 DROP_MASTER 之前（之后一律 EACCES）。
         *
         * ★★ 顺序至关重要：必须"面板断电 → 设 dsc_mode → 面板上电" ★★
         *
         *   实测踩坑（2026-10-12）：原来是在上面那段 `DPMS=On` **之后**才设
         *   dsc_mode —— 顺序反了。面板已经上电、DSI 链路已按**未压缩**建好，
         *   此时再改 dsc_mode 只是改了个属性值，**不会触发链路重建**。
         *   于是现象照旧：fbdump 读出来的缓冲是**完整正确的 KDE 桌面**
         *   （采样点全是蓝色壁纸的正确 RGB），物理面板却是彩色噪声。
         *
         *   更隐蔽的一点：kwinwrap 选中的 mode 与 Android 基线**完全相同**
         *   （3200x2000x120vid）⇒ KWin 随后的 modeset 是**无操作**，
         *   内核不会因为"模式没变"而重建 DSI 链路。所以**不能指望
         *   KWin 的 modeset 去把 DSC 建起来**，必须自己先把链路弄成
         *   "需要重建"的状态：显式 DPMS=Off，设完 dsc_mode 再 DPMS=On。
         *   （DPMS 走非原子 ioctl，不需要 modeset 权限，实测 ret=0。）
         *
         * KWINWRAP_NO_DSC=1 可关掉（对照实验用）。 */
        if (!getenv("KWINWRAP_NO_DSC")) {
            __u32 dsc_prop = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR,
                                       "dsc_mode");
            __u32 dpms_for_dsc = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR,
                                           "DPMS");
            if (dsc_prop) {
                /* ① 先断电，让链路处于"待重建"状态 */
                if (dpms_for_dsc) {
                    struct drm_mode_obj_set_property off = {
                        .obj_id = SPLIT_CONN, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                        .prop_id = dpms_for_dsc, .value = 3,  /* DRM_MODE_DPMS_OFF */
                    };
                    errno = 0;
                    int or_ = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &off);
                    fprintf(LOG, "kwinwrap: DSC 前置 DPMS=Off(prop=%u) ret=%d %s\n",
                            dpms_for_dsc, or_, or_ ? strerror(errno) : "OK");
                }
                /* ② 面板熄着的时候告诉它"要收 DSC"，并设置每分量位深。
                 *
                 * ★ bpp_mode 为什么必须一起设：面板驱动是
                 *   qcom,mdss_dsi_nt36532_wqhd_dual_dsi_dsc_vid（双 DSI + DSC），
                 *   而本机缓冲是 **10 位 AR30**。实测接管后 bpp_mode 停在
                 *   0(none) —— 若 DSC 编码器按 8bpc 编码而面板按 10bpc 解，
                 *   解出来就是彩色噪声。所以这里跟 dsc_mode 一起设成
                 *   dsi_30bpp(2)，与 10 位缓冲对齐。
                 *   （enum: none=0, dsi_24bpp=1, dsi_30bpp=2）
                 *   可用 KWINWRAP_BPP_MODE 覆盖做对照实验；设成 none 可跳过。 */
                struct drm_mode_obj_set_property dq = {
                    .obj_id = SPLIT_CONN, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                    .prop_id = dsc_prop, .value = 1,   /* dsc_enabled */
                };
                errno = 0;
                int qr = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &dq);
                fprintf(LOG, "kwinwrap: DSC=dsc_enabled(conn%u prop=%u) ret=%d %s\n",
                        SPLIT_CONN, dsc_prop, qr, qr ? strerror(errno) : "OK");

                {
                    const char *be = getenv("KWINWRAP_BPP_MODE");
                    if (!be || strcmp(be, "none")) {
                        unsigned long bv = be ? strtoul(be, NULL, 0) : 2UL; /* dsi_30bpp */
                        __u32 bp = find_prop(SPLIT_CONN, DRM_MODE_OBJECT_CONNECTOR,
                                             "bpp_mode");
                        if (bp) {
                            struct drm_mode_obj_set_property bq = {
                                .obj_id = SPLIT_CONN,
                                .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                                .prop_id = bp, .value = bv,
                            };
                            errno = 0;
                            int br = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &bq);
                            fprintf(LOG, "kwinwrap: DSC bpp_mode=%lu(conn%u prop=%u) ret=%d %s\n",
                                    bv, SPLIT_CONN, bp, br, br ? strerror(errno) : "OK");
                        } else {
                            fprintf(LOG, "kwinwrap: 找不到 conn%u 的 bpp_mode 属性\n",
                                    SPLIT_CONN);
                        }
                    } else {
                        fprintf(LOG, "kwinwrap: KWINWRAP_BPP_MODE=none —— 不设 bpp_mode\n");
                    }
                }
                /* ③ 再上电 —— 这一次链路会带上 DSC 重建 */
                if (dpms_for_dsc) {
                    struct drm_mode_obj_set_property on = {
                        .obj_id = SPLIT_CONN, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                        .prop_id = dpms_for_dsc, .value = 0,  /* DRM_MODE_DPMS_ON */
                    };
                    errno = 0;
                    int nr = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &on);
                    fprintf(LOG, "kwinwrap: DSC 后置 DPMS=On(prop=%u) ret=%d %s\n",
                            dpms_for_dsc, nr, nr ? strerror(errno) : "OK");
                }
                fflush(LOG);
            } else {
                fprintf(LOG, "kwinwrap: 找不到 conn%u 的 dsc_mode 属性\n",
                        SPLIT_CONN);
                fflush(LOG);
            }
        } else {
            fprintf(LOG, "kwinwrap: KWINWRAP_NO_DSC=1 —— 跳过 DSC 设置（对照实验）\n");
            fflush(LOG);
        }

        /* ── 平面级"非 ATOMIC"属性：blend_op / alpha / zpos / rotation ────
         * ★ 实测对比 Android（kmsdump 读 PLANE 131/127/123/92 的全部属性）：
         *   Android 每个 Primary 平面都**显式设了这 4 个**，我们原来一个都没设：
         *       blend_op id=102 = 1 (opaque)        我们 0 = not_defined
         *       alpha    id=95  = 255               我们 0 = **全透明**
         *       zpos     id=94  = 0
         *       rotation id=133 = 1 (ROTATE_0)      我们 0 = 未定义
         *
         *   这 4 个的 flags 里**都没有 DRM_MODE_PROP_ATOMIC**
         *   （kmsdump 显示 flags=DRM_MODE_PROP_RANGE / ENUM / BITMASK），
         *   所以塞进 atomic 提交会被内核判 EINVAL —— 只能像 DPMS/dsc_mode
         *   那样走非原子 DRM_IOCTL_MODE_OBJ_SETPROPERTY，且必须赶在
         *   DROP_MASTER 之前（之后一律 EACCES）。
         *
         *   关于旧记录里"4 平面 + 单调坐标 → 约 20s 后内核 panic"：那条归因
         *   建立在"目的坐标 1600~3200 超出单条链路本地地址范围"这个**误判**上
         *   （见文件头：kmsdump 读回的是驱动减完 1600 的值，不是提交值）。
         *   驱动源码证明全局坐标才是正确输入。KWINWRAP_NO_PLANE_PROPS=1
         *   仍可关掉这组属性做对照，但 alpha=0（全透明）本来就必须补上。 */
        if (!getenv("KWINWRAP_NO_PLANE_PROPS")) {
            static const struct { const char *n; __u64 v; } pprops[] = {
                { "blend_op", 1u },     /* opaque */
                { "alpha",    255u },
                /* ★ zpos 不在这里 —— 它按段索引算，见下面 split_zpos()。
                 *   原来这里硬写 0：4 条平面同 zpos ⇒ 同 stage，配合当时的
                 *   链路内 CRTC_X，_sde_crtc_validate_src_split_order 会把它们
                 *   排成 0,0,800,800 并配成 (0,0)/(800,800) ⇒ 全被拒。
                 *   （安卓也是 zpos 全 0，但它的 CRTC_X 是全局坐标，减完 1600
                 *    后同一 stage 内按 layout 分成两组，各自 0/800 才成立。） */
                { "rotation", 1u },     /* DRM_MODE_ROTATE_0（bit0），不是"转 90°" */
            };
            for (int s = 0; s < SPLIT_NSEG; s++) {
                for (unsigned k = 0; k < sizeof pprops / sizeof pprops[0]; k++) {
                    __u32 pp = find_prop(SPLIT_PLANE[s], DRM_MODE_OBJECT_PLANE,
                                         pprops[k].n);
                    if (!pp) {
                        fprintf(LOG, "kwinwrap: plane%u 没有 %s 属性\n",
                                SPLIT_PLANE[s], pprops[k].n);
                        continue;
                    }
                    struct drm_mode_obj_set_property pq = {
                        .obj_id   = SPLIT_PLANE[s],
                        .obj_type = DRM_MODE_OBJECT_PLANE,
                        .prop_id  = pp,
                        .value    = pprops[k].v,
                    };
                    errno = 0;
                    int pr = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &pq);
                    fprintf(LOG, "kwinwrap: plane%u %s=%llu ret=%d %s\n",
                            SPLIT_PLANE[s], pprops[k].n,
                            (unsigned long long)pprops[k].v, pr,
                            pr ? strerror(errno) : "OK");
                }

                /* ── zpos：SDE stage 分组的关键（KWINWRAP_SPLIT_ZPOS）─────
                 * 模式 1：zpos = s/2 —— 每 2 段共用一个 stage，正好对应
                 *         "双 DSI 每条链路 2 管"：
                 *             s=0,1 → zpos 0（链路0: 131 dst0-800 + 127 dst800-1600）
                 *             s=2,3 → zpos 1（链路1: 123 dst0-800 + 92  dst800-1600）
                 *         这样 stage0 内按 CRTC_X 排序得 0,800 → 左<右 ✓
                 * 模式 2：zpos = s —— 每段独立 stage。 */
                if (SPLIT_ZPOS_MODE) {
                    unsigned zv;
                    if (SPLIT_ZPOS_MODE == 1)      zv = (unsigned)(s / 2);
                    else if (SPLIT_ZPOS_MODE == 3) zv = 0u;   /* 单一图层 */
                    else if (SPLIT_ZPOS_MODE == 4)            /* 反转配对 */
                        zv = (unsigned)((SPLIT_NSEG - 1 - s) / 2);
                    else if (SPLIT_ZPOS_MODE == 5)            /* ★ 严格对齐安卓 */
                        zv = (unsigned)(SPLIT_NSEG - 1 - s);
                    else                           zv = (unsigned)s;
                    __u32 pz = find_prop(SPLIT_PLANE[s], DRM_MODE_OBJECT_PLANE,
                                         "zpos");
                    if (pz) {
                        struct drm_mode_obj_set_property zq = {
                            .obj_id   = SPLIT_PLANE[s],
                            .obj_type = DRM_MODE_OBJECT_PLANE,
                            .prop_id  = pz,
                            .value    = zv,
                        };
                        errno = 0;
                        int zr = ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &zq);
                        fprintf(LOG, "kwinwrap: plane%u zpos=%u(模式%d) ret=%d %s\n",
                                SPLIT_PLANE[s], zv, SPLIT_ZPOS_MODE, zr,
                                zr ? strerror(errno) : "OK");
                    } else {
                        fprintf(LOG, "kwinwrap: plane%u 没有 zpos 属性\n", SPLIT_PLANE[s]);
                    }
                }
            }
            fflush(LOG);
        } else {
            fprintf(LOG, "kwinwrap: KWINWRAP_NO_PLANE_PROPS=1 —— 跳过平面属性设置（对照实验）\n");
            fflush(LOG);
        }
    }

    if (HIJACK && MASTERFD >= 0 && !LEASE) {
        /* Hand DRM to kwin natively: release our master so kwin's first REAL
         * open of card0 auto-becomes master (first-opener rule, cf. uid1000
         * SETMASTER probe). Relay remains only as probe-failure fallback. */
        int dret = ioctl(DRMFD, DRM_DROP_MASTER_REQ, 0);
        fprintf(LOG, "kwinwrap: DROP_MASTER ret=%d %s\n",
                dret, dret ? strerror(errno) : "OK");
        fflush(LOG);
    }

    pid_t child = fork();
    if (child == 0) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL)) { perror("traceme"); _exit(2); }
        if (SECCMODE && install_drm_filter()) {
            fprintf(stderr, "kwinwrap: seccomp install failed (%s)\n",
                    strerror(errno));
            _exit(4);
        }
        char *u = getenv("KWINWRAP_UID");
        char *g = getenv("KWINWRAP_GID");
        if (u && g) {
            /* ★★ 必须补上附加组，不能只 setgid() ★★
             *
             * 实测踩坑（2026-10-12）：原来这里只有 `setgid(g); setuid(u);`。
             * setgid() 只设**主组**，不会去读 /etc/group 加载附加组 ⇒
             * 子进程的 `Groups:` 是**空的**（/proc/<pid>/status 实测）：
             *     Uid: 1000  Gid: 1000  Groups: (空)
             * 而本机 /dev/input/event* 是 `crw-rw---- root:input`，
             * 桌面账号 Gold 本来就在 input 组（/etc/group: input:x:996:root,Gold）
             * —— 附加组一丢，KWin 就打不开这些节点。
             *
             * 现象正是这样：KWin 只打开了触摸屏 event5（那个节点恰好
             * 权限允许），**电源键 pmic_pwrkey(event3) / gpio-keys(event0) /
             * hall_irq(event2) 全部没打开** ⇒ 电源键不能开关屏幕。
             *
             * ★ 为什么不用 initgroups()/getpwuid()：实测在本容器里
             *   getpwuid() 直接返回 NULL，errno=ENOSYS("Function not
             *   implemented") —— NSS 后端在这个精简容器里不可用。
             *   所以这里**自己解析 /etc/group**，完全不依赖 NSS。
             *
             * 顺序要紧：setgroups() 需要 root，**必须在 setuid() 之前**。 */
            uid_t uid = (uid_t)atoi(u);
            gid_t gid = (gid_t)atoi(g);
            /* 用户名：优先用环境变量；没有就从 /etc/passwd 按 uid 查
             *（同样不依赖 NSS，getpwuid 在本容器里是 ENOSYS）。 */
            char ubuf[64];
            const char *uname = getenv("KWINWRAP_USER");
            if (!uname || !*uname) {
                uname = NULL;
                FILE *pf = fopen("/etc/passwd", "re");
                if (pf) {
                    char line[1024];
                    while (fgets(line, sizeof line, pf)) {
                        /* name:x:uid:gid:... */
                        char *c1 = strchr(line, ':');
                        if (!c1) continue;
                        char *c2 = strchr(c1 + 1, ':');
                        if (!c2) continue;
                        if ((uid_t)atoi(c2 + 1) == uid) {
                            size_t L = (size_t)(c1 - line);
                            if (L < sizeof ubuf) {
                                memcpy(ubuf, line, L);
                                ubuf[L] = 0;
                                uname = ubuf;
                            }
                            break;
                        }
                    }
                    fclose(pf);
                }
                if (!uname) uname = "Gold";
            }

            /* ★ 组列表来源有优先级，因为 kwinwrap 跑在**宿主**侧：
             *   它读到的 /etc/group 是 Android 宿主的，里面根本没有
             *   容器桌面账号 Gold ⇒ 自己解析 /etc/group 这条路在宿主上
             *   必然失败（实测：setgroups OK —— 1 个组: 1000，而容器里
             *   `id Gold` 明明有 9 个组，含 996(input)）。
             *   所以首选 display.sh 从**容器内**算好的 KWINWRAP_GROUPS
             *   （逗号/空格分隔的 gid 列表）。其次才退回解析 /etc/group。 */
            gid_t gs[64];
            int ngs = 0;
            gs[ngs++] = gid;                 /* 主组一定要在列表里 */
            const char *glist = getenv("KWINWRAP_GROUPS");
            if (glist && *glist) {
                const char *p = glist;
                while (*p && ngs < 64) {
                    while (*p == ',' || *p == ' ' || *p == '\t') p++;
                    if (!*p) break;
                    char *end = NULL;
                    long v = strtol(p, &end, 10);
                    if (end == p) break;
                    gid_t eg = (gid_t)v;
                    int dup = 0;
                    for (int i = 0; i < ngs; i++) if (gs[i] == eg) dup = 1;
                    if (!dup) gs[ngs++] = eg;
                    p = end;
                }
                fprintf(LOG, "kwinwrap: 组列表来自 KWINWRAP_GROUPS=%s\n", glist);
            } else {
            FILE *gf = fopen("/etc/group", "re");
            if (gf) {
                char line[1024];
                while (fgets(line, sizeof line, gf) && ngs < 64) {
                    /* 格式：name:x:gid:member1,member2 */
                    char *c1 = strchr(line, ':');
                    if (!c1) continue;
                    char *c2 = strchr(c1 + 1, ':');
                    if (!c2) continue;
                    char *c3 = strchr(c2 + 1, ':');
                    if (!c3) continue;
                    gid_t eg = (gid_t)atoi(c2 + 1);
                    /* 在成员列表里按"整名匹配"找（避免 Gold 命中 GoldX） */
                    char *m = c3 + 1;
                    int found = 0;
                    while (*m) {
                        while (*m == ',' || *m == ' ' || *m == '\t' || *m == '\n')
                            m++;
                        if (!*m) break;
                        char *e = m;
                        while (*e && *e != ',' && *e != '\n' && *e != ' ' && *e != '\t')
                            e++;
                        size_t L = (size_t)(e - m);
                        if (L == strlen(uname) && !strncmp(m, uname, L)) { found = 1; break; }
                        m = e;
                    }
                    if (found) {
                        int dup = 0;
                        for (int i = 0; i < ngs; i++) if (gs[i] == eg) dup = 1;
                        if (!dup) gs[ngs++] = eg;
                    }
                }
                fclose(gf);
            }
            }
            if (setgroups((size_t)ngs, gs) != 0)
                fprintf(LOG, "kwinwrap: setgroups(%d 个) 失败: %s\n", ngs, strerror(errno));
            else {
                fprintf(LOG, "kwinwrap: setgroups OK —— %d 个组:", ngs);
                for (int i = 0; i < ngs; i++) fprintf(LOG, " %u", (unsigned)gs[i]);
                fprintf(LOG, "\n");
            }

            if (setgid(gid) != 0)
                fprintf(LOG, "kwinwrap: setgid(%u) 失败: %s\n",
                        (unsigned)gid, strerror(errno));
            if (setuid(uid) != 0)
                fprintf(LOG, "kwinwrap: setuid(%u) 失败: %s\n",
                        (unsigned)uid, strerror(errno));
            fflush(LOG);
        }
        execvp(argv[di], argv + di);
        perror("execvp");
        _exit(3);
    }

    int status;
    waitpid(child, &status, 0);
    ptrace(PTRACE_SETOPTIONS, child, NULL,
           (void *)(long)(PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE |
                          PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
                          PTRACE_O_EXITKILL |
                          /* RET_TRACE events are silently downgraded to
                           * -ENOSYS unless the tracer asked for them: */
                          (SECCMODE ? (1 << PTRACE_EVENT_SECCOMP) : 0)));
    phases[nphase++] = (struct phase){ child, 0 };
    ptrace(PTRACE_SYSCALL, child, NULL, NULL);

    for (;;) {
        pid_t t = waitpid(-1, &status, __WALL);
        if (t < 0) { if (errno == EINTR) continue; break; }
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            if (t == child) { fprintf(LOG, "child gone status=%d\n", status); fflush(LOG); break; }
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { phases[i] = phases[--nphase]; break; }
            continue;
        }
        if (WIFSTOPPED(status) &&
            (status >> 8) == (SIGTRAP | (PTRACE_EVENT_SECCOMP << 8))) {
            /* seccomp RET_TRACE entry stop: only the syscalls we care about
             * get here.  Run the entry handler, then arm exactly the
             * matching exit stop with one PTRACE_SYSCALL. */
            struct phase *ph = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph = &phases[i]; break; }
            if (!ph && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph = &phases[nphase - 1];
            }
            if (ph) {
                handle_entry(t, ph);
                ph->p = 1;
                ptrace(PTRACE_SYSCALL, t, NULL, NULL);
            } else {
                ptrace(PTRACE_CONT, t, NULL, NULL);
            }
            continue;
        }
        if (WIFSTOPPED(status) && (status >> 8) == (SIGTRAP | 0x80)) {
            /* syscall-stop */
            struct phase *ph = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph = &phases[i]; break; }
            if (!ph && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph = &phases[nphase - 1];
            }
            int dir = syscall_dir(t);
            int entry = dir ? dir == 1 : (ph && ph->p == 0);
            int exity = dir ? dir == 2 : (ph && ph->p == 1);
            if (ph && entry) {
                handle_entry(t, ph);
            } else if (ph && exity && ph->sub == 6 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    long long own = (long long)r.regs[0];
                    fprintf(LOG, "PROBE tid=%d fd=%llu own=%lld %s\n",
                            t, r.regs[0], own, own ? strerror((int)-own) : "OK");
                    fflush(LOG);
                    /* Only EACCES proves "not master". TEST_ONLY commits
                     * legitimately fail (-22/-2) while still EXECUTING on
                     * kwin's master fd — treat anything else as native. */
                    if (own != -EACCES) {
                        NATIVE = 1;
                        fprintf(LOG, ">>> kwin is native master: passthrough\n");
                    } else {
                        NATIVE = 0;
                        int mr = ioctl(DRMFD, DRM_SET_MASTER_REQ, 0);
                        fprintf(LOG, ">>> re-SETMASTER ret=%d %s; relaying\n",
                                mr, mr ? strerror(errno) : "OK");
                        struct drm_mode_atomic la = { 0 };
                        long rr = -EINVAL;
                        if (build_local_atomic(t, r.regs[2], &la) == 0)
                            rr = relay_atomic(&la);
                        fprintf(LOG, "PROBE-RELAY flags=0x%x nobjs=%u -> ret=%ld %s\n",
                                la.flags, la.count_objs, rr,
                                rr ? strerror((int)-rr) : "OK");
                        r.regs[0] = (unsigned long long)rr;
                        setregs(t, &r);
                    }
                    fflush(LOG);
                }
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 5 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0 && (long long)r.regs[0] == 0)
                    filter_getres(t, r.regs[2]);
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 3) {
                struct ptregs r;
                if (getregs(t, &r) == 0)
                    log_hijack_result(t, (long long)r.regs[0]);
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 4 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    long long own = (long long)r.regs[0];
                    r.regs[0] = (unsigned long long)ph->hret;
                    setregs(t, &r);
                    fprintf(LOG, "<<< ATOMIC tid=%d own=%lld relay=%lld injected\n",
                            t, own, ph->hret);
                    fflush(LOG);
                }
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 2 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    static long long last_commit_ns;
                    long long now = nsnow();
                    long long dt_us = last_commit_ns ?
                        (now - last_commit_ns) / 1000 : 0;
                    long long exec_us = ph->e_ns ? (now - ph->e_ns) / 1000 : 0;
                    if (r.regs[0] == 0) last_commit_ns = now;
                    fprintf(LOG, "<<< ATOMIC tid=%d f=0x%llx ret=%lld dt=%lldus exec=%lldus%s\n",
                            t, (unsigned long long)ph->hret, (long long)r.regs[0],
                            dt_us, exec_us,
                            (long long)r.regs[0] < 0
                                ? strerror((int)-(long long)r.regs[0]) : "");
                    if ((long long)r.regs[0] == -2 && sc_dumped < 12 &&
                        sc_no && t == sc_tid) {
                        sc_dumped++;
                        __u32 dno = sc_no > 60 ? 60 : sc_no;
                        __u32 dnp = sc_np > 240 ? 240 : sc_np;
                        __u32 do_[64], dc[64], dp[240];
                        int ok = readmem(t, sc_sp, do_, dno * 4) >= 0 &&
                                 readmem(t, sc_sp + 256, dc, dno * 4) >= 0 &&
                                 readmem(t, sc_sp + 512, dp, dnp * 4) >= 0;
                        fprintf(LOG, "SCRATCH-DUMP #%d tid=%d ok=%d objs=", sc_dumped, t, ok);
                        for (__u32 i = 0; i < dno; i++) fprintf(LOG, "%u,", do_[i]);
                        fprintf(LOG, " cnts=");
                        for (__u32 i = 0; i < dno; i++) fprintf(LOG, "%u,", dc[i]);
                        fprintf(LOG, " props=");
                        for (__u32 i = 0; i < dnp; i++) fprintf(LOG, "%u,", dp[i]);
                        fprintf(LOG, "\n");
                    }
                    fflush(LOG);
                    ph->sub = 0;
                }
            } else if (ph && exity && (ph->nr == NR_OPENAT || ph->nr == 437)) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    if ((long long)r.regs[0] >= 0) {
                        log_card_open(t, (long)r.regs[0], ph->path);
                        if (HIJACK && !ph->path[0]) {
                            /* path unreadable — did the child really open a
                             * DRM node (unmastered file = future -13s)? */
                            char lnk[128] = "", procl[64];
                            snprintf(procl, sizeof procl, "/proc/%d/fd/%lld",
                                     t, (long long)r.regs[0]);
                            int n = readlink(procl, lnk, sizeof lnk - 1);
                            if (n > 0 && (strstr(lnk, "card") ||
                                          strstr(lnk, "render")))
                                fprintf(LOG, "REALOPEN tid=%d fd=%lld -> %s\n",
                                        t, (long long)r.regs[0], lnk);
                            fflush(LOG);
                        }
                    } else if (strstr(ph->path, "card")) {
                        fprintf(LOG, "openat FAIL tid=%d %s ret=%lld\n",
                                t, ph->path, (long long)r.regs[0]);
                        fflush(LOG);
                    }
                }
            }
            if (SECCMODE) {
                if (ph && exity) ph->p = 0;
                ptrace(ph && exity ? PTRACE_CONT : PTRACE_SYSCALL,
                       t, NULL, NULL);
            } else {
                if (ph) ph->p ^= 1;
                ptrace(PTRACE_SYSCALL, t, NULL, NULL);
            }
            continue;
        }
        if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP) {
            /* ptrace event or group-stop: register tid, continue quietly.
             * In seccomp mode only re-arm a syscall-stop when an exit stop
             * is already pending; arming fresh would confuse entry/exit
             * pairing with the seccomp events. */
            struct phase *ph2 = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph2 = &phases[i]; break; }
            if (!ph2 && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph2 = &phases[nphase - 1];
            }
            int arm = !SECCMODE || (ph2 && ph2->p == 1);
            ptrace(arm ? PTRACE_SYSCALL : PTRACE_CONT, t, NULL, NULL);
            continue;
        }
        /* any other signal-stop: forward unchanged, keeping an armed
         * exit-stop pending if the signal interrupted a trapped syscall */
        {
            struct phase *ph2 = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph2 = &phases[i]; break; }
            int arm = !SECCMODE || (ph2 && ph2->p == 1);
            ptrace(arm ? PTRACE_SYSCALL : PTRACE_CONT, t, NULL,
                   (void *)(long)WSTOPSIG(status));
        }
    }
    return 0;
}

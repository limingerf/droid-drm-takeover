/* atomic-spy: ptrace-attach a pid, print every DRM_IOCTL_MODE_ATOMIC's
 * struct contents (objects, per-object prop counts, prop ids + values).
 * aarch64 only. Run: ./atomic-spy <pid> [seconds] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <linux/ptrace.h>
#include <signal.h>
#include <stdint.h>

#define ATOMIC_IOC 0xC03864A9u  /* _IOWR('d', 0xa9, struct drm_mode_atomic [56B]) */
#define SYS_IOCTL  29

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint64_t rd8(pid_t tid, unsigned long addr) {
    struct iovec loc = { (void *)addr, 8 };
    uint64_t v;
    ssize_t n = ptrace(PTRACE_PEEKDATA, tid, (void *)addr, NULL);
    if (n == -1 && errno) return (uint64_t)-1;
    v = (uint64_t)n; (void)loc;
    return v;
}
static uint32_t rd4(pid_t tid, unsigned long addr) {
    uint64_t w = rd8(tid, addr & ~7UL);
    if (w == (uint64_t)-1) return 0xFFFFFFFF;
    return (uint32_t)(w >> ((addr & 7) * 8));
}

static void dump_atomic(pid_t tid, unsigned long up) {
    uint32_t flags = rd4(tid, up + 0);
    uint32_t count_objs = rd4(tid, up + 4);
    uint64_t objs_ptr = rd8(tid, up + 8);
    uint64_t cntp_ptr = rd8(tid, up + 16);
    uint64_t props_ptr = rd8(tid, up + 24);
    uint64_t vals_ptr = rd8(tid, up + 32);
    printf("== ATOMIC tid %d flags 0x%x objs %u\n", tid, flags, count_objs);
    if (count_objs > 64 || !objs_ptr) { printf("   (bogus, skip)\n"); fflush(stdout); return; }
    uint32_t pidx = 0;
    for (uint32_t i = 0; i < count_objs; i++) {
        uint32_t obj = rd4(tid, objs_ptr + 4 * i);
        uint32_t cnt = cntp_ptr ? rd4(tid, cntp_ptr + 4 * i) : 0;
        printf("   obj %5u: %u props\n", obj, cnt);
        for (uint32_t j = 0; j < cnt && j < 40; j++, pidx++) {
            uint32_t pid = rd4(tid, props_ptr + 4 * pidx);
            uint64_t val = rd8(tid, vals_ptr + 8 * pidx);
            printf("      prop %3u = 0x%llx (%llu)\n", pid,
                   (unsigned long long)val, (unsigned long long)val);
        }
    }
    fflush(stdout);
}

static long g_nstop, g_nregfail = -1;
static unsigned g_syct[64];

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s pid [secs]\n", argv[0]); return 1; }
    pid_t target = atoi(argv[1]);
    double deadline = now_s() + (argc > 2 ? atof(argv[2]) : 5.0);

    char path[256];
    snprintf(path, sizeof path, "/proc/%d/task", target);
    DIR *d = opendir(path);
    if (!d) { perror("opendir task"); return 2; }
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        pid_t tid = atoi(de->d_name);
        if (ptrace(PTRACE_ATTACH, tid, NULL, NULL)) {
            fprintf(stderr, "attach %d: %s\n", tid, strerror(errno));
            continue;
        }
        waitpid(tid, NULL, __WALL);
        ptrace(PTRACE_SETOPTIONS, tid, NULL, 0);
        ptrace(PTRACE_SYSCALL, tid, NULL, 0);
    }
    closedir(d);
    printf("attached, watching %.0fs\n", deadline - now_s());
    fflush(stdout);

    while (now_s() < deadline) {
        int status;
        pid_t tid = waitpid(-1, &status, __WALL);
        if (tid < 0) { if (errno == EINTR) continue; break; }
        if (WIFEXITED(status) || WIFSIGNALED(status)) continue;
        if (WIFSTOPPED(status)) {
            int sig = WSTOPSIG(status);
            if (++g_nstop <= 5) printf("stop tid %d sig %d\n", tid, sig), fflush(stdout);
            if (sig == (SIGTRAP | 0x80) || sig == SIGTRAP) {
                struct user_pt_regs r;
                struct iovec io = { &r, sizeof r };
                if (ptrace(PTRACE_GETREGSET, tid, (void *)1 /*NT_PRSTATUS*/, &io)) {
                    if (g_nregfail < 0) { g_nregfail = errno;
                        printf("GETREGSET failed tid %d: %s\n", tid, strerror(errno));
                        fflush(stdout); }
                } else {
                    g_syct[r.regs[7] % 64]++;
                    static long seen[40];
                    static int nseen;
                    if (r.regs[7] == SYS_IOCTL) {
                        unsigned cmd = (unsigned)r.regs[1];
                        int known = 0;
                        for (int k = 0; k < nseen; k++)
                            if (seen[k] == (long)cmd) { known++; }
                        if (!known && nseen < 40) {
                            printf("ioctl cmd 0x%08x fd %lld\n", cmd,
                                   (long long)r.regs[0]);
                            fflush(stdout);
                            seen[nseen++] = cmd;
                        }
                        if (cmd == ATOMIC_IOC)
                            dump_atomic(tid, r.regs[2]);
                    }
                }
                ptrace(PTRACE_SYSCALL, tid, NULL, 0);
                continue;
            }
            ptrace(PTRACE_SYSCALL, tid, NULL, sig); /* forward other signals */
            continue;
        }
        ptrace(PTRACE_SYSCALL, tid, NULL, 0);
    }
    {
        printf("stops %ld regfail %d\n", g_nstop, g_nregfail < 0 ? 0 : (int)g_nregfail);
        for (int k = 0; k < 64; k++) if (g_syct[k]) printf("  syscall %d x %u\n", k, g_syct[k]);
        printf("detaching\n");}
    d = opendir(path);
    if (d) { while ((de = readdir(d))) {
                if (de->d_name[0] == '.') continue;
                ptrace(PTRACE_DETACH, atoi(de->d_name), NULL, 0); }
              closedir(d); }
    return 0;
}

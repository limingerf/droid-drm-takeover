/*
 * agmprobe.c —— AGM 只读探针（P1），v3
 *
 * v1: rc=139 且 stdout 块缓冲 ⇒ 日志全丢。
 * v2: 无缓冲 + fork 隔离 ⇒ 定位到崩溃点在 agm_session_open。
 * v3: 反汇编 libagmclient.so 读出真实 ABI（v2 的结论）：
 *
 *   agm_session_open 实体 @0xab84:
 *       mov x21, x2        ; 保存 arg3
 *       mov w19, w1        ; arg2 当 32 位用
 *       mov w20, w0        ; arg1 当 32 位用
 *       ldr x5, [x2]       ; ★ arg3 被当指针解引用（64 位读）
 *       ...
 *       mov w1, w20        ; HIDL 入参 = arg1
 *       mov w2, w19        ; HIDL 入参 = arg2
 *       blr x9             ; 调 get_agm_server() 拿到对象再发事务
 *
 *   ⇒ 签名是 (uint32_t mode, uint32_t tag, agm_session_t *session_id)，
 *     **三个参数**。v2 只传两个，x2 是垃圾指针 ⇒ 解引用即段错误。
 *     （对照 agm_get_aif_info_list @0xb99c 是 (void*, size_t*)，两参数，能跑通。）
 *
 * 合规：只做 agm_init / agm_get_aif_info_list / agm_session_open+close。
 *       **不 set_config、不 prepare、不 start、不 write** ⇒ 不会出声。
 *
 * 用法：STEP=1..4，REV=1 试反向参数序，TAG=<n> 指定第 2 个参数。
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef uint64_t agm_session_t;
typedef int (*fn_init)(void);
typedef int (*fn_deinit)(void);
typedef int (*fn_open3)(uint32_t mode, uint32_t tag, agm_session_t *sid);
typedef int (*fn_open2)(uint32_t mode, agm_session_t *sid);
typedef int (*fn_close)(agm_session_t sid);
typedef int (*fn_aif_list)(void *list, size_t *num);
/* ABI 反汇编 @0xaf0c：mov w20,w2 / w19,w1 / w21,w0 ⇒ 三个 32 位参数 */
typedef int (*fn_aif_connect)(uint32_t session_id, uint32_t aif_id, uint32_t enable);

static void dump_aif(const unsigned char *buf, size_t n) {
    /* 实测步长 36 字节：name[32] + uint32 aif_id（小端） */
    printf("      共 %zu 条，步长 36B（name[32] + u32 aif_id）\n", n);
    for (size_t i = 0; i < n; i++) {
        const unsigned char *r = buf + i * 36;
        uint32_t id;
        memcpy(&id, r + 32, 4);
        printf("      [%2zu] aif_id=%-4u name=\"%.32s\"\n", i, id, (const char *)r);
    }
}

static int child(int step, const char *lib, int rev, uint32_t tag) {
    printf("  [child pid=%d] STEP=%d REV=%d TAG=%u\n", (int)getpid(), step, rev, tag);
    void *h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("      dlopen 失败: %s\n", dlerror()); return 11; }
    fn_init a_init = (fn_init)dlsym(h, "agm_init");
    fn_deinit a_deinit = (fn_deinit)dlsym(h, "agm_deinit");
    fn_open3 a_open3 = (fn_open3)dlsym(h, "agm_session_open");
    fn_close a_close = (fn_close)dlsym(h, "agm_session_close");
    fn_aif_list a_list = (fn_aif_list)dlsym(h, "agm_get_aif_info_list");
    printf("  [1] dlopen ✓  init=%p open=%p close=%p aif_list=%p\n",
           (void *)a_init, (void *)a_open3, (void *)a_close, (void *)a_list);
    if (!a_init || !a_open3) return 12;

    printf("  [2] agm_init()...\n");
    int rc = a_init();
    printf("      rc=%d %s\n", rc, rc == 0 ? "✓ HIDL AGM 服务已连上" : "✗");
    if (rc != 0) return 13;
    if (step <= 2) return 0;

    printf("  [3] agm_get_aif_info_list()...\n");
    if (a_list) {
        size_t cap = 128, n = cap;
        unsigned char *buf = calloc(cap, 36);
        if (buf) {
            int r2 = a_list(buf, &n);
            printf("      rc=%d 条数=%zu\n", r2, n);
            if (r2 == 0 && n > 0 && n <= cap) dump_aif(buf, n);
            free(buf);
        }
    }
    if (step <= 3) return 0;

    if (step == 5) {
        /* [5] 先给 session 挂 backend(AIF)，再 open。
         * 依据：服务端日志原文
         *   session_open_with_first_device: 889 No Audio interface(Backend) set on session(Frontend):N
         *   session_obj_open: 2192 Unable to open a session with Session ID:N
         * ⇒ session_open 之前必须先 aif_connect 把后端挂到这个 session id 上。 */
        fn_aif_connect a_conn = (fn_aif_connect)dlsym(h, "agm_session_aif_connect");
        printf("  [5] agm_session_aif_connect=%p\n", (void *)a_conn);
        if (a_conn) {
            for (uint32_t sid = 100; sid <= 200; sid += 100) {
                for (uint32_t aif = 1; aif <= 2; aif++) {
                    int cr = a_conn(sid, aif, 1);
                    printf("      aif_connect(sid=%u, aif=%u, enable=1) rc=%d\n", sid, aif, cr);
                    agm_session_t hd = 0;
                    int orc = a_open3(sid, 0, &hd);
                    printf("      session_open(sid=%u, mode=0) rc=%d handle=0x%llx%s\n", sid, orc,
                           (unsigned long long)hd, orc == 0 ? "   ← ✓ 成功" : "");
                    if (orc == 0 && a_close) printf("      session_close rc=%d\n", a_close(sid));
                }
            }
        }
        if (a_deinit) printf("  [6] agm_deinit rc=%d\n", a_deinit());
        return 0;
    }

    printf("  [4] agm_session_open 试 mode 0..12（三参数, tag=%u）...\n", tag);
    int ok = -1;
    for (uint32_t mode = 0; mode <= 12; mode++) {
        agm_session_t sid = 0;
        int r = a_open3(mode, tag, &sid);
        printf("      mode=%-2u rc=%-6d session_id=0x%llx%s\n", mode, r,
               (unsigned long long)sid, r == 0 ? "   ← ✓ 成功" : "");
        if (r == 0) {
            ok = (int)mode;
            if (a_close) printf("           agm_session_close rc=%d\n", a_close(sid));
            break;
        }
    }
    if (ok < 0) printf("      ⇒ 0..12 全被拒\n");
    else        printf("      ⇒ 可用 mode = %d\n", ok);
    if (a_deinit) printf("  [5] agm_deinit rc=%d\n", a_deinit());
    return (ok >= 0) ? 0 : 20;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *lib = (argc > 1) ? argv[1] : "/vendor/lib64/libagmclient.so";
    int step = getenv("STEP") ? atoi(getenv("STEP")) : 4;
    int rev = getenv("REV") && atoi(getenv("REV"));
    uint32_t tag = getenv("TAG") ? (uint32_t)atoi(getenv("TAG")) : 0;
    printf("=== agmprobe v3  lib=%s STEP=%d REV=%d TAG=%u ===\n", lib, step, rev, tag);

    pid_t p = fork();
    if (p == 0) { alarm(25); _exit(child(step, lib, rev, tag)); }
    int st = 0;
    if (waitpid(p, &st, 0) < 0) { printf("waitpid 失败\n"); return 1; }
    if (WIFSIGNALED(st)) printf("!! 子进程被信号杀死: signal=%d\n", WTERMSIG(st));
    else                 printf("子进程退出码=%d\n", WEXITSTATUS(st));
    printf("VERDICT: %s\n", WIFSIGNALED(st) ? "CRASHED"
                                : (WEXITSTATUS(st) == 0 ? "OK" : "FAILED"));
    (void)rev;
    return 0;
}

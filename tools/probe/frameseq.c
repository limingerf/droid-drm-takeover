/*
 * frameseq —— 判定"合成器到底有没有在向 CRTC 提交帧"。
 *
 * 背景（2026-10-12）：用户观察到面板是彩色噪声、电源键也不响应，
 * 怀疑"KWin 没接管面板 / 帧没提交"。需要一个**客观判据**来区分：
 *   - KWin 在正常 flip  → CRTC 的帧序号会持续递增
 *   - KWin 卡住/没提交  → 序号不动
 *
 * 用法：
 *   frameseq <card> [次数] [间隔毫秒]
 * 默认 10 次 × 500ms。
 *
 * 输出每个 CRTC 的 sequence（单调帧计数）与当前 fb_id，
 * 最后给出"递增 / 不动"的结论。打印 FRAMESEQ_DONE。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "用法: %s <card> [次数] [间隔ms]\n", argv[0]);
        return 2;
    }
    int rounds = argc > 2 ? atoi(argv[2]) : 10;
    int delay  = argc > 3 ? atoi(argv[3]) : 500;
    if (rounds <= 0) rounds = 10;
    if (delay  <= 0) delay  = 500;

    int fd = open(argv[1], O_RDWR | O_CLOEXEC);
    if (fd < 0) { fprintf(stderr, "打开 %s 失败: %s\n", argv[1], strerror(errno)); return 1; }

    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) { fprintf(stderr, "drmModeGetResources 失败: %s\n", strerror(errno)); close(fd); return 1; }

    printf("CRTC 数量: %d\n", res->count_crtcs);
    for (int i = 0; i < res->count_crtcs; i++)
        printf("  crtc[%d] = %u\n", i, res->crtcs[i]);
    fflush(stdout);

    /* 上一次的 sequence，用来判断是否递增 */
    uint64_t prev[64];
    int prev_ok[64];
    for (int i = 0; i < 64; i++) { prev[i] = 0; prev_ok[i] = 0; }

    long long t0 = now_ms();
    for (int r = 0; r < rounds; r++) {
        long long t = now_ms();
        printf("[%5d ms]", (int)(t - t0));
        for (int i = 0; i < res->count_crtcs; i++) {
            uint32_t crtc = res->crtcs[i];
            uint64_t seq = 0;
            int sr = drmCrtcGetSequence(fd, crtc, &seq, NULL);
            drmModeCrtcPtr c = drmModeGetCrtc(fd, crtc);
            if (sr == 0) {
                const char *mark = "";
                if (prev_ok[i]) mark = (seq > prev[i]) ? "↑" : (seq == prev[i] ? "=" : "?");
                printf("  crtc%u seq=%llu%s fb=%u", crtc,
                       (unsigned long long)seq, mark, c ? c->buffer_id : 0);
                prev[i] = seq; prev_ok[i] = 1;
            } else {
                printf("  crtc%u seq=ERR(%s) fb=%u", crtc, strerror(errno),
                       c ? c->buffer_id : 0);
            }
            if (c) drmModeFreeCrtc(c);
        }
        printf("\n");
        fflush(stdout);
        if (r + 1 < rounds) usleep((useconds_t)delay * 1000);
    }

    printf("\n── 结论 ──\n");
    for (int i = 0; i < res->count_crtcs; i++) {
        if (prev_ok[i])
            printf("  crtc%u: 最终 sequence = %llu\n", res->crtcs[i],
                   (unsigned long long)prev[i]);
    }
    drmModeFreeResources(res);
    close(fd);
    printf("FRAMESEQ_DONE\n");
    return 0;
}

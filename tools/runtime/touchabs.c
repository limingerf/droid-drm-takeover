/* touchabs.c —— LD_PRELOAD 垫片：改写触摸屏位置轴的 min/max
 *
 * ══ 为什么需要它 ══
 * 本机触摸屏（NVTCapacitiveTouchScreen）报的坐标系与显示差一个绕中心的 90° 旋转：
 *     需要  n_x = v,  n_y = 1 - u        （u = rawX/20000, v = rawY/32000）
 *
 * 本来该用 LIBINPUT_CALIBRATION_MATRIX，但实测（本容器 libinput 1.28.1，
 * 4 种矩阵变体、6 值与 9 值、平移量放 val[5]/val[6]/val[7] 全部试过）：
 *     **libinput 只用矩阵的 2×2 部分，平移项被完全忽略。**
 *   而 90° 旋转的 "+1" 恰恰是平移项 ⇒ 校准矩阵在数学上无法表达它。
 *   （上游仓库能用一个矩阵搞定，是因为它跑 libinput ≥1.31。）
 *
 * ══ 本垫片的思路 ══
 * libinput 归一化坐标是  U = (raw - min) / (max - min)。
 * 只要把 X 轴的量程整体平移，就能白拿到那个 "+1"：
 *
 *   需要  n_y = 1 - u  ⇒  取矩阵 n_y = -U  ⇒  要 U = u - 1
 *   U = (rawX - min)/(max - min) = u - 1
 *   ⇒  min = 20000,  max = 40000      （即把 X 轴量程平移 +20000）
 *
 * 于是矩阵写成  "0 1 0 -1 0 0"  就得到  n = (v, 1-u)  —— 全是 2×2，无平移项。
 *
 * ══ 风险与验证 ══
 * 若 libinput 把原始值 clamp 到 [min,max]，则所有 rawX < 20000 都会被夹到 20000，
 * U 恒为 0，n_y 恒为 0 —— 方案失效。
 * 判定实验：把 X 量程设成 [-20000, 0]（U = u + 1 ∈ [1,2]，必定越界），
 * 矩阵用恒等 "1 0 0 0 1 0"，则 KWin 日志里的 x 应等于 -1422.2*(u+1)，
 * **随注入点变化** ⇒ 没被 clamp；**恒为 -1422.2** ⇒ 被 clamp。
 *
 * ══ 用法 ══
 *   LD_PRELOAD=touchabs.so
 *   TOUCHABS_X_MIN / TOUCHABS_X_MAX   覆盖 ABS_MT_POSITION_X(53) 的 min/max
 *   TOUCHABS_Y_MIN / TOUCHABS_Y_MAX   覆盖 ABS_MT_POSITION_Y(54) 的 min/max
 *   TOUCHABS_LOG=<path>               落盘诊断（每根轴只记一次）
 * 不设任何 TOUCHABS_* 时本垫片完全透明。
 *
 * 交叉编译：
 *   aarch64-linux-gnu-gcc -O2 -g -Wall -shared -fPIC -o touchabs.so touchabs.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/input.h>

typedef int (*ioctl_fn)(int, unsigned long, ...);
static ioctl_fn real_ioctl = NULL;

/* 每个轴只记一次日志，避免刷屏 */
static int logged[64];

static void alog(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if (n > (int)sizeof buf - 1)
        n = (int)sizeof buf - 1;
    (void)!write(2, buf, (size_t)n);

    const char *p = getenv("TOUCHABS_LOG");
    if (!p || !*p)
        return;
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    (void)!write(fd, buf, (size_t)n);
    close(fd);
}

static int env_int(const char *name, int dflt)
{
    const char *v = getenv(name);
    if (!v || !*v)
        return dflt;
    return (int)strtol(v, NULL, 10);
}

/* 该轴是否配置了覆盖；返回 1 表示需要改写 */
static int axis_override(int code, int *mn, int *mx)
{
    const char *nm = NULL, *xm = NULL;
    if (code == ABS_MT_POSITION_X) { nm = "TOUCHABS_X_MIN"; xm = "TOUCHABS_X_MAX"; }
    else if (code == ABS_MT_POSITION_Y) { nm = "TOUCHABS_Y_MIN"; xm = "TOUCHABS_Y_MAX"; }
    else return 0;
    const char *a = getenv(nm), *b = getenv(xm);
    if ((!a || !*a) && (!b || !*b))
        return 0;
    *mn = env_int(nm, 0);
    *mx = env_int(xm, 0);
    return 1;
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;

    if (!real_ioctl)
        real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    int rc = real_ioctl(fd, req, arg);

    /* 只关心 EVIOCGABS(code)：_IOR('E', 0x40+code, struct input_absinfo) */
    if (rc == 0 && arg) {
        int code = -1;
        if (req == (unsigned long)EVIOCGABS(ABS_MT_POSITION_X)) code = ABS_MT_POSITION_X;
        else if (req == (unsigned long)EVIOCGABS(ABS_MT_POSITION_Y)) code = ABS_MT_POSITION_Y;

        if (code >= 0) {
            int mn, mx;
            if (axis_override(code, &mn, &mx)) {
                struct input_absinfo *ai = (struct input_absinfo *)arg;
                int omin = ai->minimum, omax = ai->maximum;
                ai->minimum = mn;
                ai->maximum = mx;
                if (!logged[code]) {
                    logged[code] = 1;
                    alog("touchabs: fd=%d ABS_MT_POSITION_%c code=%d min/max %d..%d -> %d..%d\n",
                         fd, code == ABS_MT_POSITION_X ? 'X' : 'Y', code, omin, omax, mn, mx);
                }
            }
        }
    }
    return rc;
}

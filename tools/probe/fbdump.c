/* fbdump — 把某个 DRM framebuffer 导成 PPM(P6)，用于肉眼核对合成结果。
 *
 * 用法: fbdump [设备] [fb_id] [输出.ppm]
 *
 * 为什么需要它：接管后无法用 adb screencap（安卓显示栈已停），
 * 而"提交成功"不等于"画面正确"——必须看 KWin 真正合成出来的像素。
 * 走 PrimeHandleToFD + mmap，所以 GBM 缓冲（非 dumb）也能读。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    unsigned fb_id  = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 0;
    const char *out = argc > 3 ? argv[3] : "/tmp/fb.ppm";

    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }

    drmModeFB2 *fb = drmModeGetFB2(fd, fb_id);
    if (!fb) { perror("drmModeGetFB2"); close(fd); return 1; }

    fprintf(stderr, "fb %u: %ux%u format=0x%08x pitch=%u modifier=0x%llx\n",
            fb_id, fb->width, fb->height, fb->pixel_format, fb->pitches[0],
            (unsigned long long)fb->modifier);

    int dfd = -1;
    if (drmPrimeHandleToFD(fd, fb->handles[0], DRM_CLOEXEC, &dfd) != 0) {
        perror("drmPrimeHandleToFD"); drmModeFreeFB2(fb); close(fd); return 1;
    }

    size_t sz = (size_t)fb->pitches[0] * fb->height;
    void *m = mmap(NULL, sz, PROT_READ, MAP_SHARED, dfd, 0);
    if (m == MAP_FAILED) { perror("mmap"); close(dfd); drmModeFreeFB2(fb); close(fd); return 1; }

    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); munmap(m, sz); close(dfd); drmModeFreeFB2(fb); close(fd); return 1; }

    fprintf(f, "P6\n%u %u\n255\n", fb->width, fb->height);

    const unsigned char *p = m;
    unsigned char *rowbuf = malloc((size_t)fb->width * 3);
    if (!rowbuf) { fclose(f); munmap(m, sz); close(dfd); drmModeFreeFB2(fb); close(fd); return 1; }

    /* ★ 必须按 fb 的真实 fourcc 解码，否则会得到假"条纹"。
     *   踩过的坑：KWin 的输出缓冲是 AR30 = DRM_FORMAT_ARGB2101010
     *   （10 bit/通道），早先按 8 位 XRGB8888 硬解 ⇒ 满屏密集竖条纹，
     *   看着像画面坏了，其实只是解码错了。 */
    unsigned fmt = fb->pixel_format;
    int is2101010_argb = (fmt == 0x30335241u || fmt == 0x30335258u); /* AR30 / XR30 */
    int is2101010_abgr = (fmt == 0x30334241u || fmt == 0x30334258u); /* AB30 / XB30 */
    int bgr_order       = (fmt == 0x34325241u || fmt == 0x34325258u ||   /* AR24 / XR24 */
                           fmt == 0x34324241u || fmt == 0x34324258u);   /* AB24 / XB24 */
    (void)bgr_order;
    /* bgr_order 为真时字节序是 B,G,R(,X)；为假（ABGR/XBGR）时是 R,G,B(,X) */
    int rgbs = (fmt == 0x34324241u || fmt == 0x34324258u);            /* AB24 / XB24 */

    fprintf(stderr, "  解码: %s%s\n",
            is2101010_argb ? "ARGB2101010" : is2101010_abgr ? "ABGR2101010" :
            rgbs ? "ABGR8888/XBGR8888" : "ARGB8888/XRGB8888",
            (fmt == 0x30335258u || fmt == 0x30334258u ||
             fmt == 0x34325258u || fmt == 0x34324258u) ? " (X=忽略alpha)" : "");

    for (unsigned y = 0; y < fb->height; y++) {
        const unsigned char *row = p + (size_t)y * fb->pitches[0];
        for (unsigned x = 0; x < fb->width; x++) {
            const unsigned char *px = row + (size_t)x * 4;
            if (is2101010_argb || is2101010_abgr) {
                unsigned v = (unsigned)px[0] | ((unsigned)px[1] << 8) |
                             ((unsigned)px[2] << 16) | ((unsigned)px[3] << 24);
                unsigned r, g, b;
                if (is2101010_argb) {           /* R[0:9] G[10:19] B[20:29] A[30:31] */
                    r = v & 0x3ffu; g = (v >> 10) & 0x3ffu; b = (v >> 20) & 0x3ffu;
                } else {                        /* A[0:1] B[2:11] G[12:21] R[22:31] */
                    b = (v >> 2) & 0x3ffu; g = (v >> 12) & 0x3ffu; r = (v >> 22) & 0x3ffu;
                }
                rowbuf[x * 3 + 0] = (unsigned char)(r >> 2);   /* 10bit -> 8bit */
                rowbuf[x * 3 + 1] = (unsigned char)(g >> 2);
                rowbuf[x * 3 + 2] = (unsigned char)(b >> 2);
            } else if (rgbs) {                  /* 字节序 R,G,B,X */
                rowbuf[x * 3 + 0] = px[0];
                rowbuf[x * 3 + 1] = px[1];
                rowbuf[x * 3 + 2] = px[2];
            } else {                            /* 字节序 B,G,R,X */
                rowbuf[x * 3 + 0] = px[2];
                rowbuf[x * 3 + 1] = px[1];
                rowbuf[x * 3 + 2] = px[0];
            }
        }
        fwrite(rowbuf, 1, (size_t)fb->width * 3, f);
    }

    free(rowbuf);
    fclose(f);
    munmap(m, sz);
    close(dfd);
    drmModeFreeFB2(fb);
    close(fd);
    fprintf(stderr, "wrote %s\n", out);
    return 0;
}

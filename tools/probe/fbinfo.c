/* fbinfo.c — 读一个 framebuffer 的真实元数据（format / pitch / modifier / 平面数）。
 *
 * 为什么需要：判断"扫出读到的是什么"时，fb 的 format 与 pitch 是权威依据。
 * drmModeGetFB2 能给出 fourcc + modifier + 每平面的 pitch/offset，
 * 比从 fbdump 的输出反推可靠。
 *
 * usage: fbinfo <card> <fb_id> [...]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_fourcc.h>

static void fourcc_str(uint32_t f, char out[5]) {
    out[0] = (char)(f & 0xff);
    out[1] = (char)((f >> 8) & 0xff);
    out[2] = (char)((f >> 16) & 0xff);
    out[3] = (char)((f >> 24) & 0xff);
    out[4] = 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <card> <fb_id> [fb_id...]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open %s: %s\n", path, strerror(errno)); return 2; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);

    for (int i = 2; i < argc; i++) {
        uint32_t id = (uint32_t)strtoul(argv[i], NULL, 0);
        printf("=== fb %u ===\n", id);

        drmModeFB2 *fb2 = drmModeGetFB2(fd, id);
        if (fb2) {
            char f[5];
            fourcc_str(fb2->pixel_format, f);
            printf("  FB2: %ux%u fourcc=0x%08x '%s' modifier=0x%016llx flags=0x%x\n",
                   fb2->width, fb2->height, fb2->pixel_format, f,
                   (unsigned long long)fb2->modifier, fb2->flags);
            for (int p = 0; p < 4; p++) {
                if (!fb2->handles[p] && !fb2->pitches[p] && !fb2->offsets[p])
                    continue;
                printf("    plane%d handle=%u pitch=%u offset=%u\n",
                       p, fb2->handles[p], fb2->pitches[p], fb2->offsets[p]);
            }
            drmModeFreeFB2(fb2);
        } else {
            printf("  FB2: 不可用（%s）\n", strerror(errno));
        }

        drmModeFB *fb = drmModeGetFB(fd, id);
        if (fb) {
            /* drmModeFB（legacy）没有 fourcc，只有 bpp/depth/pitch */
            printf("  FB1: %ux%u bpp=%u depth=%u pitch=%u handle=%u\n",
                   fb->width, fb->height, fb->bpp, fb->depth, fb->pitch,
                   fb->handle);
            drmModeFreeFB(fb);
        } else {
            printf("  FB1: 不可用（%s）\n", strerror(errno));
        }
    }
    close(fd);
    printf("FBINFO_DONE\n");
    return 0;
}

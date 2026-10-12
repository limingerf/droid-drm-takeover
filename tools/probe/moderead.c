/* moderead.c — 读 CRTC 的 MODE_ID blob，打印里面真正的时序。
 *
 * 为什么需要：kmsdump 显示 CRTC 200 的 mode=3200x2000x144vid，
 * 而 KWin 按 preferred 应该选 120vid。MODE_ID blob 里到底是什么时序，
 * 决定了"面板收到的时序"和"面板期望的时序"是否一致 ——
 * 不一致就是彩色噪声的直接原因。
 *
 * usage: moderead <card>
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_mode.h>

static void show(const drmModeModeInfo *m, const char *tag) {
    printf("%s %s %ux%u clock=%u hz=%u type=0x%x\n", tag, m->name,
           m->hdisplay, m->vdisplay, m->clock, m->vrefresh, m->type);
    printf("   h: %u/%u/%u/%u  v: %u/%u/%u/%u  flags=0x%x\n",
           m->hdisplay, m->hsync_start, m->hsync_end, m->htotal,
           m->vdisplay, m->vsync_start, m->vsync_end, m->vtotal, m->flags);
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 2; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("res"); return 3; }
    for (int i = 0; i < res->count_crtcs; i++) {
        uint32_t cid = res->crtcs[i];
        drmModeObjectProperties *op =
            drmModeObjectGetProperties(fd, cid, DRM_MODE_OBJECT_CRTC);
        if (!op) continue;
        uint32_t modeblob = 0;
        for (uint32_t k = 0; k < op->count_props; k++) {
            drmModePropertyRes *pr = drmModeGetProperty(fd, op->props[k]);
            if (pr && !strcmp(pr->name, "MODE_ID")) modeblob = op->prop_values[k];
            if (pr) drmModeFreeProperty(pr);
        }
        drmModeFreeObjectProperties(op);
        if (!modeblob) continue;
        drmModePropertyBlobRes *bl = drmModeGetPropertyBlob(fd, modeblob);
        if (!bl) { printf("CRTC %u MODE_ID blob %u 读不到\n", cid, modeblob); continue; }
        printf("=== CRTC %u MODE_ID blob=%u len=%u ===\n", cid, modeblob, bl->length);
        if (bl->length >= sizeof(drmModeModeInfo))
            show((const drmModeModeInfo *)bl->data, "  BLOB");
        else
            printf("  blob 太短（%u < %zu）\n", bl->length, sizeof(drmModeModeInfo));
        drmModeFreePropertyBlob(bl);
    }
    drmModeFreeResources(res);
    close(fd);
    printf("MODEREAD_DONE\n");
    return 0;
}

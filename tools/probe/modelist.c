/* modelist.c — 打印连接器所有模式的完整时序 + CRTC 当前生效的 mode。
 *
 * 为什么需要：本机面板 3200x2000 有 4 个模式（120/144/90/60vid）。
 * KWin 按 preferred(type&0x8) 选，选中的是 **120vid**；
 * 但 `kmsdump` 显示 CRTC 200 上生效的是 **144vid** —— 两者不一致。
 * 时序不匹配是"面板收到数据却解不出画面"的经典原因，
 * 所以必须把每个模式的 clock/hsync/vsync/porch 都摊开看。
 *
 * usage: modelist <card>
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_mode.h>

static void dump_mode(const drmModeModeInfo *m, const char *tag) {
    printf("%s %s %ux%u clock=%u(%u kHz) hz=%u type=0x%x flags=0x%x\n",
           tag, m->name, m->hdisplay, m->vdisplay, m->clock, m->clock,
           m->vrefresh, m->type, m->flags);
    printf("      h: disp=%u sync_start=%u sync_end=%u total=%u skew=%u\n",
           m->hdisplay, m->hsync_start, m->hsync_end, m->htotal, m->hskew);
    printf("      v: disp=%u sync_start=%u sync_end=%u total=%u scan=%u\n",
           m->vdisplay, m->vsync_start, m->vsync_end, m->vtotal, m->vscan);
    printf("      pixclk_khz=%u  实际行频=%.2f kHz  实际帧率=%.3f Hz\n",
           m->clock,
           m->htotal ? (double)m->clock / m->htotal : 0.0,
           (m->htotal && m->vtotal)
               ? (double)m->clock * 1000.0 / ((double)m->htotal * m->vtotal) : 0.0);
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 2; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("resources"); return 3; }

    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection != DRM_MODE_CONNECTED) { drmModeFreeConnector(c); continue; }
        printf("=== connector %u type=%d type_id=%d modes=%d encoder=%u ===\n",
               c->connector_id, c->connector_type, c->connector_type_id,
               c->count_modes, c->encoder_id);
        for (int m = 0; m < c->count_modes; m++) {
            char tag[32];
            snprintf(tag, sizeof tag, "  [%d]%s", m,
                     (c->modes[m].type & DRM_MODE_TYPE_PREFERRED) ? " ★PREFERRED" : "");
            dump_mode(&c->modes[m], tag);
        }
        /* 当前生效的 mode（如果 encoder 有 crtc） */
        if (c->encoder_id) {
            drmModeEncoder *e = drmModeGetEncoder(fd, c->encoder_id);
            if (e && e->crtc_id) {
                drmModeCrtc *cr = drmModeGetCrtc(fd, e->crtc_id);
                if (cr) {
                    printf("  → 当前生效 CRTC %u (encoder %u):\n", e->crtc_id, c->encoder_id);
                    dump_mode(&cr->mode, "     LIVE");
                    drmModeFreeCrtc(cr);
                }
                if (e) drmModeFreeEncoder(e);
            }
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(res);
    close(fd);
    printf("MODELIST_DONE\n");
    return 0;
}

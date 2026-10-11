#include <stdio.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) fd = open("/dev/dri/renderD128", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { printf("no resources on render node, trying card0 masterless anyway\n"); return 1; }
    printf("CRTCs:");
    for (int i = 0; i < res->count_crtcs; i++) printf(" %u(idx%d)", res->crtcs[i], i);
    printf("\n");
    uint32_t want[] = {97, 129, 157, 161};
    for (int w = 0; w < 4; w++) {
        drmModePlane *p = drmModeGetPlane(fd, want[w]);
        if (!p) { printf("plane %u: get failed\n", want[w]); continue; }
        printf("plane %u: possible_crtcs=0x%x crtc=%u fb=%u\n",
               want[w], p->possible_crtcs, p->crtc_id, p->fb_id);
        drmModeFreePlane(p);
    }
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connector_type == DRM_MODE_CONNECTOR_DSI ||
            c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL)
            printf("conn %u type %u status %d enc %u crtcs_mask=0x%x\n",
                   c->connector_id, c->connector_type, c->connection,
                   c->encoder_id, 0u);
        for (int j = 0; j < c->count_encoders; j++) {
            drmModeEncoder *e = drmModeGetEncoder(fd, c->encoders[j]);
            if (!e) continue;
            printf("   encoder %u: possible_crtcs=0x%x crtc=%u\n",
                   e->encoder_id, e->possible_crtcs, e->crtc_id);
            drmModeFreeEncoder(e);
        }
        drmModeFreeConnector(c);
    }
    return 0;
}

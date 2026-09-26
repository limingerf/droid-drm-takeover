/* stageprobe.c — find which property group makes the full atomic TEST_ONLY
 * return EINVAL. Same setup as drmatomic (master + caps + dumb fb + mode
 * blob), then cumulative staged TEST_ONLY commits. Run under the takeover
 * script (needs master). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdbool.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define FP 16
static int fd;

static void t(const char *label, drmModeAtomicReq *r) {
    errno = 0;
    int ret = drmModeAtomicCommit(fd, r,
              DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_ATOMIC_TEST_ONLY, NULL);
    printf("%-34s ret=%d (%s)\n", label, ret, ret ? strerror(errno) : "ok");
    fflush(stdout);
    drmModeAtomicFree(r);
}

#define A(r, o, p, v) drmModeAtomicAddProperty(r, o, p, v)

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/dri/card0";
    fd = open(path, O_RDWR);
    if (fd < 0) { printf("open: %s\n", strerror(errno)); return 2; }
    if (drmSetMaster(fd)) { printf("SETMASTER: %s\n", strerror(errno)); return 3; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        printf("CAP ATOMIC: %s\n", strerror(errno)); return 4;
    }
    printf("master+caps ok\n");

    drmModeRes *res = drmModeGetResources(fd);
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED &&
            c->connector_type == DRM_MODE_CONNECTOR_DSI && c->count_modes) {
            conn = c; break;
        }
        drmModeFreeConnector(c);
    }
    if (!conn) { printf("no DSI\n"); return 5; }
    uint32_t crtc_id = 0;
    drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
    if (enc) { crtc_id = enc->crtc_id; drmModeFreeEncoder(enc); }
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (!pc || !pc->mode_valid) { printf("no active mode\n"); return 6; }
    drmModeModeInfo mode = pc->mode;
    drmModeFreeCrtc(pc);
    uint32_t cid = conn->connector_id;
    printf("conn %u crtc %u mode %s\n", cid, crtc_id, mode.name);

    uint32_t blob_id = 0;
    if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &blob_id)) {
        printf("blob: %s\n", strerror(errno)); return 7;
    }

    struct drm_mode_create_dumb cd = {0};
    cd.width = mode.hdisplay; cd.height = mode.vdisplay; cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        printf("dumb: %s\n", strerror(errno)); return 8;
    }
    uint32_t handles[4] = {cd.handle}, pitches[4] = {cd.pitch}, offsets[4] = {0};
    uint32_t fb_id = 0;
    if (drmModeAddFB2(fd, cd.width, cd.height, DRM_FORMAT_XRGB8888,
                      handles, pitches, offsets, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno)); return 9;
    }
    struct drm_mode_map_dumb md = {0};
    md.handle = cd.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md) ||
        mmap(NULL, (size_t)cd.pitch * cd.height, PROT_READ | PROT_WRITE,
             MAP_SHARED, fd, md.offset) == MAP_FAILED) {
        printf("map: %s\n", strerror(errno)); return 10;
    }
    printf("fb %u created\n", fb_id);

    /* property IDs proven resolvable by rawprobe round-2 */
    const uint32_t P_ACTIVE = 22, P_MODE = 23, P_CRTC_ID = 20, P_FB = 17;
    const uint32_t P_SX = 9, P_SY = 10, P_SW = 11, P_SH = 12;
    const uint32_t P_CX = 13, P_CY = 14, P_CW = 15, P_CH = 16;
    uint32_t pl[2] = {161, 157};
    uint32_t half = mode.hdisplay / 2;

#define PLANE_FULL(r, i) do { \
        A(r, pl[i], P_FB, fb_id); \
        A(r, pl[i], P_CRTC_ID, crtc_id); \
        A(r, pl[i], P_SX, (uint64_t)(i) * half << FP); \
        A(r, pl[i], P_SY, 0); \
        A(r, pl[i], P_SW, (uint64_t)half << FP); \
        A(r, pl[i], P_SH, (uint64_t)mode.vdisplay << FP); \
        A(r, pl[i], P_CX, (uint64_t)(i) * half << FP); \
        A(r, pl[i], P_CY, 0); \
        A(r, pl[i], P_CW, (uint64_t)half << FP); \
        A(r, pl[i], P_CH, (uint64_t)mode.vdisplay << FP); \
    } while (0)

    drmModeAtomicReq *r;

    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1);
    t("S1 crtc ACTIVE=1", r);

    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    t("S2 +conn CRTC_ID", r);

    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id);
    t("S3 +crtc MODE_ID=blob", r);

    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id); PLANE_FULL(r, 0);
    t("S4 +plane161 left half", r);

    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id); PLANE_FULL(r, 0); PLANE_FULL(r, 1);
    t("S5 +plane157 right half", r);

    /* plane161 alone, whole panel (single-pipe full width) */
    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id);
    A(r, pl[0], P_FB, fb_id); A(r, pl[0], P_CRTC_ID, crtc_id);
    A(r, pl[0], P_SX, 0); A(r, pl[0], P_SY, 0);
    A(r, pl[0], P_SW, (uint64_t)mode.hdisplay << FP);
    A(r, pl[0], P_SH, (uint64_t)mode.vdisplay << FP);
    A(r, pl[0], P_CX, 0); A(r, pl[0], P_CY, 0);
    A(r, pl[0], P_CW, mode.hdisplay << FP);
    A(r, pl[0], P_CH, (uint64_t)mode.vdisplay << FP);
    t("S6 plane161 whole panel", r);

    /* S3 + FB+CRTC only, no rects */
    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id);
    A(r, pl[0], P_FB, fb_id); A(r, pl[0], P_CRTC_ID, crtc_id);
    t("S7 plane161 FB+CRTC no rects", r);

    /* legacy primary plane 97 single-pipe full panel */
    r = drmModeAtomicAlloc(); A(r, crtc_id, P_ACTIVE, 1); A(r, cid, P_CRTC_ID, crtc_id);
    A(r, crtc_id, P_MODE, blob_id);
    A(r, 97, P_FB, fb_id); A(r, 97, P_CRTC_ID, crtc_id);
    A(r, 97, P_SX, 0); A(r, 97, P_SY, 0);
    A(r, 97, P_SW, (uint64_t)mode.hdisplay << FP);
    A(r, 97, P_SH, (uint64_t)mode.vdisplay << FP);
    A(r, 97, P_CX, 0); A(r, 97, P_CY, 0);
    A(r, 97, P_CW, mode.hdisplay << FP);
    A(r, 97, P_CH, (uint64_t)mode.vdisplay << FP);
    t("S8 legacy plane97 full panel", r);

    printf("DONE\n");
    return 0;
}

/* Faithful replica of kwinwrap's rebuilt 4-obj commit (the steady TEST that
 * returns -ENOENT during takeover), TEST_ONLY only, with shape variants to
 * find which missing/extra object turns -2 into 0. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define CRTC_ID 206u
#define CONN_ID 67u
#define PL_L    161u
#define PL_R    157u
#define W       1600u
#define H       2136u
#define P_SX 9u
#define P_SY 10u
#define P_SW 11u
#define P_SH 12u
#define P_CX 13u
#define P_CY 14u
#define P_CW 15u
#define P_CH 16u
#define P_FB 17u
#define P_CRTC 20u
#define P_ACT 22u
#define P_MODE 23u
#define P_LINK 5u
#define P_VRR 24u

static int fd;
static uint32_t blob, fb;

static void plane(drmModeAtomicReq *r, uint32_t pl, int right) {
    drmModeAtomicAddProperty(r, pl, P_CRTC, CRTC_ID);
    drmModeAtomicAddProperty(r, pl, P_FB, fb);
    drmModeAtomicAddProperty(r, pl, P_SX, (uint64_t)(right ? W : 0) << 16);
    drmModeAtomicAddProperty(r, pl, P_SY, 0);
    drmModeAtomicAddProperty(r, pl, P_SW, (uint64_t)W << 16);
    drmModeAtomicAddProperty(r, pl, P_SH, (uint64_t)H << 16);
    drmModeAtomicAddProperty(r, pl, P_CX, right ? W : 0);
    drmModeAtomicAddProperty(r, pl, P_CY, 0);
    drmModeAtomicAddProperty(r, pl, P_CW, W);
    drmModeAtomicAddProperty(r, pl, P_CH, H);
}

static int base(drmModeAtomicReq *r) {
    drmModeAtomicAddProperty(r, CONN_ID, P_LINK, 0);
    drmModeAtomicAddProperty(r, CONN_ID, P_CRTC, CRTC_ID);
    drmModeAtomicAddProperty(r, CRTC_ID, P_MODE, blob);
    drmModeAtomicAddProperty(r, CRTC_ID, P_ACT, 1);
    drmModeAtomicAddProperty(r, CRTC_ID, P_VRR, 0);
    plane(r, PL_R, 1);
    plane(r, PL_L, 0);
    return 0;
}

static void run(const char *tag, int variant) {
    drmModeAtomicReq *r = drmModeAtomicAlloc();
    base(r);
    static const uint32_t others[] = {271,280,289,298,307,316,325};
    if (variant == 2)
        for (unsigned i = 0; i < 7; i++) {
            drmModeAtomicAddProperty(r, others[i], P_MODE, 0);
            drmModeAtomicAddProperty(r, others[i], P_ACT, 0);
        }
    if (variant == 3)
        drmModeAtomicAddProperty(r, CONN_ID, P_MODE, blob);
    if (variant == 4) {          /* left half only */
        drmModeAtomicReq *r2 = drmModeAtomicAlloc();
        drmModeAtomicAddProperty(r2, CONN_ID, P_LINK, 0);
        drmModeAtomicAddProperty(r2, CONN_ID, P_CRTC, CRTC_ID);
        drmModeAtomicAddProperty(r2, CRTC_ID, P_MODE, blob);
        drmModeAtomicAddProperty(r2, CRTC_ID, P_ACT, 1);
        plane(r2, PL_L, 0);
        r = r2;
    }
    if (variant == 5) {          /* conn link-status + DPMS (kwin-style) */
        drmModeAtomicReq *r2 = drmModeAtomicAlloc();
        drmModeAtomicAddProperty(r2, CONN_ID, P_LINK, 0);
        drmModeAtomicAddProperty(r2, CONN_ID, P_CRTC, CRTC_ID);
        drmModeAtomicAddProperty(r2, CONN_ID, 2, 0);
        drmModeAtomicAddProperty(r2, CRTC_ID, P_MODE, blob);
        drmModeAtomicAddProperty(r2, CRTC_ID, P_ACT, 1);
        drmModeAtomicAddProperty(r2, CRTC_ID, P_VRR, 0);
        plane(r2, PL_R, 1);
        plane(r2, PL_L, 0);
        r = r2;
    }
    if (variant == 6) {          /* replica but halves carry IN_FENCE_FD=-1 */
        base(r);
        drmModeAtomicAddProperty(r, PL_L, 18, ~0ULL);
        drmModeAtomicAddProperty(r, PL_R, 18, ~0ULL);
    }
    int ret = drmModeAtomicCommit(fd, r, DRM_MODE_ATOMIC_TEST_ONLY |
                                  DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
    printf("%-28s -> %s\n", tag, ret ? strerror(errno) : "OK");
    if (r) drmModeAtomicFree(r);
}

int main(void) {
    fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    if (drmSetMaster(fd)) printf("SetMaster: %s (continuing)\n", strerror(errno));
    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { printf("no res %s\n", strerror(errno)); return 2; }
    drmModeConnector *c = drmModeGetConnector(fd, CONN_ID);
    if (!c || !c->count_modes) { printf("conn bad\n"); return 3; }
    if (drmModeCreatePropertyBlob(fd, &c->modes[0], sizeof(c->modes[0]), &blob)) {
        printf("blob %s\n", strerror(errno)); return 4;
    }
    struct drm_mode_create_dumb cd = {0};
    cd.width = 2 * W; cd.height = H; cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { printf("dumb %s\n", strerror(errno)); return 5; }
    uint32_t h4[4] = { cd.handle }, p4[4] = { cd.pitch }, o4[4] = {0};
    if (drmModeAddFB2(fd, 2 * W, H, DRM_FORMAT_XRGB8888, h4, p4, o4, &fb, 0)) {
        printf("addfb %s\n", strerror(errno)); return 6;
    }
    printf("blob=%u fb=%u mode %dx%d\n", blob, fb, c->modes[0].hdisplay, c->modes[0].vdisplay);
    drmModeFreeConnector(c);
    drmModeFreeResources(res);

    run("V1 replica no=4", 1);
    run("V2 +7 inactive crtcs", 2);
    run("V3 +conn MODE_ID", 3);
    run("V4 left half only", 4);
    run("V5 +conn DPMS", 5);
    run("V6 halves +IN_FENCE", 6);

    drmModeRmFB(fd, fb);
    drmModeDestroyPropertyBlob(fd, blob);
    drmDropMaster(fd);
    return 0;
}

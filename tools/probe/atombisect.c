/* Incremental TEST_ONLY bisector: find exactly which object/property combo
 * the kernel rejects with EINVAL. Non-destructive (TEST_ONLY never touches
 * hardware), but needs drm master. Steals master briefly, restores it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define FP 16
#define P_SRC_X 9
#define P_SRC_Y 10
#define P_SRC_W 11
#define P_SRC_H 12
#define P_CRTC_X 13
#define P_CRTC_Y 14
#define P_CRTC_W 15
#define P_CRTC_H 16
#define P_FB_ID 17
#define P_CRTC_ID 20
#define P_ACTIVE 22
#define P_MODE_ID 23

static int fd;
static uint32_t conn_id, crtc_id, fb_id, blob_id;
static uint32_t map_w, map_h;
static drmModeModeInfo mode_copy;
static int have_mode;

static void addp(drmModeAtomicReq *r, uint32_t obj, uint32_t prop, uint64_t v) {
    if (drmModeAtomicAddProperty(r, obj, prop, v) < 0)
        printf("  AddProperty(obj %u prop %u) FAILED: %s\n",
               obj, prop, strerror(errno));
}

static void try_step(const char *label, uint32_t *objs, uint32_t *props,
                     uint64_t *vals, int n) {
    drmModeAtomicReq *r = drmModeAtomicAlloc();
    for (int i = 0; i < n; i++)
        addp(r, objs[i], props[i], vals[i]);
    int ret = drmModeAtomicCommit(fd, r,
                                  DRM_MODE_ATOMIC_ALLOW_MODESET |
                                  DRM_MODE_ATOMIC_TEST_ONLY, NULL);
    int e = (ret == -1) ? errno : (ret < 0 ? -ret : 0);
    printf("%-46s -> %d (%s)\n", label, ret,
           e ? strerror(e) : "OK");
    drmModeAtomicFree(r);
}

#define MAXP 32
static uint32_t objs[MAXP], props[MAXP];
static uint64_t vals[MAXP];
static int np;
static void push(uint32_t o, uint32_t p, uint64_t v) {
    objs[np] = o; props[np] = p; vals[np] = v; np++;
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    if (drmSetMaster(fd)) { printf("SetMaster: %s\n", strerror(errno)); return 1; }
    printf("master acquired\n");

    /* find DSI connector + its crtc + current mode */
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { printf("no resources (need master?) %s\n", strerror(errno)); return 2; }
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connector_type == DRM_MODE_CONNECTOR_DSI &&
            c->connection == DRM_MODE_CONNECTED) {
            conn_id = c->connector_id;
            for (int m = 0; m < c->count_modes; m++)
                if (c->modes[m].type & DRM_MODE_TYPE_PREFERRED)
                    { mode_copy = c->modes[m]; have_mode = 1; }
            if (!have_mode && c->count_modes)
                { mode_copy = c->modes[0]; have_mode = 1; }
        }
        drmModeFreeConnector(c);
        if (conn_id) break;
    }
    if (!conn_id) { printf("no DSI conn\n"); return 3; }
    printf("conn %u mode %dx%d\n", conn_id, mode_copy.hdisplay, mode_copy.vdisplay);

    /* crtc 206 hardcoded as observed; also try to find via encoder */
    crtc_id = 206;
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (pc) {
        if (pc->mode_valid) { mode_copy = pc->mode; }
        drmModeFreeCrtc(pc);
    } else {
        printf("GetCrtc(206) failed: %s, trying all crtcs\n", strerror(errno));
        for (int i = 0; i < res->count_crtcs; i++) {
            pc = drmModeGetCrtc(fd, res->crtcs[i]);
            if (pc) { if (pc->mode_valid) { crtc_id = res->crtcs[i];
                            mode_copy = pc->mode; }
                      drmModeFreeCrtc(pc); }
        }
        printf("fallback crtc %u\n", crtc_id);
    }
    printf("crtc %u\n", crtc_id);

    if (!blob_id && drmModeCreatePropertyBlob(fd, &mode_copy, sizeof(mode_copy),
                                              &blob_id)) {
        printf("blob: %s\n", strerror(errno)); return 4;
    }
    printf("blob %u\n", blob_id);

    /* small dumb fb so plane FB_ID gets a plausible value */
    struct drm_mode_create_dumb cd = {0};
    cd.width = 64; cd.height = 64; cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        printf("dumb: %s\n", strerror(errno)); return 5;
    }
    uint32_t handles[4] = { cd.handle }, pitches[4] = { cd.pitch };
    uint32_t moffs[4] = { 0 };
    if (drmModeAddFB2(fd, 64, 64, DRM_FORMAT_XRGB8888, handles, pitches,
                      moffs, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno)); return 6;
    }
    printf("fb %u\n", fb_id);

    map_w = mode_copy.hdisplay; map_h = mode_copy.vdisplay;

    printf("\n== incremental TEST_ONLY ==\n\n");

    np = 0;
    try_step("1a  crtc ACTIVE=1", objs, props, vals, np);
    push(crtc_id, P_ACTIVE, 1);
    try_step("1b  crtc ACTIVE=1", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    try_step("2   crtc ACTIVE + MODE_ID", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    push(conn_id, P_MODE_ID, blob_id);
    try_step("3a  + conn MODE_ID (no CRTC_ID)", objs, props, vals, np);
    push(conn_id, P_CRTC_ID, crtc_id);
    try_step("3b  + conn MODE_ID + CRTC_ID", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    push(conn_id, P_MODE_ID, blob_id);
    push(conn_id, P_CRTC_ID, crtc_id);
    push(161, P_FB_ID, fb_id);
    try_step("4a  + plane161 FB_ID (no CRTC_ID)", objs, props, vals, np);
    push(161, P_CRTC_ID, crtc_id);
    try_step("4b  + plane161 FB_ID + CRTC_ID", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    push(conn_id, P_MODE_ID, blob_id);
    push(conn_id, P_CRTC_ID, crtc_id);
    push(161, P_FB_ID, fb_id);
    push(161, P_CRTC_ID, crtc_id);
    push(161, P_SRC_X, 0);
    push(161, P_SRC_Y, 0);
    push(161, P_SRC_W, (uint64_t)map_w << FP);
    push(161, P_SRC_H, (uint64_t)map_h << FP);
    push(161, P_CRTC_X, 0);
    push(161, P_CRTC_Y, 0);
    push(161, P_CRTC_W, map_w);
    push(161, P_CRTC_H, map_h);
    try_step("5a  + plane161 full-frame coords", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    push(conn_id, P_MODE_ID, blob_id);
    push(conn_id, P_CRTC_ID, crtc_id);
    push(161, P_FB_ID, fb_id);
    push(161, P_CRTC_ID, crtc_id);
    push(161, P_SRC_X, 0);
    push(161, P_SRC_Y, 0);
    push(161, P_SRC_W, (uint64_t)(map_w / 2) << FP);
    push(161, P_SRC_H, (uint64_t)map_h << FP);
    push(161, P_CRTC_X, 0);
    push(161, P_CRTC_Y, 0);
    push(161, P_CRTC_W, map_w / 2);
    push(161, P_CRTC_H, map_h);
    push(157, P_FB_ID, fb_id);
    push(157, P_CRTC_ID, crtc_id);
    push(157, P_SRC_X, (uint64_t)(map_w / 2) << FP);
    push(157, P_SRC_Y, 0);
    push(157, P_SRC_W, (uint64_t)(map_w / 2) << FP);
    push(157, P_SRC_H, (uint64_t)map_h << FP);
    push(157, P_CRTC_X, map_w / 2);
    push(157, P_CRTC_Y, 0);
    push(157, P_CRTC_W, map_w / 2);
    push(157, P_CRTC_H, map_h);
    try_step("5b  dual-plane split 161|157", objs, props, vals, np);

    /* variants: which FB_ID id on plane */
    np = 0;
    push(crtc_id, P_ACTIVE, 1);
    push(crtc_id, P_MODE_ID, blob_id);
    push(conn_id, P_MODE_ID, blob_id);
    push(conn_id, P_CRTC_ID, crtc_id);
    push(161, 34, fb_id);
    push(161, P_CRTC_ID, crtc_id);
    try_step("6a  plane161 vendor FB_ID(34)+CRTC_ID", objs, props, vals, np);

    np = 0;
    push(conn_id, P_MODE_ID, blob_id);
    push(conn_id, P_CRTC_ID, crtc_id);
    try_step("7a  conn only (no crtc props)", objs, props, vals, np);

    np = 0;
    push(crtc_id, P_ACTIVE, 0);
    try_step("7b  crtc ACTIVE=0 (teardown check)", objs, props, vals, np);

    printf("\nDONE\n");
    return 0;
}

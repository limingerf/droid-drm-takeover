/* kmspaint.c — 最小 KMS 提交：往面板上画一个"已知图案"，用来判断
 * 扫出（scanout）链路本身是否正常。
 *
 * 为什么需要它：
 *   fbdump 证明 KWin 把**正确的桌面**写进了 framebuffer，但物理面板是彩色噪声。
 *   ⇒ 问题在扫出链路（DPU/DSI/DSC），不在渲染。
 *   这个工具绕开 KWin，用最简单的平面配置 + 最少的非原子属性，
 *   画一个我们自己完全清楚的图案。面板上看到什么，就能反推链路哪里错。
 *
 * 图案：上半屏纯红 (255,0,0)，下半屏纯绿 (0,255,0)，左上角 200x200 纯蓝块。
 *   - 颜色对 → 说明扫出正常，问题在 KWin 的提交
 *   - 颜色互换 → 通道顺序（格式）错
 *   - 位置错/斜 → 步长(pitch)或源偏移错
 *   - 还是噪声 → DSI/DSC 链路问题
 *
 * 关键：必须像 kwinwrap 那样补上 4 个**非 ATOMIC** 平面属性
 *   （blend_op / alpha / zpos / rotation），否则 SDE 直接 EINVAL。
 *
 * usage: kmspaint <card> [--crtc=N] [--seconds=N] [--dual]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>

static int fd;
static uint32_t conn_id, crtc_id, fb_id, fb_w, fb_h, plane1, plane2, crtc_override;

static uint32_t find_prop(uint32_t obj, uint32_t type, const char *name) {
    drmModeObjectProperties *p = drmModeObjectGetProperties(fd, obj, type);
    if (!p) return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < p->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, p->props[i]);
        if (!pr) continue;
        if (strcmp(pr->name, name) == 0) id = pr->prop_id;
        drmModeFreeProperty(pr);
        if (id) break;
    }
    drmModeFreeObjectProperties(p);
    return id;
}

static int setp(uint32_t obj, uint32_t type, const char *name, uint64_t v) {
    uint32_t pr = find_prop(obj, type, name);
    if (!pr) { printf("  找不到属性 %s (obj %u)\n", name, obj); return -1; }
    struct drm_mode_obj_set_property sp = {
        .obj_id = obj, .obj_type = type, .prop_id = pr, .value = v,
    };
    errno = 0;
    int r = ioctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
    printf("  SET %-12s obj=%-4u = %-6llu ret=%d %s\n", name, obj,
           (unsigned long long)v, r, r ? strerror(errno) : "OK");
    return r;
}

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

static void add_plane(drmModeAtomicReq *r, uint32_t pl, uint32_t sx, uint32_t cx,
                      uint32_t w, uint32_t h) {
    drmModeAtomicAddProperty(r, pl, P_CRTC, crtc_id);
    drmModeAtomicAddProperty(r, pl, P_FB, fb_id);
    drmModeAtomicAddProperty(r, pl, P_SX, (uint64_t)sx << 16);
    drmModeAtomicAddProperty(r, pl, P_SY, 0);
    drmModeAtomicAddProperty(r, pl, P_SW, (uint64_t)w << 16);
    drmModeAtomicAddProperty(r, pl, P_SH, (uint64_t)h << 16);
    drmModeAtomicAddProperty(r, pl, P_CX, cx);
    drmModeAtomicAddProperty(r, pl, P_CY, 0);
    drmModeAtomicAddProperty(r, pl, P_CW, w);
    drmModeAtomicAddProperty(r, pl, P_CH, h);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *path = "/dev/dri/card0";
    int secs = 20, dual = 0;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--crtc=", 7)) crtc_override = (uint32_t)strtoul(argv[i] + 7, NULL, 0);
        else if (!strncmp(argv[i], "--seconds=", 10)) secs = atoi(argv[i] + 10);
        else if (!strcmp(argv[i], "--dual")) dual = 1;
        else if (argv[i][0] != '-') path = argv[i];
    }
    fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open: %s\n", strerror(errno)); return 2; }
    if (drmSetMaster(fd)) { printf("SET_MASTER: %s\n", strerror(errno)); return 3; }
    printf("master acquired\n");
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);

    drmModeRes *res = drmModeGetResources(fd);
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED &&
            c->connector_type == DRM_MODE_CONNECTOR_DSI && c->count_modes) { conn = c; break; }
        drmModeFreeConnector(c);
    }
    if (!conn) { printf("no DSI connector\n"); return 7; }
    conn_id = conn->connector_id;
    crtc_id = crtc_override;
    if (!crtc_id && conn->encoder_id) {
        drmModeEncoder *e = drmModeGetEncoder(fd, conn->encoder_id);
        if (e) { crtc_id = e->crtc_id; drmModeFreeEncoder(e); }
    }
    if (!crtc_id) crtc_id = 200;
    printf("conn=%u crtc=%u mode=%s %ux%u\n", conn_id, crtc_id, conn->modes[0].name,
           conn->modes[0].hdisplay, conn->modes[0].vdisplay);
    fb_w = conn->modes[0].hdisplay;
    fb_h = conn->modes[0].vdisplay;

    /* 收集 Primary 平面（type=1） */
    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    uint32_t prim[8]; int nprim = 0;
    for (uint32_t i = 0; i < pr->count_planes && nprim < 8; i++) {
        drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
        if (p) {
            if (p->possible_crtcs) {
                /* type 属性 1 = Primary */
                uint32_t tp = find_prop(p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
                if (tp) {
                    drmModeObjectProperties *op =
                        drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
                    if (op) {
                        for (uint32_t k = 0; k < op->count_props; k++)
                            if (op->props[k] == tp && op->prop_values[k] == 1)
                                prim[nprim++] = p->plane_id;
                        drmModeFreeObjectProperties(op);
                    }
                }
            }
            drmModeFreePlane(p);
        }
    }
    drmModeFreePlaneResources(pr);
    printf("primary planes: %d", nprim);
    for (int i = 0; i < nprim; i++) printf(" %u", prim[i]);
    printf("\n");
    if (nprim < 1) { printf("no primary plane\n"); return 8; }
    plane1 = prim[0];
    plane2 = (nprim > 1) ? prim[1] : 0;

    /* dumb buffer + 图案 */
    struct drm_mode_create_dumb cd = { .width = fb_w, .height = fb_h, .bpp = 32 };
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { printf("create dumb: %s\n", strerror(errno)); return 9; }
    uint32_t handles[4] = { cd.handle }, pitches[4] = { cd.pitch }, offsets[4] = { 0 };
    if (drmModeAddFB2(fd, fb_w, fb_h, DRM_FORMAT_ARGB8888, handles, pitches, offsets, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno)); return 10;
    }
    struct drm_mode_map_dumb md = { .handle = cd.handle };
    drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md);
    size_t sz = (size_t)cd.pitch * fb_h;
    void *map = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
    if (map == MAP_FAILED) { printf("mmap: %s\n", strerror(errno)); return 11; }
    for (uint32_t y = 0; y < fb_h; y++) {
        uint32_t *row = (uint32_t *)((char *)map + (size_t)y * cd.pitch);
        uint32_t c = (y < fb_h / 2) ? 0xffff0000u : 0xff00ff00u;  /* ARGB: 上红下绿 */
        for (uint32_t x = 0; x < fb_w; x++) row[x] = c;
    }
    for (uint32_t y = 0; y < 200 && y < fb_h; y++) {
        uint32_t *row = (uint32_t *)((char *)map + (size_t)y * cd.pitch);
        for (uint32_t x = 0; x < 200 && x < fb_w; x++) row[x] = 0xff0000ffu;  /* 左上蓝块 */
    }
    printf("fb %u %ux%u pitch=%u 图案=上红/下绿/左上蓝\n", fb_id, fb_w, fb_h, cd.pitch);

    /* 非原子平面属性（必须，否则 SDE EINVAL） */
    printf("── 平面非原子属性 ──\n");
    for (int s = 0; s < (dual ? 2 : 1); s++) {
        uint32_t pl = s ? plane2 : plane1;
        if (!pl) continue;
        setp(pl, DRM_MODE_OBJECT_PLANE, "blend_op", 1);
        setp(pl, DRM_MODE_OBJECT_PLANE, "alpha", 255);
        setp(pl, DRM_MODE_OBJECT_PLANE, "zpos", (uint64_t)s);
        setp(pl, DRM_MODE_OBJECT_PLANE, "rotation", 1);
    }
    /* 连接器 DSC */
    setp(conn_id, DRM_MODE_OBJECT_CONNECTOR, "dsc_mode", 1);

    /* 真实提交 */
    uint32_t blob;
    drmModeCreatePropertyBlob(fd, &conn->modes[0], sizeof(conn->modes[0]), &blob);
    drmModeAtomicReq *r = drmModeAtomicAlloc();
    drmModeAtomicAddProperty(r, conn_id, find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID"), crtc_id);
    drmModeAtomicAddProperty(r, crtc_id, P_ACT, 1);
    drmModeAtomicAddProperty(r, crtc_id, P_MODE, blob);
    if (dual && plane2) {
        add_plane(r, plane1, 0, 0, fb_w / 2, fb_h);
        add_plane(r, plane2, fb_w / 2, fb_w / 2, fb_w / 2, fb_h);
    } else {
        add_plane(r, plane1, 0, 0, fb_w, fb_h);
    }
    errno = 0;
    int ret = drmModeAtomicCommit(fd, r, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
    printf("COMMIT %s ret=%d %s\n", dual ? "双平面拆分" : "单平面全宽", ret,
           ret ? strerror(errno) : "OK");
    if (ret == 0) sleep(secs);
    drmModeAtomicFree(r);
    munmap(map, sz);
    drmModeRmFB(fd, fb_id);
    drmModeDestroyDumbBuffer(fd, cd.handle);
    drmDropMaster(fd);
    close(fd);
    printf("KMSPAINT_DONE\n");
    return ret ? 1 : 0;
}

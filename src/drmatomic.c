/* drmatomic.c — KMS takeover via atomic commit, replicating the stock
 * composer's dual-pipe split: two SSPP planes each scan half the panel from
 * the same linear framebuffer (legacy SetCrtc only binds one implicit
 * primary plane and leaves the composer's split mixers fed with junk).
 * usage: drmatomic [card] [seconds]
 */
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

/* The kernel gates every atomic ioctl on file_priv->atomic: without
 * DRM_CLIENT_CAP_ATOMIC set on our fd, any property in the request returns a
 * bare -EINVAL (rawprobe A-K proved this). Once the cap is on, the core atomic
 * props (global IDs 9..23 below) are accepted even though per-object
 * enumeration does not list them. Verified IDs on this device: */
static uint32_t hardcoded_prop_id(const char *name, uint32_t obj_type) {
    struct { const char *n; uint32_t id; } tbl[] = {
        {"SRC_X", 9}, {"SRC_Y", 10}, {"SRC_W", 11}, {"SRC_H", 12},
        {"CRTC_X", 13}, {"CRTC_Y", 14}, {"CRTC_W", 15}, {"CRTC_H", 16},
        {"FB_ID", 17}, {"FB", 17},
        {"CRTC_ID", 20}, {"FB_DAMAGE_CLIPS", 21},
        {"ACTIVE", 22}, {"MODE_ID", 23},
    };
    /* plane FB may instead be vendor prop 34 ("FB_ID" flags=RANGE, legacy) */
    for (unsigned i = 0; i < sizeof(tbl) / sizeof(tbl[0]); i++)
        if (strcmp(tbl[i].n, name) == 0) return tbl[i].id;
    return 0;
}

static uint32_t find_prop(int fd, uint32_t obj, uint32_t obj_type,
                          const char *name) {
    drmModeObjectProperties *p =
        drmModeObjectGetProperties(fd, obj, obj_type);
    if (!p) return hardcoded_prop_id(name, obj_type);
    uint32_t id = 0;
    for (uint32_t i = 0; i < p->count_props && !id; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, p->props[i]);
        if (pr) {
            if (strcmp(pr->name, name) == 0) id = pr->prop_id;
            drmModeFreeProperty(pr);
        }
    }
    drmModeFreeObjectProperties(p);
    if (!id) id = hardcoded_prop_id(name, obj_type);
    return id;
}

static uint64_t prop_value(int fd, uint32_t obj, uint32_t obj_type,
                           const char *name) {
    drmModeObjectProperties *p =
        drmModeObjectGetProperties(fd, obj, obj_type);
    if (!p) return (uint64_t)-1;
    uint64_t val = (uint64_t)-1;
    for (uint32_t i = 0; i < p->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, p->props[i]);
        if (pr) {
            if (strcmp(pr->name, name) == 0) val = p->prop_values[i];
            drmModeFreeProperty(pr);
            if (val != (uint64_t)-1) break;
        }
    }
    drmModeFreeObjectProperties(p);
    return val;
}

#define FP 16 /* fixed-point shift for plane coords */

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/dri/card0";
    int secs = argc > 2 ? atoi(argv[2]) : 60;
    int fd = open(path, O_RDWR);
    if (fd < 0) { printf("open %s: %s\n", path, strerror(errno)); return 2; }
    if (drmSetMaster(fd)) {
        printf("SETMASTER failed: %s\n", strerror(errno));
        return 3;
    }
    printf("master acquired\n");
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)) {
        printf("SET_CAP UNIVERSAL_PLANES: %s\n", strerror(errno));
        return 4;
    }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        printf("SET_CAP ATOMIC: %s\n", strerror(errno));
        return 5;
    }
    printf("client caps ATOMIC+UNIVERSAL_PLANES set\n");

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { printf("GetResources failed\n"); return 4; }
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED &&
            c->connector_type == DRM_MODE_CONNECTOR_DSI && c->count_modes) {
            conn = c;
            break;
        }
        drmModeFreeConnector(c);
    }
    if (!conn) { printf("no DSI connector\n"); return 5; }

    uint32_t crtc_id = 0;
    if (conn->encoder_id) {
        drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
        if (enc) { crtc_id = enc->crtc_id; drmModeFreeEncoder(enc); }
    }
    if (!crtc_id) { printf("crtc not bound to encoder\n"); return 6; }
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (!pc || !pc->mode_valid) { printf("crtc has no active mode\n"); return 7; }
    drmModeModeInfo mode = pc->mode;
    drmModeFreeCrtc(pc);
    printf("crtc %u mode %s %dx%d\n", crtc_id, mode.name,
           mode.hdisplay, mode.vdisplay);

    /* find planes usable on this crtc */
    int crtc_idx = -1;
    for (int i = 0; i < res->count_crtcs; i++)
        if (res->crtcs[i] == crtc_id) crtc_idx = i;
    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (!pres) { printf("GetPlaneResources failed\n"); return 8; }
    uint32_t planes[8]; int nplanes = 0;
    uint32_t other_planes[32]; int n_other = 0;
    for (uint32_t i = 0; i < pres->count_planes; i++) {
        uint32_t pid = pres->planes[i];
        drmModePlane *pl = drmModeGetPlane(fd, pid);
        if (!pl) continue;
        uint64_t ptype = prop_value(fd, pid, DRM_MODE_OBJECT_PLANE, "type");
        /* modern DPU leaves possible_crtcs empty; 0 means "any" */
        bool ok_crtc = pl->possible_crtcs == 0 ||
                       (crtc_idx < 0) || (pl->possible_crtcs & (1u << crtc_idx));
        printf("plane %u type=%llu poss_crtc=0x%x fb=%u crtc=%u ok=%d\n",
               pid, (unsigned long long)ptype, pl->possible_crtcs,
               pl->fb_id, pl->crtc_id, ok_crtc);
        if (ok_crtc) {
            if (pl->fb_id && n_other < 32)
                other_planes[n_other++] = pid;
            if (ptype == DRM_PLANE_TYPE_PRIMARY || ptype == 0 ||
                ptype == (uint64_t)-1) {
                if (nplanes < 8) planes[nplanes++] = pid;
            }
        }
        drmModeFreePlane(pl);
    }
    /* the composer's split pipes are 157 (right half) and 161 (left half);
     * use them if present at all, even if typed OVERLAY */
    bool has157 = false, has161 = false;
    for (uint32_t i = 0; i < pres->count_planes; i++) {
        if (pres->planes[i] == 157) has157 = true;
        if (pres->planes[i] == 161) has161 = true;
    }
    if (has157 && has161) {
        planes[0] = 161; /* left half */
        planes[1] = 157; /* right half */
        if (nplanes < 2) nplanes = 2;
    }
    printf("primary planes: %d [", nplanes);
    for (int i = 0; i < nplanes; i++) printf("%u%s", planes[i], i + 1 < nplanes ? "," : "");
    printf("]  to-disable: %d\n", n_other);
    if (nplanes < 2) {
        printf("need two primary pipes for the split mixers\n");
        return 9;
    }

    /* dumb fb, full panel */
    struct drm_mode_create_dumb cd = {0};
    cd.width = mode.hdisplay; cd.height = mode.vdisplay; cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        printf("create_dumb: %s\n", strerror(errno)); return 10;
    }
    uint32_t handles[4] = {cd.handle}, pitches[4] = {cd.pitch}, offsets[4] = {0};
    uint32_t fb_id = 0;
    if (drmModeAddFB2(fd, cd.width, cd.height, DRM_FORMAT_XRGB8888,
                      handles, pitches, offsets, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno)); return 11;
    }
    struct drm_mode_map_dumb md = {0};
    md.handle = cd.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        printf("map_dumb: %s\n", strerror(errno)); return 12;
    }
    size_t size = (size_t)cd.pitch * cd.height;
    volatile uint32_t *map = mmap(NULL, size, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, md.offset);
    if (map == MAP_FAILED) { printf("mmap: %s\n", strerror(errno)); return 13; }

    static const uint32_t bands[] = {
        0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00,
        0xFF00FF, 0xFF0000, 0x0000FF, 0x000000
    };
    for (unsigned y = 0; y < cd.height; y++) {
        uint32_t c = bands[(size_t)y * 8 / cd.height];
        if (y < 8) c = 0xFF00FF;
        if (y >= cd.height - 8) c = 0x00FF00;
        volatile uint32_t *row = (volatile uint32_t *)
            ((char *)map + (size_t)y * cd.pitch);
        for (unsigned x = 0; x < cd.width; x++) row[x] = 0xFF000000u | c;
    }
    /* flush CPU caches into DRAM: display does not snoop them */
    {
        size_t n = 128u << 20;
        char *t = mmap(NULL, n, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (t != MAP_FAILED) {
            for (int pass = 0; pass < 2; pass++)
                for (size_t i = 0; i < n; i += 64) t[i] = 1;
            munmap(t, n);
        }
    }
    printf("fb %u filled, readback first=0x%08X last=0x%08X\n",
           fb_id, map[0], map[(size_t)(cd.height - 1) * cd.pitch / 4 + cd.width - 1]);

    uint32_t blob_id = 0;
    if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &blob_id)) {
        printf("mode blob: %s\n", strerror(errno)); return 14;
    }

    drmModeAtomicReq *req = drmModeAtomicAlloc();
    uint32_t c_crtc_id = find_prop(fd, conn->connector_id,
                                   DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
    uint32_t k_active = find_prop(fd, crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
    uint32_t k_mode = find_prop(fd, crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
    if (!c_crtc_id || !k_active) {
        printf("missing atomic props\n"); return 15;
    }

    uint32_t p_crtc = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "CRTC_ID");
    uint32_t p_sx = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "SRC_X");
    uint32_t p_sy = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "SRC_Y");
    uint32_t p_sw = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "SRC_W");
    uint32_t p_sh = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "SRC_H");
    uint32_t p_cx = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "CRTC_X");
    uint32_t p_cy = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "CRTC_Y");
    uint32_t p_cw = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "CRTC_W");
    uint32_t p_ch = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "CRTC_H");
    if (!p_crtc || !p_sx || !p_sw) {
        printf("plane missing standard props\n"); return 16;
    }
    /* Core plane FB_ID is global prop 17 but its flags say IMMUTABLE on this
     * build; vendor prop 34 is the second candidate. Try both. */
    uint32_t plane_fb_ids[2] = { find_prop(fd, planes[0],
                                           DRM_MODE_OBJECT_PLANE, "FB"),
                                 34 };
    if (plane_fb_ids[0] == 34) plane_fb_ids[1] = 0;
    int ret = -1;
    for (int attempt = 0; attempt < 2 && ret != 0; attempt++) {
        uint32_t fb_pid = plane_fb_ids[attempt];
        if (!fb_pid) continue;
        drmModeAtomicReq *r = drmModeAtomicAlloc();
        uint32_t half_w = mode.hdisplay / 2;
        drmModeAtomicAddProperty(r, conn->connector_id, c_crtc_id, crtc_id);
        /* NO connector MODE_ID: connector 67 has no mode_id prop on this
         * vendor kernel (rawprobe L: ENOENT on global 23; full enumeration
         * of its 32 props shows none). Mode is set CRTC-side only. */
        drmModeAtomicAddProperty(r, crtc_id, k_active, 1);
        if (k_mode) drmModeAtomicAddProperty(r, crtc_id, k_mode, blob_id);
        for (int i = 0; i < 2; i++) {
            uint32_t pid = planes[i];
            drmModeAtomicAddProperty(r, pid, fb_pid, fb_id);
            drmModeAtomicAddProperty(r, pid, p_crtc, crtc_id);
            drmModeAtomicAddProperty(r, pid, p_sx, (uint64_t)i * half_w << FP);
            drmModeAtomicAddProperty(r, pid, p_sy, 0);
            drmModeAtomicAddProperty(r, pid, p_sw, (uint64_t)half_w << FP);
            drmModeAtomicAddProperty(r, pid, p_sh, (uint64_t)mode.vdisplay << FP);
            drmModeAtomicAddProperty(r, pid, p_cx, (uint64_t)i * half_w);
            drmModeAtomicAddProperty(r, pid, p_cy, 0);
            drmModeAtomicAddProperty(r, pid, p_cw, (uint64_t)half_w);
            drmModeAtomicAddProperty(r, pid, p_ch, (uint64_t)mode.vdisplay);
        }
        for (int i = 0; i < n_other; i++) {
            uint32_t pid = other_planes[i];
            if (pid == planes[0] || pid == planes[1]) continue;
            drmModeAtomicAddProperty(r, pid, fb_pid, 0);
            drmModeAtomicAddProperty(r, pid, p_crtc, 0);
        }
        ret = drmModeAtomicCommit(fd, r,
                                  DRM_MODE_ATOMIC_ALLOW_MODESET |
                                  DRM_MODE_ATOMIC_TEST_ONLY, NULL);
        printf("attempt %u: plane FB prop id %u -> TEST_ONLY ret=%d (%s)\n",
               attempt, fb_pid, ret, ret ? strerror(errno) : "ok");
        if (ret == 0) {
            req = r;
            break;
        }
        drmModeAtomicFree(r);
    }
    if (ret) return 17;
    ret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
    printf("COMMIT ret=%d (%s)\n", ret, ret ? strerror(errno) : "ok");
    if (ret) return 18;

    sleep(secs);
    printf("DRMATOMIC DONE\n");
    return 0;
}

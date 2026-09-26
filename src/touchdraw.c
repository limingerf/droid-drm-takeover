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
#include <sys/select.h>
#include <time.h>
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
    setvbuf(stdout, NULL, _IOLBF, 0);
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
    /* Stopping Android detaches the connector from its encoder. Recover the
     * DSI encoder and CRTC from the resource topology in that state. */
    if (!crtc_id) {
        for (int i = 0; i < res->count_encoders && !crtc_id; i++) {
            drmModeEncoder *enc = drmModeGetEncoder(fd, res->encoders[i]);
            if (enc && enc->encoder_type == DRM_MODE_ENCODER_DSI) {
                for (int j = 0; j < res->count_crtcs; j++) {
                    if (enc->possible_crtcs & (1u << j)) {
                        crtc_id = res->crtcs[j];
                        break;
                    }
                }
            }
            if (enc) drmModeFreeEncoder(enc);
        }
    }
    if (!crtc_id) { printf("no DSI CRTC in encoder topology\n"); return 6; }
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (!pc) { printf("get crtc failed: %s\n", strerror(errno)); return 7; }
    drmModeModeInfo mode = pc->mode;
    bool mode_valid = pc->mode_valid;
    drmModeFreeCrtc(pc);
    if (!mode_valid) {
        bool found = false;
        for (int i = 0; i < conn->count_modes; i++) {
            if (conn->modes[i].vrefresh == 60) {
                mode = conn->modes[i];
                found = true;
                break;
            }
        }
        if (!found && conn->count_modes) mode = conn->modes[0];
    }
    printf("crtc %u mode %s %dx%d\n", crtc_id, mode.name,
           mode.hdisplay, mode.vdisplay);
    /* Discover the primary planes at runtime. The vendor driver exposes all
     * primary planes as usable by the connected CRTC; the first two form the
     * panel's left and right scanout pipes. */
    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (!pres) { printf("GetPlaneResources failed\n"); return 8; }
    uint32_t planes[8]; int nplanes = 0;
    for (uint32_t i = 0; i < pres->count_planes; i++) {
        uint32_t pid = pres->planes[i];
        drmModePlane *pl = drmModeGetPlane(fd, pid);
        if (!pl) continue;
        uint64_t ptype = prop_value(fd, pid, DRM_MODE_OBJECT_PLANE, "type");
        if (ptype == DRM_PLANE_TYPE_PRIMARY && nplanes < 8) {
            planes[nplanes++] = pid;
            printf("primary plane %u\n", pid);
        }
        drmModeFreePlane(pl);
    }
    printf("primary planes: %d [", nplanes);
    for (int i = 0; i < nplanes; i++)
        printf("%u%s", planes[i], i + 1 < nplanes ? "," : "");
    printf("]\n");
    if (nplanes < 2) {
        printf("need two primary planes for the split mixers\n");
        return 9;
    }
    printf("using primary planes %u,%u\n", planes[0], planes[1]);
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
    uint32_t p_fb = find_prop(fd, planes[0], DRM_MODE_OBJECT_PLANE, "FB_ID");
    if (!p_crtc || !p_fb || !p_sx || !p_sy || !p_sw || !p_sh ||
        !p_cx || !p_cy || !p_cw || !p_ch || !k_mode) {
        printf("plane or CRTC atomic properties missing\n");
        return 16;
    }

    drmModeAtomicReq *req = drmModeAtomicAlloc();
    if (!req) { printf("atomic alloc failed\n"); return 16; }

    uint32_t half_w = mode.hdisplay / 2;
    /* Keep the same property order as the accepted vendor atomic request. */
    drmModeAtomicAddProperty(req, crtc_id, k_active, 1);
    drmModeAtomicAddProperty(req, crtc_id, k_mode, blob_id);
    /* This connector has no MODE_ID property. The mode is set on the CRTC. */
    drmModeAtomicAddProperty(req, conn->connector_id, c_crtc_id, crtc_id);
    for (int i = 0; i < 2; i++) {
        uint32_t pid = planes[i];
        drmModeAtomicAddProperty(req, pid, p_fb, fb_id);
        drmModeAtomicAddProperty(req, pid, p_crtc, crtc_id);
        drmModeAtomicAddProperty(req, pid, p_sx, (uint64_t)i * half_w << FP);
        drmModeAtomicAddProperty(req, pid, p_sy, 0);
        drmModeAtomicAddProperty(req, pid, p_sw, (uint64_t)half_w << FP);
        drmModeAtomicAddProperty(req, pid, p_sh, (uint64_t)mode.vdisplay << FP);
        drmModeAtomicAddProperty(req, pid, p_cx, (uint64_t)i * half_w);
        drmModeAtomicAddProperty(req, pid, p_cy, 0);
        drmModeAtomicAddProperty(req, pid, p_cw, (uint64_t)half_w);
        drmModeAtomicAddProperty(req, pid, p_ch, (uint64_t)mode.vdisplay);
    }
    int ret = drmModeAtomicCommit(fd, req,
                                  DRM_MODE_ATOMIC_ALLOW_MODESET |
                                  DRM_MODE_ATOMIC_TEST_ONLY, NULL);
    printf("TEST_ONLY dual-plane ret=%d (%s)\n", ret,
           ret ? strerror(errno) : "ok");
    if (ret) return 17;
    ret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
    printf("COMMIT ret=%d (%s)\n", ret, ret ? strerror(errno) : "ok");
    if (ret) return 18;


    /* ---- input takeover: NVT kernel-direct device ----
     * Android's uhid mirror goes silent once surfaceflinger stops. Prefer the
     * event node selected by the wrapper; the NVT-ts coords are 0.01 mm and
     * axes are transposed vs the landscape panel (ABS_X -> panel height,
     * ABS_Y -> panel width); dividing by 100 gives panel pixels. */
    const char *node = getenv("TOUCH_EVENT");
    if (!node || !*node) node = "/dev/input/event11";
    int ifd = open(node, O_RDONLY);
    if (ifd < 0) { printf("open %s: %s\n", node, strerror(errno)); sleep(secs); return 0; }
    printf("touchdraw on %s, %d s, touch the screen\n", node, secs);

    struct { int x, y, on; } slots[10];
    memset(slots, 0, sizeof slots);
    int cur = 0;
    uint32_t *fb32 = (uint32_t *)map;   /* discard volatile: fine, dc-clean below */
    uint32_t pitch32 = cd.pitch / 4;
    static const uint32_t bands2[] = {
        0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00,
        0xFF00FF, 0xFF0000, 0x0000FF, 0x000000
    };
    const int R = 55;

    time_t t_end = time(NULL) + secs;
    long nev = 0, nframe = 0;
    time_t t_mark = time(NULL);
    while (time(NULL) < t_end) {
        fd_set rfds; FD_ZERO(&rfds); FD_SET(ifd, &rfds);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
        int sr = select(ifd + 1, &rfds, NULL, NULL, &tv);
        if (sr <= 0) {
            /* no touch for a while: still run a self-test pass every second
             * (yellow square sweeping) to prove the writeback path works */
            time_t now = time(NULL);
            if (now != t_mark) {
                t_mark = now;
                int cy = 200 + (now % 8) * 200, cx = 400 + (now % 8) * 300;
                for (int dy = -40; dy <= 40; dy++)
                    for (int dx = -40; dx <= 40; dx++)
                        fb32[(size_t)(cy + dy) * pitch32 + cx + dx] = 0xFFFFFF00u;
                char *p = (char *)map;
                for (size_t off = 0; off < size; off += 64)
                    __asm__ volatile("dc civac, %0" :: "r"(p + off));
                __asm__ volatile("dsb sy" ::: "memory");
            }
            continue;
        }
        struct { long ts[2]; unsigned short type, code; int value; } ev[64];
        ssize_t n = read(ifd, ev, sizeof ev);
        if (n <= 0) continue;
        int nsyn = n / (long)sizeof(ev[0]);
        nev += nsyn;
        int dirty = 0;
        for (ssize_t i = 0; i < nsyn; i++) {
            if (ev[i].type == 0 /*EV_SYN*/ && ev[i].code == 0) { dirty = 1; nframe++; continue; }
            if (ev[i].type != 3 /*EV_ABS*/) continue;
            switch (ev[i].code) {
            case 47: /* ABS_MT_SLOT */
                if (ev[i].value >= 0 && ev[i].value < 10) cur = ev[i].value;
                break;
            case 57: /* ABS_MT_TRACKING_ID */
                slots[cur].on = (ev[i].value >= 0);
                break;
            case 53: /* ABS_MT_POSITION_X */ slots[cur].x = ev[i].value; break;
            case 54: /* ABS_MT_POSITION_Y */ slots[cur].y = ev[i].value; break;
            }
        }
        if (!dirty) continue;
        for (unsigned y = 0; y < cd.height; y++) {
            uint32_t c = 0xFF000000u | bands2[(size_t)y * 8 / cd.height];
            uint32_t *row = fb32 + (size_t)y * pitch32;
            for (unsigned x = 0; x < cd.width; x++) row[x] = c;
        }
        for (int s = 0; s < 10; s++) {
            if (!slots[s].on) continue;
            int cx0 = slots[s].y / 100;   /* NVT Y axis -> panel width  (correct) */
            int cy0 = (int)cd.height - 1 - slots[s].x / 100;  /* X axis -> height, flipped */
            for (int dy = -R; dy <= R; dy++) {
                int py = cy0 + dy;
                if (py < 0 || py >= (int)cd.height) continue;
                for (int dx = -R; dx <= R; dx++) {
                    if (dx * dx + dy * dy > R * R) continue;
                    int px = cx0 + dx;
                    if (px < 0 || px >= (int)cd.width) continue;
                    fb32[(size_t)py * pitch32 + px] = 0xFFFFFFFFu;
                }
            }
        }
        char *p = (char *)map;
        for (size_t off = 0; off < size; off += 64)
            __asm__ volatile("dc civac, %0" :: "r"(p + off));
        __asm__ volatile("dsb sy" ::: "memory");
    }
    close(ifd);
    printf("events=%ld frames=%ld\n", nev, nframe);
    printf("TOUCHDRAW DONE\n");
    return 0;
}

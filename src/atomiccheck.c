/* atomiccheck.c - dynamic KMS atomic probe for the connected DSI panel.
 *
 * This tool intentionally does not hardcode the panel, CRTC, mode, or plane
 * IDs. It discovers the live DSI topology, then tests increasingly complete
 * atomic states with TEST_ONLY before optionally performing one real commit.
 *
 * usage: atomiccheck [card] [--commit-seconds=N]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm.h>
#include <drm_fourcc.h>

#define FP 16

static int fd;
static uint32_t conn_id, crtc_id, mode_blob, fb_id;
static uint32_t p_fb_id, p_crtc_id, p_sx, p_sy, p_sw, p_sh;
static uint32_t p_cx, p_cy, p_cw, p_ch;
static uint32_t c_crtc_id, c_dpms;
static uint32_t k_active, k_mode_id;
static uint32_t plane1, plane2;
static bool have_plane2;
static uint32_t fb_w, fb_h;

static uint32_t find_prop(uint32_t obj, uint32_t type, const char *name) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    if (!props)
        return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, props->props[i]);
        if (pr) {
            if (strcmp(pr->name, name) == 0)
                id = pr->prop_id;
            drmModeFreeProperty(pr);
        }
        if (id)
            break;
    }
    drmModeFreeObjectProperties(props);
    return id;
}

static uint64_t prop_value(uint32_t obj, uint32_t type, const char *name) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    if (!props)
        return (uint64_t)-1;
    uint64_t value = (uint64_t)-1;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, props->props[i]);
        if (pr) {
            if (strcmp(pr->name, name) == 0)
                value = props->prop_values[i];
            drmModeFreeProperty(pr);
        }
        if (value != (uint64_t)-1)
            break;
    }
    drmModeFreeObjectProperties(props);
    return value;
}

static int addp(drmModeAtomicReq *req, const char *label, uint32_t obj,
                uint32_t prop, uint64_t val) {
    if (!prop) {
        printf("  missing %s (obj=%u)\n", label, obj);
        return -1;
    }
    if (drmModeAtomicAddProperty(req, obj, prop, val) < 0) {
        printf("  AddProperty(%s obj=%u prop=%u) failed: %s\n", label, obj,
               prop, strerror(errno));
        return -1;
    }
    return 0;
}

static void add_base(drmModeAtomicReq *req, bool with_conn, bool with_mode) {
    addp(req, "crtc.ACTIVE", crtc_id, k_active, 1);
    if (with_mode)
        addp(req, "crtc.MODE_ID", crtc_id, k_mode_id, mode_blob);
    if (with_conn)
        addp(req, "conn.CRTC_ID", conn_id, c_crtc_id, crtc_id);
}

static int add_plane(drmModeAtomicReq *req, uint32_t plane, uint32_t x,
                     uint32_t y, uint32_t w, uint32_t h, uint32_t src_x,
                     uint32_t src_y) {
    if (addp(req, "plane.FB_ID", plane, p_fb_id, fb_id) ||
        addp(req, "plane.CRTC_ID", plane, p_crtc_id, crtc_id) ||
        addp(req, "plane.SRC_X", plane, p_sx, (uint64_t)src_x << FP) ||
        addp(req, "plane.SRC_Y", plane, p_sy, (uint64_t)src_y << FP) ||
        addp(req, "plane.SRC_W", plane, p_sw, (uint64_t)w << FP) ||
        addp(req, "plane.SRC_H", plane, p_sh, (uint64_t)h << FP) ||
        addp(req, "plane.CRTC_X", plane, p_cx, x) ||
        addp(req, "plane.CRTC_Y", plane, p_cy, y) ||
        addp(req, "plane.CRTC_W", plane, p_cw, w) ||
        addp(req, "plane.CRTC_H", plane, p_ch, h))
        return -1;
    return 0;
}

static void run_case(const char *label, bool with_conn, bool with_mode,
                     bool with_plane, bool dual, bool with_dpms,
                     bool allow_modeset) {
    drmModeAtomicReq *req = drmModeAtomicAlloc();
    if (!req) {
        printf("%-48s alloc failed\n", label);
        return;
    }
    int bad = 0;
    add_base(req, with_conn, with_mode);
    if (with_dpms)
        bad |= addp(req, "conn.DPMS", conn_id, c_dpms, 0);
    if (with_plane) {
        uint32_t half = fb_w / 2;
        if (dual && have_plane2) {
            bad |= add_plane(req, plane1, 0, 0, half, fb_h, 0, 0);
            bad |= add_plane(req, plane2, half, 0, half, fb_h, half, 0);
        } else {
            bad |= add_plane(req, plane1, 0, 0, fb_w, fb_h, 0, 0);
        }
    }
    if (bad) {
        drmModeAtomicFree(req);
        return;
    }
    uint32_t flags = DRM_MODE_ATOMIC_TEST_ONLY;
    if (allow_modeset)
        flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
    errno = 0;
    int ret = drmModeAtomicCommit(fd, req, flags, NULL);
    printf("%-48s ret=%d errno=%d (%s)\n", label, ret, errno,
           ret ? strerror(errno) : "OK");
    drmModeAtomicFree(req);
}

static int make_framebuffer(void) {
    struct drm_mode_create_dumb cd = { 0 };
    cd.width = fb_w;
    cd.height = fb_h;
    cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        printf("create dumb: %s\n", strerror(errno));
        return -1;
    }
    uint32_t handles[4] = { cd.handle }, pitches[4] = { cd.pitch };
    uint32_t offsets[4] = { 0 };
    if (drmModeAddFB2(fd, cd.width, cd.height, DRM_FORMAT_XRGB8888,
                      handles, pitches, offsets, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno));
        return -1;
    }
    struct drm_mode_map_dumb md = { 0 };
    md.handle = cd.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        printf("map dumb: %s\n", strerror(errno));
        return -1;
    }
    size_t size = (size_t)cd.pitch * cd.height;
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     md.offset);
    if (map == MAP_FAILED) {
        printf("mmap: %s\n", strerror(errno));
        return -1;
    }
    static const uint32_t bands[] = {
        0x00ffff, 0xffff00, 0x00ff00, 0xff00ff,
        0xff0000, 0x0000ff, 0xffffff, 0x000000
    };
    for (uint32_t y = 0; y < cd.height; y++) {
        uint32_t color = 0xff000000u | bands[(size_t)y * 8 / cd.height];
        uint32_t *row = (uint32_t *)((char *)map + (size_t)y * cd.pitch);
        for (uint32_t x = 0; x < cd.width; x++)
            row[x] = color;
    }
    printf("fb=%u %ux%u pitch=%u\n", fb_id, cd.width, cd.height, cd.pitch);
    munmap(map, size);
    return 0;
}

static int find_primary_planes(uint32_t *out, unsigned cap) {
    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (!pres) {
        printf("get plane resources: %s\n", strerror(errno));
        return -1;
    }
    unsigned n = 0;
    for (uint32_t i = 0; i < pres->count_planes && n < cap; i++) {
        drmModePlane *pl = drmModeGetPlane(fd, pres->planes[i]);
        if (!pl)
            continue;
        uint64_t type = prop_value(pres->planes[i], DRM_MODE_OBJECT_PLANE,
                                   "type");
        if (type == DRM_PLANE_TYPE_PRIMARY)
            out[n++] = pres->planes[i];
        drmModeFreePlane(pl);
    }
    drmModeFreePlaneResources(pres);
    return (int)n;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *path = "/dev/dri/card0";
    int commit_secs = 0;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--commit-seconds=", 17) == 0)
            commit_secs = atoi(argv[i] + 17);
        else if (argv[i][0] != '-')
            path = argv[i];
    }

    fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        printf("open %s: %s\n", path, strerror(errno));
        return 2;
    }
    if (drmSetMaster(fd)) {
        printf("SET_MASTER: %s\n", strerror(errno));
        return 3;
    }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
        drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        printf("set client caps: %s\n", strerror(errno));
        return 4;
    }
    printf("master acquired\n");

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) {
        printf("get resources: %s\n", strerror(errno));
        return 5;
    }
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c)
            continue;
        if (c->connection == DRM_MODE_CONNECTED &&
            c->connector_type == DRM_MODE_CONNECTOR_DSI && c->count_modes) {
            conn = c;
            break;
        }
        drmModeFreeConnector(c);
    }
    if (!conn) {
        printf("no connected DSI connector\n");
        return 6;
    }
    conn_id = conn->connector_id;
    if (conn->encoder_id) {
        drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
        if (enc) {
            crtc_id = enc->crtc_id;
            drmModeFreeEncoder(enc);
        }
    }
    if (!crtc_id) {
        printf("DSI connector has no bound CRTC\n");
        return 7;
    }
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (!pc) {
        printf("get crtc %u: %s\n", crtc_id, strerror(errno));
        return 8;
    }
    drmModeModeInfo mode = pc->mode;
    if (!pc->mode_valid && conn->count_modes)
        mode = conn->modes[0];

    drmModeFreeCrtc(pc);
    fb_w = mode.hdisplay;
    fb_h = mode.vdisplay;
    printf("conn=%u crtc=%u mode=%s %ux%u\n", conn_id, crtc_id, mode.name,
           fb_w, fb_h);

    c_crtc_id = find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
    c_dpms = find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
    k_active = find_prop(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
    k_mode_id = find_prop(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
    printf("props conn: CRTC_ID=%u DPMS=%u; crtc: ACTIVE=%u MODE_ID=%u\n",
           c_crtc_id, c_dpms, k_active, k_mode_id);

    uint32_t planes[32];
    int nplanes = find_primary_planes(planes, 32);
    if (nplanes <= 0) {
        printf("no primary planes\n");
        return 9;
    }
    plane1 = planes[0];
    plane2 = nplanes > 1 ? planes[1] : 0;
    have_plane2 = plane2 != 0;
    printf("primary planes: %d [", nplanes);
    for (int i = 0; i < nplanes; i++)
        printf("%s%u", i ? "," : "", planes[i]);
    printf("] using %u%s%u\n", plane1, have_plane2 ? "," : "", plane2);

    p_fb_id = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "FB_ID");
    p_crtc_id = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
    p_sx = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "SRC_X");
    p_sy = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "SRC_Y");
    p_sw = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "SRC_W");
    p_sh = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "SRC_H");
    p_cx = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "CRTC_X");
    p_cy = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
    p_cw = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "CRTC_W");
    p_ch = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "CRTC_H");
    printf("plane1 props: FB_ID=%u CRTC_ID=%u SRC=%u,%u,%u,%u CRTC=%u,%u,%u,%u\n",
           p_fb_id, p_crtc_id, p_sx, p_sy, p_sw, p_sh, p_cx, p_cy, p_cw, p_ch);

    if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &mode_blob)) {
        printf("create mode blob: %s\n", strerror(errno));
        return 10;
    }
    printf("mode blob=%u\n", mode_blob);

    if (make_framebuffer())
        return 11;

    printf("\n== TEST_ONLY ==\n");
    run_case("empty", false, false, false, false, false, false);
    run_case("crtc ACTIVE", false, false, false, false, false, false);
    run_case("crtc ACTIVE+MODE", false, true, false, false, false, false);
    run_case("+conn CRTC", true, true, false, false, false, false);
    run_case("current mode + plane1", true, false, true, false, false, false);
    run_case("current mode + split planes", true, false, true, true, false, false);
    run_case("+plane1 FB+CRTC", true, true, true, false, false, false);
    run_case("+plane1 full rects", true, true, true, false, false, false);
    run_case("+plane1 full rects allow modeset", true, true, true, false,
             false, true);
    if (have_plane2) {
        run_case("+plane1+plane2 split", true, true, true, true, false, false);
        run_case("+plane1+plane2 split allow modeset", true, true, true, true,
                 false, true);
    }
    run_case("+conn DPMS=0 (diagnostic)", true, true, true, false, true, true);

    if (commit_secs > 0) {
        printf("\n== REAL COMMIT ==\n");
        drmModeAtomicReq *req = drmModeAtomicAlloc();
        add_base(req, true, true);
        if (have_plane2) {
            uint32_t half = fb_w / 2;
            add_plane(req, plane1, 0, 0, half, fb_h, 0, 0);
            add_plane(req, plane2, half, 0, half, fb_h, half, 0);
        } else {
            add_plane(req, plane1, 0, 0, fb_w, fb_h, 0, 0);
        }
        errno = 0;
        int ret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET,
                                      NULL);
        printf("real %s commit ret=%d errno=%d (%s)\n",
               have_plane2 ? "dual-plane" : "single-plane", ret, errno,
               ret ? strerror(errno) : "OK");
        if (ret == 0)
            sleep(commit_secs);
        drmModeAtomicFree(req);
    }

    drmModeRmFB(fd, fb_id);
    drmModeDestroyPropertyBlob(fd, mode_blob);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    drmDropMaster(fd);
    close(fd);
    printf("ATOMICCHECK DONE\n");
    return 0;
}

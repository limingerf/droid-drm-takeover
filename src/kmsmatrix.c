/* kmsmatrix.c - dynamic atomic commit matrix for the connected DSI panel.
 *
 * This probe is intentionally device-independent: it discovers the connected
 * DSI connector, its CRTC, the current mode, and the primary planes at runtime.
 * It then walks a small matrix of TEST_ONLY commits to find the exact minimum
 * state this vendor KMS driver accepts, optionally performs one real commit,
 * and prints every ioctl result.
 *
 * usage: kmsmatrix [card] [--commit-seconds=N] [--no-plane2]
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

typedef struct {
    uint32_t id;
    uint32_t crtc_id;
    uint32_t mode_blob;
    drmModeModeInfo mode;
} ConnInfo;

static int fd;
static uint32_t c_crtc_id, c_dpms, c_mode_id;
static uint32_t k_active, k_mode_id;
static uint32_t p_fb_id, p_crtc_id, p_sx, p_sy, p_sw, p_sh;
static uint32_t p_cx, p_cy, p_cw, p_ch, p_zpos;
static uint32_t conn_id, crtc_id, fb_id, fb_w, fb_h, plane1, plane2;
static bool have_plane2;
static uint32_t blob_current, blob_120;
static unsigned plane_count;

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

static uint32_t prop_value(uint32_t obj, uint32_t type, const char *name,
                           uint64_t *out) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    if (!props)
        return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, props->props[i]);
        if (pr) {
            if (strcmp(pr->name, name) == 0) {
                id = pr->prop_id;
                if (out)
                    *out = props->prop_values[i];
            }
            drmModeFreeProperty(pr);
        }
        if (id)
            break;
    }
    drmModeFreeObjectProperties(props);
    return id;
}

static int addp(drmModeAtomicReq *req, const char *label, uint32_t obj,
                uint32_t prop, uint64_t val) {
    if (!prop) {
        printf("  missing property %s (obj=%u)\n", label, obj);
        return -1;
    }
    if (drmModeAtomicAddProperty(req, obj, prop, val) < 0) {
        printf("  AddProperty(%s obj=%u prop=%u) failed: %s\n",
               label, obj, prop, strerror(errno));
        return -1;
    }
    return 0;
}

static int test_only(const char *label, drmModeAtomicReq *req) {
    errno = 0;
    int ret = drmModeAtomicCommit(fd, req,
                                  DRM_MODE_ATOMIC_ALLOW_MODESET |
                                  DRM_MODE_ATOMIC_TEST_ONLY, NULL);
    int e = ret < 0 ? errno : 0;
    printf("%-58s ret=%d errno=%d (%s)\n", label, ret, e,
           ret ? strerror(e) : "OK");
    return ret;
}

static int plane_ok(uint32_t plane) {
    drmModePlane *pl = drmModeGetPlane(fd, plane);
    if (!pl)
        return -1;
    uint64_t type = 0;
    prop_value(plane, DRM_MODE_OBJECT_PLANE, "type", &type);
    printf("  plane %u type=%llu possible_crtcs=0x%x crtc=%u fb=%u\n",
           plane, (unsigned long long)type, pl->possible_crtcs,
           pl->crtc_id, pl->fb_id);
    int ok = type == DRM_PLANE_TYPE_PRIMARY ? 1 : 0;
    drmModeFreePlane(pl);
    return ok;
}

static int add_plane_full(drmModeAtomicReq *req, uint32_t plane,
                          uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (addp(req, "plane.FB_ID", plane, p_fb_id, fb_id) ||
        addp(req, "plane.CRTC_ID", plane, p_crtc_id, crtc_id) ||
        addp(req, "plane.SRC_X", plane, p_sx, (uint64_t)x << FP) ||
        addp(req, "plane.SRC_Y", plane, p_sy, (uint64_t)y << FP) ||
        addp(req, "plane.SRC_W", plane, p_sw, (uint64_t)w << FP) ||
        addp(req, "plane.SRC_H", plane, p_sh, (uint64_t)h << FP) ||
        addp(req, "plane.CRTC_X", plane, p_cx, x) ||
        addp(req, "plane.CRTC_Y", plane, p_cy, y) ||
        addp(req, "plane.CRTC_W", plane, p_cw, w) ||
        addp(req, "plane.CRTC_H", plane, p_ch, h))
        return -1;
    return 0;
}

static int add_plane(drmModeAtomicReq *req, uint32_t plane, uint32_t x,
                     uint32_t y, uint32_t w, uint32_t h) {
    return add_plane_full(req, plane, x, y, w, h);
}

static int add_base(drmModeAtomicReq *req, bool with_mode, bool with_conn,
                    bool with_dpms, bool with_120) {
    uint32_t blob = with_120 ? blob_120 : blob_current;
    if (addp(req, "crtc.ACTIVE", crtc_id, k_active, 1))
        return -1;
    if (with_mode && addp(req, "crtc.MODE_ID", crtc_id, k_mode_id, blob))
        return -1;
    if (with_conn && addp(req, "conn.CRTC_ID", conn_id, c_crtc_id, crtc_id))
        return -1;
    if (with_dpms && addp(req, "conn.DPMS", conn_id, c_dpms, 0))
        return -1;
    if (c_mode_id && addp(req, "conn.MODE_ID", conn_id, c_mode_id, blob))
        return -1;
    return 0;
}

static void run_case(const char *label, bool with_mode, bool with_conn,
                     bool with_dpms, bool use_plane2, bool with_zpos,
                     bool with_120) {
    drmModeAtomicReq *req = drmModeAtomicAlloc();
    if (!req) {
        printf("%s: atomic alloc failed\n", label);
        return;
    }
    if (add_base(req, with_mode, with_conn, with_dpms, with_120) == 0) {
        uint32_t half = fb_w / 2;
        if (use_plane2 && have_plane2) {
            if (add_plane(req, plane1, 0, 0, half, fb_h) ||
                add_plane(req, plane2, half, 0, half, fb_h))
                goto out;
        } else {
            if (add_plane(req, plane1, 0, 0, fb_w, fb_h))
                goto out;
        }
        if (with_zpos) {
            if (addp(req, "plane1.zpos", plane1, p_zpos, 1))
                goto out;
            if (use_plane2 && have_plane2 &&
                addp(req, "plane2.zpos", plane2, p_zpos, 2))
                goto out;
        }
        test_only(label, req);
    }
out:
    drmModeAtomicFree(req);
}

static void build_full_req(drmModeAtomicReq *req, bool dual) {
    uint32_t half = fb_w / 2;
    add_base(req, true, true, true, false);
    if (dual && have_plane2) {
        add_plane(req, plane1, 0, 0, half, fb_h);
        add_plane(req, plane2, half, 0, half, fb_h);
    } else {
        add_plane(req, plane1, 0, 0, fb_w, fb_h);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *path = "/dev/dri/card0";
    int commit_secs = 0;
    bool allow_plane2 = true;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--commit-seconds=", 17) == 0)
            commit_secs = atoi(argv[i] + 17);
        else if (strcmp(argv[i], "--no-plane2") == 0)
            allow_plane2 = false;
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
    printf("master acquired\n");
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)) {
        printf("cap universal planes: %s\n", strerror(errno));
        return 4;
    }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        printf("cap atomic: %s\n", strerror(errno));
        return 5;
    }

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) {
        printf("get resources: %s\n", strerror(errno));
        return 6;
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
        return 7;
    }
    conn_id = conn->connector_id;
    crtc_id = 0;
    if (conn->encoder_id) {
        drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
        if (enc) {
            crtc_id = enc->crtc_id;
            drmModeFreeEncoder(enc);
        }
    }
    if (!crtc_id) {
        for (int i = 0; i < res->count_crtcs; i++) {
            drmModeCrtc *pc = drmModeGetCrtc(fd, res->crtcs[i]);
            if (pc && pc->mode_valid) {
                crtc_id = res->crtcs[i];
                drmModeFreeCrtc(pc);
                break;
            }
            if (pc)
                drmModeFreeCrtc(pc);
        }
    }
    if (!crtc_id) {
        printf("no CRTC for DSI connector\n");
        return 8;
    }
    drmModeCrtc *pc = drmModeGetCrtc(fd, crtc_id);
    if (!pc) {
        printf("get crtc %u: %s\n", crtc_id, strerror(errno));
        return 9;
    }
    drmModeModeInfo mode = pc->mode;
    if (!pc->mode_valid && conn->count_modes)
        mode = conn->modes[0];
    drmModeFreeCrtc(pc);
    fb_w = mode.hdisplay;
    fb_h = mode.vdisplay;
    printf("conn %u crtc %u mode %s %ux%u\n", conn_id, crtc_id, mode.name,
           fb_w, fb_h);
    printf("connector modes:");
    for (int i = 0; i < conn->count_modes; i++)
        printf(" [%d]%s %ux%u clock=%u type=0x%x", i, conn->modes[i].name,
               conn->modes[i].hdisplay, conn->modes[i].vdisplay,
               conn->modes[i].clock, conn->modes[i].type);
    printf("\n");

    c_crtc_id = find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
    c_dpms = find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
    c_mode_id = find_prop(conn_id, DRM_MODE_OBJECT_CONNECTOR, "MODE_ID");
    k_active = find_prop(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
    k_mode_id = find_prop(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
    printf("props conn: CRTC_ID=%u DPMS=%u MODE_ID=%u; crtc: ACTIVE=%u MODE_ID=%u\n",
           c_crtc_id, c_dpms, c_mode_id, k_active, k_mode_id);
    if (!c_crtc_id || !c_dpms || !k_active || !k_mode_id) {
        printf("required core properties missing\n");
        return 10;
    }

    if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &blob_current)) {
        printf("create current mode blob: %s\n", strerror(errno));
        return 11;
    }
    blob_120 = blob_current;
    for (int i = 0; i < conn->count_modes; i++) {
        if (conn->modes[i].vrefresh == 120) {
            if (drmModeCreatePropertyBlob(fd, &conn->modes[i],
                                          sizeof(conn->modes[i]), &blob_120)) {
                printf("create 120Hz blob: %s\n", strerror(errno));
                return 12;
            }
            break;
        }
    }
    printf("blob current=%u 120=%u\n", blob_current, blob_120);

    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (!pres) {
        printf("get plane resources: %s\n", strerror(errno));
        return 13;
    }
    uint32_t primaries[32];
    unsigned nprim = 0;
    for (uint32_t i = 0; i < pres->count_planes && nprim < 32; i++) {
        if (plane_ok(pres->planes[i]) == 1)
            primaries[nprim++] = pres->planes[i];
    }
    if (!nprim) {
        printf("no primary planes\n");
        return 14;
    }
    plane1 = primaries[0];
    plane2 = allow_plane2 && nprim > 1 ? primaries[1] : 0;
    have_plane2 = plane2 != 0;
    printf("primary planes: %u [", nprim);
    for (unsigned i = 0; i < nprim; i++)
        printf("%s%u", i ? "," : "", primaries[i]);
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
    p_zpos = find_prop(plane1, DRM_MODE_OBJECT_PLANE, "zpos");
    printf("plane props: FB_ID=%u CRTC_ID=%u SRC=%u,%u,%u,%u "
           "CRTC=%u,%u,%u,%u zpos=%u\n",
           p_fb_id, p_crtc_id, p_sx, p_sy, p_sw, p_sh,
           p_cx, p_cy, p_cw, p_ch, p_zpos);
    if (!p_fb_id || !p_crtc_id || !p_sx || !p_sw || !p_cx || !p_cw) {
        printf("required plane properties missing\n");
        return 15;
    }

    struct drm_mode_create_dumb cd = { 0 };
    cd.width = fb_w;
    cd.height = fb_h;
    cd.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        printf("create dumb: %s\n", strerror(errno));
        return 16;
    }
    uint32_t handles[4] = { cd.handle }, pitches[4] = { cd.pitch };
    uint32_t offsets[4] = { 0 };
    if (drmModeAddFB2(fd, cd.width, cd.height, DRM_FORMAT_XRGB8888,
                      handles, pitches, offsets, &fb_id, 0)) {
        printf("AddFB2: %s\n", strerror(errno));
        return 17;
    }
    struct drm_mode_map_dumb md = { 0 };
    md.handle = cd.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        printf("map dumb: %s\n", strerror(errno));
        return 18;
    }
    size_t size = (size_t)cd.pitch * cd.height;
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     md.offset);
    if (map == MAP_FAILED) {
        printf("mmap: %s\n", strerror(errno));
        return 19;
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
    printf("fb %u %ux%u pitch=%u filled\n", fb_id, cd.width, cd.height, cd.pitch);

    printf("\n== TEST_ONLY matrix ==\n");
    { drmModeAtomicReq *e = drmModeAtomicAlloc(); test_only("empty TEST_ONLY", e); drmModeAtomicFree(e); }
    run_case("crtc ACTIVE (empty base)", false, false, false, false, false, false);
    run_case("crtc ACTIVE", false, false, false, false, false, false);
    run_case("crtc ACTIVE+MODE", true, false, false, false, false, false);
    run_case("crtc ACTIVE+MODE+conn CRTC", true, true, false, false, false, false);
    run_case("crtc ACTIVE+MODE+conn CRTC+DPMS", true, true, true, false, false, false);
    run_case("BASE+plane1 full", true, true, true, false, false, false);
    run_case("BASE+plane1 full+zpos", true, true, true, false, true, false);
    if (have_plane2) {
        run_case("BASE+plane1+plane2 split", true, true, true, true, false, false);
        run_case("BASE+plane1+plane2 split+zpos", true, true, true, true, true, false);
    }
    run_case("BASE+plane1 full 120Hz", true, true, true, false, false, true);
    run_case("BASE+plane1+plane2 split 120Hz", true, true, true, true, false, true);

    if (commit_secs > 0) {
        printf("\n== REAL COMMIT ==\n");
        drmModeAtomicReq *req = drmModeAtomicAlloc();
        build_full_req(req, false);
        errno = 0;
        int ret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
        printf("real full-frame commit ret=%d errno=%d (%s)\n", ret, errno,
               ret ? strerror(errno) : "OK");
        if (ret == 0)
            sleep(commit_secs);
        drmModeAtomicFree(req);
    }

    munmap(map, size);
    drmModeRmFB(fd, fb_id);
    if (blob_120 != blob_current)
        drmModeDestroyPropertyBlob(fd, blob_120);
    drmModeDestroyPropertyBlob(fd, blob_current);
    drmModeFreePlaneResources(pres);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    drmDropMaster(fd);
    close(fd);
    printf("KMSMATRIX DONE\n");
    return 0;
}

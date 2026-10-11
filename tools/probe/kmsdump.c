/* kmsdump.c ? read-only KMS topology/property dump. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void prop_flags(char *buf, size_t n, uint32_t flags) {
    buf[0] = 0;
#define ADD(x) do { if (flags & (x)) { if (buf[0]) strncat(buf, "|", n - strlen(buf) - 1); strncat(buf, #x, n - strlen(buf) - 1); } } while (0)
    ADD(DRM_MODE_PROP_PENDING);
    ADD(DRM_MODE_PROP_RANGE);
    ADD(DRM_MODE_PROP_IMMUTABLE);
    ADD(DRM_MODE_PROP_ENUM);
    ADD(DRM_MODE_PROP_BLOB);
    ADD(DRM_MODE_PROP_BITMASK);
    ADD(DRM_MODE_PROP_OBJECT);
    ADD(DRM_MODE_PROP_SIGNED_RANGE);
    ADD(DRM_MODE_PROP_ATOMIC);
#undef ADD
    if (!buf[0]) strncpy(buf, "0", n - 1);
}

static void dump_props(int fd, uint32_t id, uint32_t type, const char *kind) {
    drmModeObjectProperties *p = drmModeObjectGetProperties(fd, id, type);
    if (!p) {
        printf("  %s %u props: %s\n", kind, id, strerror(errno));
        return;
    }
    printf("  %s %u props (%u):\n", kind, id, p->count_props);
    for (uint32_t i = 0; i < p->count_props; i++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, p->props[i]);
        if (!pr) {
            printf("    prop %u: %s\n", p->props[i], strerror(errno));
            continue;
        }
        char fl[160];
        prop_flags(fl, sizeof fl, pr->flags);
        printf("    %-28s id=%-4u value=%-12" PRIu64 " flags=%s",
               pr->name, pr->prop_id, p->prop_values[i], fl);
        if (pr->count_enums) {
            printf(" enum=[");
            for (int e = 0; e < pr->count_enums; e++)
                printf("%s%s=%" PRIu64, e ? "," : "", pr->enums[e].name,
                       (uint64_t)pr->enums[e].value);
            printf("]");
        }
        printf("\n");
        drmModeFreeProperty(pr);
    }
    drmModeFreeObjectProperties(p);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("GetResources"); return 2; }
    printf("card %s\n", path);
    printf("resources: crtcs=%d connectors=%d encoders=%d fbs=%d\n",
           res->count_crtcs, res->count_connectors, res->count_encoders,
           res->count_fbs);

    for (int i = 0; i < res->count_crtcs; i++) {
        uint32_t id = res->crtcs[i];
        drmModeCrtc *c = drmModeGetCrtc(fd, id);
        if (c) {
            printf("CRTC %u mode_valid=%d mode=%s %dx%d fb=%u\n", id,
                   c->mode_valid, c->mode.name, c->mode.hdisplay,
                   c->mode.vdisplay, c->buffer_id);
            drmModeFreeCrtc(c);
        } else {
            printf("CRTC %u get: %s\n", id, strerror(errno));
        }
        dump_props(fd, id, DRM_MODE_OBJECT_CRTC, "crtc");
    }

    for (int i = 0; i < res->count_connectors; i++) {
        uint32_t id = res->connectors[i];
        drmModeConnector *c = drmModeGetConnector(fd, id);
        if (c) {
            printf("CONNECTOR %u type=%u type_id=%u connection=%d encoder=%u modes=%d\n",
                   id, c->connector_type, c->connector_type_id,
                   c->connection, c->encoder_id, c->count_modes);
            for (int m = 0; m < c->count_modes; m++)
                printf("  mode[%d] %s %dx%d clock=%d type=0x%x\n", m,
                       c->modes[m].name, c->modes[m].hdisplay,
                       c->modes[m].vdisplay, c->modes[m].clock,
                       c->modes[m].type);
            drmModeFreeConnector(c);
        } else {
            printf("CONNECTOR %u get: %s\n", id, strerror(errno));
        }
        dump_props(fd, id, DRM_MODE_OBJECT_CONNECTOR, "connector");
    }

    for (int i = 0; i < res->count_encoders; i++) {
        uint32_t id = res->encoders[i];
        drmModeEncoder *e = drmModeGetEncoder(fd, id);
        if (e) {
            printf("ENCODER %u type=%u possible_crtcs=0x%x possible_clones=0x%x crtc=%u\n",
                   id, e->encoder_type, e->possible_crtcs,
                   e->possible_clones, e->crtc_id);
            drmModeFreeEncoder(e);
        } else {
            printf("ENCODER %u get: %s\n", id, strerror(errno));
        }
        dump_props(fd, id, DRM_MODE_OBJECT_ENCODER, "encoder");
    }

    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    if (!pr) { perror("GetPlaneResources"); return 3; }
    printf("planes: %u\n", pr->count_planes);
    for (uint32_t i = 0; i < pr->count_planes; i++) {
        uint32_t id = pr->planes[i];
        drmModePlane *p = drmModeGetPlane(fd, id);
        if (p) {
            printf("PLANE %u possible_crtcs=0x%x crtc=%u fb=%u formats=%u gamma_size=%u\n",
                   id, p->possible_crtcs, p->crtc_id, p->fb_id,
                   p->count_formats, p->gamma_size);
            printf("  formats:");
            for (uint32_t f = 0; f < p->count_formats; f++)
                printf(" %c%c%c%c", p->formats[f] & 0xff,
                       (p->formats[f] >> 8) & 0xff,
                       (p->formats[f] >> 16) & 0xff,
                       (p->formats[f] >> 24) & 0xff);
            printf("\n");
            drmModeFreePlane(p);
        } else {
            printf("PLANE %u get: %s\n", id, strerror(errno));
        }
        dump_props(fd, id, DRM_MODE_OBJECT_PLANE, "plane");
    }

    drmModeFreePlaneResources(pr);
    drmModeFreeResources(res);
    close(fd);
    return 0;
}

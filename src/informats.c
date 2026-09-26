/* informats.c — dump IN_FORMATS (fmt + modifier) for given plane ids. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

static uint32_t in_formats_prop(int fd, uint32_t plane) {
    drmModeObjectPropertiesPtr p =
        drmModeObjectGetProperties(fd, plane, DRM_MODE_OBJECT_PLANE);
    if (!p) return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < p->count_props; i++) {
        drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[i]);
        if (pr) {
            if (!strcmp(pr->name, "IN_FORMATS")) id = pr->prop_id;
            drmModeFreeProperty(pr);
            if (id) break;
        }
    }
    uint32_t val = 0;
    if (id) {
        for (uint32_t i = 0; i < p->count_props; i++)
            if (p->props[i] == id) val = p->prop_values[i];
    }
    drmModeFreeObjectProperties(p);
    return val ? (uint32_t)val : 0;
}

int main(int argc, char **argv) {
    int fd = open(argc > 1 ? argv[1] : "/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    for (int a = 2; a < argc; a++) {
        uint32_t plane = atoi(argv[a]);
        uint32_t blob_id = in_formats_prop(fd, plane);
        printf("plane %u IN_FORMATS blob %u\n", plane, blob_id);
        if (!blob_id) continue;
        drmModePropertyBlobPtr b = drmModeGetPropertyBlob(fd, blob_id);
        if (!b) { printf("  blob read: %s\n", strerror(errno)); continue; }
        struct drm_format_modifier_blob *hdr = b->data;
        uint32_t *fmts = (uint32_t *)((char *)b->data + hdr->formats_offset);
        struct drm_format_modifier *mods =
            (struct drm_format_modifier *)((char *)b->data + hdr->modifiers_offset);
        printf("  %u fmts, %u mods\n", hdr->count_formats, hdr->count_modifiers);
        for (uint32_t m = 0; m < hdr->count_modifiers; m++) {
            for (uint32_t f = 0; f < hdr->count_formats; f++) {
                int bit = (int)f - (int)mods[m].offset;
                if (bit < 0 || bit >= 64) continue;
                if (!((mods[m].formats >> bit) & 1)) continue;
                printf("  %.4s mod 0x%llx\n", (char *)&fmts[f],
                       (unsigned long long)mods[m].modifier);
            }
        }
        drmModeFreePropertyBlob(b);
    }
    return 0;
}

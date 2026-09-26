/* setprop.c — generic connector property writer (for dpms etc).
 * usage: setprop <value> [prop-name=dpms] [connector-id=67] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: setprop <value> [prop=dpms] [conn=67]\n"); return 1; }
    uint64_t val = strtoull(argv[1], NULL, 0);
    const char *name = argc > 2 ? argv[2] : "dpms";
    uint32_t conn = argc > 3 ? strtoul(argv[3], NULL, 0) : 67;

    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("GetResources"); return 2; }
    drmModeConnector *c = NULL;
    for (int i = 0; i < res->count_connectors; i++)
        if (res->connectors[i] == conn) { c = drmModeGetConnector(fd, conn); break; }
    if (!c) { printf("connector %u not found\n", conn); return 3; }

    uint32_t prop_id = 0;
    int idx = -1;
    for (int i = 0; i < c->count_props; i++) {
        drmModePropertyPtr p = drmModeGetProperty(fd, c->props[i]);
        if (!p) continue;
        if (!strcmp(p->name, name)) {
            prop_id = p->prop_id;
            idx = i;
            drmModeFreeProperty(p);
            break;
        }
        drmModeFreeProperty(p);
    }
    if (!prop_id) { printf("prop %s not on connector %u\n", name, conn); return 4; }
    printf("found %s id=%u cur=%llu\n", name, prop_id,
           (unsigned long long)c->prop_values[idx]);

    struct drm_mode_obj_set_property req = {
        .obj_id = conn, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
        .prop_id = prop_id, .value = val,
    };
    errno = 0;
    int ret = drmIoctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &req);
    printf("set %s=%llu -> %d (%s)\n", name, (unsigned long long)val, ret,
           ret ? strerror(errno) : "ok");
    return ret != 0;
}

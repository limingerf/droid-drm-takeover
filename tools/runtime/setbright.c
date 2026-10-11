/* setbright.c — inspect or write the active connector's brightness property.
 * usage: setbright [value]   (no arg = print range only) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv) {
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    uint64_t val = (uint64_t)-1;
    if (argc > 1) val = strtoull(argv[1], NULL, 0);

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("GetResources"); return 2; }

    uint32_t connector_id = 0, property_id = 0;
    uint64_t current = 0, minimum = 0, maximum = 0;
    for (int i = 0; i < res->count_connectors && !property_id; i++) {
        drmModeConnector *connector = drmModeGetConnector(fd, res->connectors[i]);
        if (!connector || connector->connection != DRM_MODE_CONNECTED) {
            drmModeFreeConnector(connector);
            continue;
        }
        for (int j = 0; j < connector->count_props; j++) {
            drmModePropertyPtr property = drmModeGetProperty(fd, connector->props[j]);
            if (property && !strcasecmp(property->name, "brightness")) {
                connector_id = connector->connector_id;
                property_id = property->prop_id;
                current = connector->prop_values[j];
                if (property->count_values >= 2) {
                    minimum = property->values[0];
                    maximum = property->values[1];
                }
                drmModeFreeProperty(property);
                break;
            }
            drmModeFreeProperty(property);
        }
        drmModeFreeConnector(connector);
    }
    drmModeFreeResources(res);
    if (!property_id) {
        fprintf(stderr, "no brightness property on a connected connector\n");
        return 3;
    }

    printf("connector %u brightness property %u current %llu range [%llu..%llu]\n",
           connector_id, property_id, (unsigned long long)current,
           (unsigned long long)minimum, (unsigned long long)maximum);
    if (argc <= 1) return 0;

    if (maximum && val > maximum) val = maximum;
    if (val < minimum) val = minimum;

    struct drm_mode_obj_set_property req = {
        .obj_id = connector_id, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
        .prop_id = property_id, .value = val,
    };
    errno = 0;
    int ret = drmIoctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &req);
    printf("set %llu -> %d (%s)\n", (unsigned long long)val, ret,
           ret ? strerror(errno) : "ok");
    return ret != 0;
}

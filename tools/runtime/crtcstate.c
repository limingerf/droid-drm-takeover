/* crtcstate.c — dump crtc206 legacy state + conn67 DPMS/brightness values. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    drmModeCrtcPtr c = drmModeGetCrtc(fd, 206);
    if (c) {
        printf("crtc206: mode_valid=%d mode=%s %dx%d\n",
               c->mode_valid, c->mode.name,
               c->mode.hdisplay, c->mode.vdisplay);
        drmModeFreeCrtc(c);
    } else printf("crtc206: %s\n", strerror(errno));
    drmModeConnectorPtr n = drmModeGetConnector(fd, 67);
    if (n) {
        printf("conn67: connection=%d encoder=%u count_modes=%d\n",
               n->connection, n->encoder_id, n->count_modes);
        drmModeFreeConnector(n);
    }
    drmModeObjectPropertiesPtr p =
        drmModeObjectGetProperties(fd, 67, DRM_MODE_OBJECT_CONNECTOR);
    if (p) {
        for (uint32_t i = 0; i < p->count_props; i++) {
            drmModePropertyPtr pr = drmModeGetProperty(fd, p->props[i]);
            if (!pr) continue;
            if (!strcmp(pr->name, "DPMS") || !strcmp(pr->name, "brightness") ||
                !strcmp(pr->name, "power_mode"))
                printf("conn67 %s = %llu\n", pr->name,
                       (unsigned long long)p->prop_values[i]);
            drmModeFreeProperty(pr);
        }
        drmModeFreeObjectProperties(p);
    }
    return 0;
}

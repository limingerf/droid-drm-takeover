/* connprops.c — print every property attached to connector 67 (id:name:flags),
 * then scan global property ids 1..400 for anything named *mode*. No master. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    uint32_t target = argc > 2 ? (uint32_t)atoi(argv[2]) : 67;
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) { perror("getres"); return 2; }
    drmModeConnectorPtr c = drmModeGetConnector(fd, target);
    if (!c) { printf("connector %u: %s\n", target, strerror(errno)); return 3; }
    printf("conn %u: %d props\n", target, c->count_props);
    for (int i = 0; i < c->count_props; i++) {
        drmModePropertyPtr p = drmModeGetProperty(fd, c->props[i]);
        if (!p) { printf("  %u: <gone>\n", c->props[i]); continue; }
        printf("  %3u %-28s flags 0x%08x\n", p->prop_id, p->name, p->flags);
        drmModeFreeProperty(p);
    }
    printf("global scan for *mode*:\n");
    for (uint32_t id = 1; id <= 400; id++) {
        drmModePropertyPtr p = drmModeGetProperty(fd, id);
        if (!p) continue;
        if (strstr(p->name, "mode") || strstr(p->name, "Mode") ||
            strstr(p->name, "MODE"))
            printf("  %3u %-28s flags 0x%08x\n", p->prop_id, p->name, p->flags);
        drmModeFreeProperty(p);
    }
    return 0;
}

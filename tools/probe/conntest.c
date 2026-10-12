/* conntest.c — 直接调 drmModeGetConnector，验证 drmfmt.so 的覆盖是否生效。 */
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 2; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("res"); return 3; }
    printf("connectors=%d\n", res->count_connectors);
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED)
            printf("conn %u: count_modes=%d\n", c->connector_id, c->count_modes);
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(res);
    close(fd);
    printf("CONNTEST_DONE\n");
    return 0;
}

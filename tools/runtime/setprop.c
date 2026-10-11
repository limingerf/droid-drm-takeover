/* setprop.c — 通用 connector 属性写（dpms / brightness / 等）
 *
 * usage: setprop <value> [prop-name=dpms] [connector-id]
 *
 * ══ 修掉的历史坑 ══
 * 旧版把 connector 默认写死成 67 —— 那是 piano（小米平板 8 Pro）的
 * connector id。换到任何别的设备上，每一次调用都会打印
 * "connector 67 not found" 并**静默丢掉这次 DPMS 写**，
 * 调用方只看到一句无人在意的输出。
 * 现象是"kwin 起来了、也有 master、就是屏幕不出画"，
 * 因为没人把 connector 的 DPMS 从 Off 拉回 On。
 *
 * 现在：不给 connector 就**运行时发现**——挑一个 connected、
 * 有 modes、且不是 VIRTUAL/WRITEBACK 的 connector。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#ifndef DRM_CARD
#define DRM_CARD "/dev/dri/card0"
#endif

/* 真正的面板：已连接、有可用模式、且不是虚拟/回写 connector。
 * VIRTUAL 是 writeback 连接器（DRM_MODE_CONNECTOR_VIRTUAL == 15），
 * WRITEBACK 是 22；它们也报 connected，但往上写 DPMS 没有任何视觉效果。 */
static uint32_t find_panel_connector(int fd, drmModeRes *res)
{
    uint32_t fallback = 0;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;

        int virtual_like = (c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
                            c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK);

        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            if (!virtual_like) {
                uint32_t id = c->connector_id;
                printf("setprop: 自动选中 connector %u (type=%d, modes=%d)\n",
                       id, c->connector_type, c->count_modes);
                drmModeFreeConnector(c);
                return id;
            }
            if (!fallback) fallback = c->connector_id;
        }
        drmModeFreeConnector(c);
    }
    if (fallback) {
        printf("setprop: 只找到虚拟/回写 connector %u，用它\n", fallback);
        return fallback;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
                "usage: setprop <value> [prop-name=dpms] [connector-id]\n"
                "       不给 connector-id 时运行时自动发现面板 connector\n");
        return 1;
    }
    uint64_t val = strtoull(argv[1], NULL, 0);
    const char *name = argc > 2 ? argv[2] : "dpms";
    uint32_t conn = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 0;

    int fd = open(DRM_CARD, O_RDWR);
    if (fd < 0) { perror("open " DRM_CARD); return 1; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("GetResources"); close(fd); return 2; }

    if (!conn) {
        conn = find_panel_connector(fd, res);
        if (!conn) {
            fprintf(stderr, "setprop: 找不到可用的面板 connector\n");
            drmModeFreeResources(res);
            close(fd);
            return 3;
        }
    }

    drmModeConnector *c = drmModeGetConnector(fd, conn);
    if (!c) {
        fprintf(stderr, "setprop: connector %u not found\n", conn);
        drmModeFreeResources(res);
        close(fd);
        return 3;
    }

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
    if (!prop_id) {
        fprintf(stderr, "setprop: connector %u 上没有属性 %s\n", conn, name);
        drmModeFreeConnector(c);
        drmModeFreeResources(res);
        close(fd);
        return 4;
    }
    printf("setprop: found %s id=%u cur=%llu\n", name, prop_id,
           (unsigned long long)c->prop_values[idx]);

    struct drm_mode_obj_set_property req = {
        .obj_id = conn,
        .obj_type = DRM_MODE_OBJECT_CONNECTOR,
        .prop_id = prop_id,
        .value = val,
    };
    errno = 0;
    int ret = drmIoctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &req);
    printf("setprop: set %s=%llu -> %d (%s)\n", name, (unsigned long long)val,
           ret, ret ? strerror(errno) : "ok");

    drmModeFreeConnector(c);
    drmModeFreeResources(res);
    close(fd);
    return ret != 0;
}

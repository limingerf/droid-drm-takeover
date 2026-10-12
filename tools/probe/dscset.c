/* dscset.c — 独立设置连接器的 dsc_mode / bpp_mode（都是非 ATOMIC 属性）。
 *
 * 用途：验证 DSC 相关属性的组合。本机面板是 DSC 面板
 * （cmdline: ..._dual_dsi_dsc_vid，topology_name=13=sde_quadpipe_dscmerge），
 * 接管后 dsc_mode=1 但 bpp_mode=0(none) —— 如果 DSC 编码位深与面板期望的
 * 不一致，面板解出来就是满屏细密噪声 + 彩虹色偏。
 *
 * usage: dscset <card> [--dsc=N] [--bpp=N]
 *   不带 --dsc/--bpp = 只打印当前值（不修改）
 *   dsc_mode enum: 0=none 1=dsc_enabled 2=dsc_disabled
 *   bpp_mode enum: 0=none 1=dsi_24bpp 2=dsi_30bpp
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_mode.h>

static int set_prop(int fd, uint32_t obj, uint32_t type, const char *name,
                    uint64_t want, int do_set) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    if (!props) return -1;
    int found = 0;
    for (uint32_t k = 0; k < props->count_props; k++) {
        drmModePropertyRes *pr = drmModeGetProperty(fd, props->props[k]);
        if (!pr) continue;
        if (strcmp(pr->name, name) != 0) { drmModeFreeProperty(pr); continue; }
        found = 1;
        printf("  %-10s prop=%-3u flags=0x%x 当前=%llu",
               name, pr->prop_id, pr->flags,
               (unsigned long long)props->prop_values[k]);
        if (pr->count_enums) {
            printf(" enum=[");
            for (int e = 0; e < pr->count_enums; e++)
                printf("%s%s=%llu", e ? "," : "", pr->enums[e].name,
                       (unsigned long long)pr->enums[e].value);
            printf("]");
        }
        printf("\n");
        if (do_set && props->prop_values[k] != want) {
            struct drm_mode_obj_set_property sp = {
                .obj_id = obj, .obj_type = type,
                .prop_id = pr->prop_id, .value = want,
            };
            errno = 0;
            int r = ioctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
            printf("    -> SET %s=%llu ret=%d %s\n", name,
                   (unsigned long long)want, r, r ? strerror(errno) : "OK");
            if (r == 0) {
                drmModeObjectProperties *p2 =
                    drmModeObjectGetProperties(fd, obj, type);
                if (p2) {
                    for (uint32_t j = 0; j < p2->count_props; j++)
                        if (p2->props[j] == pr->prop_id)
                            printf("    -> 回读 %s=%llu\n", name,
                                   (unsigned long long)p2->prop_values[j]);
                    drmModeFreeObjectProperties(p2);
                }
            }
        }
        drmModeFreeProperty(pr);
    }
    drmModeFreeObjectProperties(props);
    return found ? 0 : 1;
}

int main(int argc, char **argv) {
    const char *path = "/dev/dri/card0";
    long dsc = -1, bpp = -1, dpms = -1;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--dsc=", 6) == 0) dsc = strtol(argv[i] + 6, NULL, 0);
        else if (strncmp(argv[i], "--bpp=", 6) == 0) bpp = strtol(argv[i] + 6, NULL, 0);
        else if (strncmp(argv[i], "--dpms=", 7) == 0) dpms = strtol(argv[i] + 7, NULL, 0);
        else if (argv[i][0] != '-') path = argv[i];
    }
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open %s: %s\n", path, strerror(errno)); return 2; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { printf("get resources: %s\n", strerror(errno)); return 3; }
    for (int i = 0; i < res->count_connectors; i++) {
        uint32_t cid = res->connectors[i];
        drmModeConnector *c = drmModeGetConnector(fd, cid);
        if (!c) continue;
        if (c->connection != DRM_MODE_CONNECTED ||
            c->connector_type != DRM_MODE_CONNECTOR_DSI) {
            drmModeFreeConnector(c);
            continue;
        }
        printf("conn %u (DSI connected)\n", cid);
        if (dsc < 0 && bpp < 0 && dpms < 0) {
            set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "dsc_mode", 0, 0);
            set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "bpp_mode", 0, 0);
            set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "DPMS", 0, 0);
        } else {
            /* ★ 顺序要紧：面板必须处于"待重建"状态，dsc_mode/bpp_mode
             *   才会在下次上电时真正进硬件。所以 --dpms=3(Off) 要**先**给。 */
            if (dpms >= 0)
                set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "DPMS",
                         (uint64_t)dpms, 1);
            if (dsc >= 0)
                set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "dsc_mode",
                         (uint64_t)dsc, 1);
            if (bpp >= 0)
                set_prop(fd, cid, DRM_MODE_OBJECT_CONNECTOR, "bpp_mode",
                         (uint64_t)bpp, 1);
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(res);
    close(fd);
    printf("DSCSET_DONE\n");
    return 0;
}

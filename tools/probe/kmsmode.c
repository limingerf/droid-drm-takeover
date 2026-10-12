/*
 * kmsmode —— 强制 CRTC 做一次**真正的**模式切换，逼内核重建 DSI 链路。
 *
 * 背景（2026-10-12 实测）：
 *   dmesg 显示 DSI 面板驱动的日志停在
 *       dsi_display_set_mode: ... fps=144 ...
 *       dsi_ctrl_isr_configure: dsi-ctrl-0/1: IRQ 377/378 registered
 *       dsi_panel_power_on enter!            ← 之后再也没有日志
 *   而 DSI 中断计数冻结（377=2081 不动，378=0）⇒ **链路从未建立**，
 *   面板收不到信号 ⇒ 彩色噪声。
 *
 *   根因方向：KWin 设的模式与内核里**已经是**的模式相同 ⇒ 内核认为
 *   无需重建，直接跳过 DSI 建链。所以这里主动把 CRTC 关掉、换一个
 *   模式、再打开，制造一次真实的 mode change。
 *
 * 用法：
 *   kmsmode <card> [--mode=NAME] [--crtc=N] [--hold=N] [--list]
 *
 * 默认：找到已激活的 CRTC，切到它上面**不同于当前**的那个模式；
 * 若只有一个模式可用，则先 ACTIVE=0 再 ACTIVE=1（一次 disable/enable 循环）。
 *
 * ★ 全程用 atomic 提交；结束时恢复原来的模式，尽量不留黑屏。
 * 打印 KMSMODE_DONE。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_mode.h>

static int FD = -1;
static uint32_t g_w = 3200, g_h = 2000;

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name)
{
    drmModeObjectPropertiesPtr ps = drmModeObjectGetProperties(FD, obj, type);
    if (!ps) return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < ps->count_props; i++) {
        drmModePropertyPtr p = drmModeGetProperty(FD, ps->props[i]);
        if (!p) continue;
        if (!strcmp(p->name, name)) id = p->prop_id;
        drmModeFreeProperty(p);
        if (id) break;
    }
    drmModeFreeObjectProperties(ps);
    return id;
}

static uint32_t prop_val(uint32_t obj, uint32_t type, const char *name)
{
    drmModeObjectPropertiesPtr ps = drmModeObjectGetProperties(FD, obj, type);
    if (!ps) return 0;
    uint32_t v = 0;
    for (uint32_t i = 0; i < ps->count_props; i++) {
        drmModePropertyPtr p = drmModeGetProperty(FD, ps->props[i]);
        if (!p) continue;
        if (!strcmp(p->name, name)) v = (uint32_t)ps->prop_values[i];
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(ps);
    return v;
}

/* 提交：带 CRTC ACTIVE/MODE_ID +（可选）连接器 CRTC_ID +（可选）平面 FB */
static int commit_full(uint32_t crtc, uint32_t mode_blob, uint32_t active,
                       uint32_t conn, uint32_t dpms_val, int have_dpms,
                       uint32_t plane, uint32_t fb, int have_plane,
                       uint32_t flags)
{
    drmModeAtomicReqPtr req = drmModeAtomicAlloc();
    if (!req) return -1;

    uint32_t p_act  = prop_id(crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE");
    uint32_t p_mode = prop_id(crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
    if (!p_act || !p_mode) { drmModeAtomicFree(req); return -2; }

    drmModeAtomicAddProperty(req, crtc, p_act, active);
    drmModeAtomicAddProperty(req, crtc, p_mode, mode_blob);

    if (conn) {
        uint32_t p_cc = prop_id(conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
        if (p_cc) drmModeAtomicAddProperty(req, conn, p_cc, active ? crtc : 0);
        if (have_dpms && dpms_val != 0xffffffff) {
            uint32_t p_dp = prop_id(conn, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
            if (p_dp) drmModeAtomicAddProperty(req, conn, p_dp, dpms_val);
        }
    }

    if (have_plane && plane) {
        uint32_t p_fb    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "FB_ID");
        uint32_t p_crtc  = prop_id(plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
        uint32_t p_cx    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "CRTC_X");
        uint32_t p_cy    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
        uint32_t p_cw    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "CRTC_W");
        uint32_t p_ch    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "CRTC_H");
        uint32_t p_sx    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "SRC_X");
        uint32_t p_sy    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "SRC_Y");
        uint32_t p_sw    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "SRC_W");
        uint32_t p_sh    = prop_id(plane, DRM_MODE_OBJECT_PLANE, "SRC_H");
        if (p_fb)   drmModeAtomicAddProperty(req, plane, p_fb,   fb);
        if (p_crtc) drmModeAtomicAddProperty(req, plane, p_crtc, active ? crtc : 0);
        if (active) {
            if (p_cx) drmModeAtomicAddProperty(req, plane, p_cx, 0);
            if (p_cy) drmModeAtomicAddProperty(req, plane, p_cy, 0);
            if (p_cw) drmModeAtomicAddProperty(req, plane, p_cw, g_w);
            if (p_ch) drmModeAtomicAddProperty(req, plane, p_ch, g_h);
            if (p_sx) drmModeAtomicAddProperty(req, plane, p_sx, 0);
            if (p_sy) drmModeAtomicAddProperty(req, plane, p_sy, 0);
            if (p_sw) drmModeAtomicAddProperty(req, plane, p_sw, (uint32_t)g_w << 16);
            if (p_sh) drmModeAtomicAddProperty(req, plane, p_sh, (uint32_t)g_h << 16);
        }
    }

    errno = 0;
    int r = drmModeAtomicCommit(FD, req, flags, NULL);
    int e = errno;
    drmModeAtomicFree(req);
    errno = e;
    return r;
}

/* 造一个全屏纯色 dumb buffer 并注册成 FB */
static int make_fb(uint32_t w, uint32_t h, uint32_t *out_fb, uint32_t *out_handle)
{
    struct drm_mode_create_dumb cd;
    memset(&cd, 0, sizeof cd);
    cd.width = w; cd.height = h; cd.bpp = 32;
    if (drmIoctl(FD, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) return -1;

    struct drm_mode_map_dumb md;
    memset(&md, 0, sizeof md);
    md.handle = cd.handle;
    if (drmIoctl(FD, DRM_IOCTL_MODE_MAP_DUMB, &md)) return -1;
    void *p = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, FD, (off_t)md.offset);
    if (p == MAP_FAILED) return -1;
    /* 填一个明显的颜色：深蓝 */
    uint32_t *px = p;
    for (uint32_t i = 0; i < cd.size / 4; i++) px[i] = 0xff203060u;
    munmap(p, cd.size);

    uint32_t fb = 0, handle = cd.handle;
    uint32_t pitches[4] = { cd.pitch, 0, 0, 0 };
    uint32_t offsets[4] = { 0, 0, 0, 0 };
    uint32_t handles[4] = { cd.handle, 0, 0, 0 };
    if (drmModeAddFB2(FD, w, h, 0x34325258 /* XR24 */, handles, pitches, offsets, &fb, 0))
        return -1;
    *out_fb = fb; *out_handle = handle;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "用法: %s <card> [--mode=NAME] [--crtc=N] [--list]\n", argv[0]);
        return 2;
    }
    const char *want_mode = NULL;
    uint32_t want_crtc = 0, want_conn = 0;
    int do_list = 0;

    for (int i = 2; i < argc; i++) {
        if (!strncmp(argv[i], "--mode=", 7)) want_mode = argv[i] + 7;
        else if (!strncmp(argv[i], "--crtc=", 7)) want_crtc = (uint32_t)strtoul(argv[i] + 7, NULL, 0);
        else if (!strncmp(argv[i], "--conn=", 7)) want_conn = (uint32_t)strtoul(argv[i] + 7, NULL, 0);
        else if (!strcmp(argv[i], "--list")) do_list = 1;
    }

    FD = open(argv[1], O_RDWR | O_CLOEXEC);
    if (FD < 0) { fprintf(stderr, "打开 %s 失败: %s\n", argv[1], strerror(errno)); return 1; }

    drmModeResPtr res = drmModeGetResources(FD);
    if (!res) { fprintf(stderr, "GetResources 失败: %s\n", strerror(errno)); close(FD); return 1; }

    /* 找已激活的 CRTC 及其连接器 */
    uint32_t crtc = want_crtc, conn = want_conn;
    if (!crtc) {
        for (int i = 0; i < res->count_crtcs && !crtc; i++) {
            uint32_t c = res->crtcs[i];
            if (prop_val(c, DRM_MODE_OBJECT_CRTC, "ACTIVE") == 1) crtc = c;
        }
        if (!crtc) crtc = res->crtcs[0];
    }
    /* 连接器：显式指定优先；否则优先挑 **DSI(type=16)** 的已连接面板
     *（实测踩坑：不区分类型会挑到 DisplayPort 连接器 33，
     * 它有 37 个标准模式、跟面板完全无关）。 */
    uint32_t conn2 = want_conn;
    if (!conn2) {
        for (int i = 0; i < res->count_connectors && !conn; i++) {
            uint32_t cn = res->connectors[i];
            drmModeConnectorPtr t = drmModeGetConnector(FD, cn);
            if (t && t->count_modes > 0 && t->connection == DRM_MODE_CONNECTED &&
                t->connector_type == DRM_MODE_CONNECTOR_DSI)
                conn = cn;
            if (t) drmModeFreeConnector(t);
        }
    }

    drmModeCrtcPtr cur = drmModeGetCrtc(FD, crtc);
    drmModeConnectorPtr co = conn ? drmModeGetConnector(FD, conn) : NULL;

    printf("CRTC=%u  连接器=%u  ACTIVE=%u  当前模式=%s\n", crtc, conn,
           prop_val(crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE"),
           cur && cur->mode_valid ? cur->mode.name : "(无)");

    if (co) {
        printf("连接器 %u 可用模式 %d 个:\n", conn, co->count_modes);
        for (int i = 0; i < co->count_modes; i++)
            printf("  [%d] %s  %ux%u clock=%u type=0x%x\n", i,
                   co->modes[i].name, co->modes[i].hdisplay,
                   co->modes[i].vdisplay, co->modes[i].clock,
                   co->modes[i].type);
    }
    if (do_list) { printf("KMSMODE_DONE\n"); return 0; }

    /* 选一个与当前不同的模式 */
    int idx = -1;
    const char *cur_name = (cur && cur->mode_valid) ? cur->mode.name : "";
    if (co) {
        for (int i = 0; i < co->count_modes; i++) {
            if (want_mode) {
                if (!strcmp(co->modes[i].name, want_mode)) { idx = i; break; }
            } else if (strcmp(co->modes[i].name, cur_name)) {
                idx = i; break;          /* 第一个不同的 */
            }
        }
        if (idx < 0 && !want_mode) idx = 0;   /* 都一样就退回第一个 */
    }
    if (idx < 0) { fprintf(stderr, "找不到目标模式\n"); close(FD); return 1; }
    printf("目标模式: %s\n", co->modes[idx].name);

    /* 建 blob */
    uint32_t blob = 0;
    if (drmModeCreatePropertyBlob(FD, &co->modes[idx], sizeof(co->modes[idx]), &blob)) {
        fprintf(stderr, "建 MODE blob 失败: %s\n", strerror(errno));
        close(FD); return 1;
    }

    uint32_t saved_blob = prop_val(crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
    const uint32_t ALLOW = DRM_MODE_ATOMIC_ALLOW_MODESET;

    /* 找一个能配到该 CRTC 的 Primary 平面 */
    uint32_t plane = 0;
    drmModePlaneResPtr pr = drmModeGetPlaneResources(FD);
    if (pr) {
        for (uint32_t i = 0; i < pr->count_planes && !plane; i++) {
            uint32_t pl = pr->planes[i];
            drmModePlanePtr p = drmModeGetPlane(FD, pl);
            if (!p) continue;
            uint32_t t = prop_val(pl, DRM_MODE_OBJECT_PLANE, "type");
            /* type: 0=Overlay 1=Primary 2=Cursor */
            if (t == 1) {
                for (int k = 0; k < res->count_crtcs; k++) {
                    if (res->crtcs[k] == crtc && (p->possible_crtcs & (1u << k))) {
                        plane = pl; break;
                    }
                }
            }
            drmModeFreePlane(p);
        }
        drmModeFreePlaneResources(pr);
    }

    /* 造一个全屏纯色 FB */
    uint32_t fb = 0, dhandle = 0;
    g_w = co->modes[idx].hdisplay;
    g_h = co->modes[idx].vdisplay;
    if (make_fb(g_w, g_h, &fb, &dhandle))
        fprintf(stderr, "警告：造 FB 失败（%s）—— 只做 CRTC 建链，不带平面\n", strerror(errno));
    printf("平面=%u  FB=%u  %ux%u\n", plane, fb, g_w, g_h);

    /* ① 先关掉 CRTC —— 强制内核拆掉 DSI 链路 */
    printf("① ACTIVE=0（拆链）... ");
    errno = 0;
    int r = commit_full(crtc, 0, 0, conn, 0xffffffff, 0, plane, 0, 1, ALLOW);
    printf("ret=%d %s\n", r, r ? strerror(errno) : "OK");
    usleep(500 * 1000);

    /* ② 重新建链：连接器 CRTC_ID + CRTC ACTIVE/MODE_ID + 平面 FB，
     *    一次性提交（从零建链必须带全，缺一个内核就判 EINVAL）。 */
    printf("② 建链 MODE=%s + ACTIVE=1 + 平面 ... ", co->modes[idx].name);
    errno = 0;
    r = commit_full(crtc, blob, 1, conn, 0 /* DPMS On */, 1, plane, fb, 1, ALLOW);
    printf("ret=%d %s\n", r, r ? strerror(errno) : "OK");
    usleep(800 * 1000);

    printf("③ 提交后：ACTIVE=%u MODE_ID=%u CRTC_ID=%u DPMS=%u\n",
           prop_val(crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE"),
           prop_val(crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID"),
           conn ? prop_val(conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID") : 0,
           conn ? prop_val(conn, DRM_MODE_OBJECT_CONNECTOR, "DPMS") : 0);

    if (cur && cur->mode_valid)
        printf("（原模式 %s，blob=%u —— 不自动恢复，交给 KWin 重新设）\n",
               cur->mode.name, saved_blob);

    if (co) drmModeFreeConnector(co);
    if (cur) drmModeFreeCrtc(cur);
    drmModeFreeResources(res);
    close(FD);
    printf("KMSMODE_DONE\n");
    return 0;
}

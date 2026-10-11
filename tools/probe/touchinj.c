/* touchinj — 读触摸屏原始事件，经 KWin 的 fake-input 协议注入合成器。
 *
 * 为什么需要它：容器里的触摸节点是我们自己 mknod 出来的，libinput 会
 * 因为缺少完整的 udev 属性而拒绝整台设备。走 fake-input 可以绕开 libinput，
 * 用于验证"合成器与 KWin 都正常、只有 libinput 不认设备"这类问题。
 *
 * usage: touchinj [seconds] [event-node]
 *   env: TOUCHINJ_W / TOUCHINJ_H    强制面板尺寸（否则从 DRM 读）
 *        TOUCHINJ_ROT               坐标变换，见下（默认 xyy）
 *
 * ══ 修掉的历史坑 ══
 * 旧版把面板尺寸写死成 3200x2136 —— 那是 piano（小米平板 8 Pro）的值。
 * 在别的设备上注入的坐标会整体错位（本机 OPD2511 是 3200x2000）。
 * 而且它用 `value / 100` 猜触摸控制器的量程，那个 100 也是 piano 的
 * 巧合（NVT 控制器报 0..320000）。现在改成：
 *   · 面板尺寸从 DRM mode 读
 *   · 触摸量程用 EVIOCGABS 读 ABS_MT_POSITION_X/Y 的真实 min/max
 *   · 坐标变换可用 TOUCHINJ_ROT 覆盖
 *
 * 变换默认 "xyy"：触摸屏的 X 轴对应面板的 Y 轴（90° 旋转），
 * 且 Y 需要翻转。取值是四个字母，依次表示
 *   面板X = f(触摸?) 面板Y = g(触摸?) 是否翻转面板X 是否翻转面板Y
 * 具体见 apply_rot()。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <time.h>
#include <linux/input.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include "fake-input-protocol.h"

#ifndef DRM_CARD
#define DRM_CARD "/dev/dri/card0"
#endif

#define NSLOT 10

static struct wl_display *disp;
static struct org_kde_kwin_fake_input *fake;

/* 面板与触摸量程（运行时填） */
static int PANEL_W = 0, PANEL_H = 0;
static int TX_MIN = 0, TX_MAX = 0, TY_MIN = 0, TY_MAX = 0;
static const char *ROT = "xyy";

static void global(void *d, struct wl_registry *r, uint32_t id,
                   const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, org_kde_kwin_fake_input_interface.name)) {
        if (ver > 6) ver = 6;
        fake = wl_registry_bind(r, id, &org_kde_kwin_fake_input_interface, ver);
    }
}
static const struct wl_registry_listener regl = { global, NULL };

/* 从 DRM 读当前面板 mode 的宽高 */
static int panel_size_from_drm(void) {
    int fd = open(DRM_CARD, O_RDWR);
    if (fd < 0) { perror("open " DRM_CARD); return -1; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("GetResources"); close(fd); return -1; }
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0 &&
            c->connector_type != DRM_MODE_CONNECTOR_VIRTUAL &&
            c->connector_type != DRM_MODE_CONNECTOR_WRITEBACK) {
            /* 取第一个模式（驱动把首选模式排在前面） */
            PANEL_W = c->modes[0].hdisplay;
            PANEL_H = c->modes[0].vdisplay;
            fprintf(stderr, "touchinj: 面板 %dx%d (connector %u)\n",
                    PANEL_W, PANEL_H, c->connector_id);
            drmModeFreeConnector(c);
            drmModeFreeResources(res);
            close(fd);
            return 0;
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(res);
    close(fd);
    return -1;
}

/* 从 evdev 读 ABS_MT_POSITION_X/Y 的真实量程。
 * 注意内核 uapi 里成员名是 minimum/maximum（不是 min/max）。 */
static void touch_range_from_evdev(int ifd) {
    struct input_absinfo ax, ay;
    if (ioctl(ifd, EVIOCGABS(ABS_MT_POSITION_X), &ax) == 0) {
        TX_MIN = ax.minimum; TX_MAX = ax.maximum;
    }
    if (ioctl(ifd, EVIOCGABS(ABS_MT_POSITION_Y), &ay) == 0) {
        TY_MIN = ay.minimum; TY_MAX = ay.maximum;
    }
    fprintf(stderr, "touchinj: 触摸量程 X[%d..%d] Y[%d..%d]\n",
            TX_MIN, TX_MAX, TY_MIN, TY_MAX);
}

static int scale(int v, int lo, int hi, int out) {
    if (hi <= lo) return 0;
    long r = (long)(v - lo) * (out - 1) / (hi - lo);
    if (r < 0) r = 0;
    if (r > out - 1) r = out - 1;
    return (int)r;
}

/* 触摸坐标 → 面板坐标。
 * ROT 四字符： [0]=面板X取自触摸(x|y) [1]=面板Y取自触摸(x|y)
 *             [2]=面板X翻转('f'|'n')    [3]=面板Y翻转('f'|'n')
 * 默认 "xyy" = 面板X←触摸Y、面板Y←触摸X、面板Y翻转（90° 旋转 + 垂直翻转） */
static void apply_rot(int tx, int ty, int *px, int *py) {
    int nx = scale(tx, TX_MIN, TX_MAX, PANEL_W);
    int ny = scale(ty, TY_MIN, TY_MAX, PANEL_H);
    int a, b;
    if (ROT[0] == 'y') { a = ny; } else { a = nx; }   /* 面板 X 的源 */
    if (ROT[1] == 'y') { b = ny; } else { b = nx; }   /* 面板 Y 的源 */
    if (ROT[2] == 'f') a = PANEL_W - 1 - a;
    if (ROT[3] == 'f') b = PANEL_H - 1 - b;
    if (a < 0) a = 0;
    if (a >= PANEL_W) a = PANEL_W - 1;
    if (b < 0) b = 0;
    if (b >= PANEL_H) b = PANEL_H - 1;
    *px = a;
    *py = b;
}

struct slot { int on, was, x, y; };
static struct slot slots[NSLOT];

static void flush_touches(void) {
    int any = 0;
    for (int s = 0; s < NSLOT; s++) {
        struct slot *t = &slots[s];
        int cx, cy;
        apply_rot(t->x, t->y, &cx, &cy);
        if (t->on && !t->was) {
            org_kde_kwin_fake_input_touch_down(fake, s,
                wl_fixed_from_int(cx), wl_fixed_from_int(cy));
            fprintf(stderr, "T down %d @%d,%d\n", s, cx, cy);
            any = 1;
        } else if (t->on && t->was) {
            org_kde_kwin_fake_input_touch_motion(fake, s,
                wl_fixed_from_int(cx), wl_fixed_from_int(cy));
            any = 1;
        } else if (!t->on && t->was) {
            org_kde_kwin_fake_input_touch_up(fake, s);
            fprintf(stderr, "T up   %d\n", s);
            any = 1;
        }
        t->was = t->on;
    }
    if (any) {
        org_kde_kwin_fake_input_touch_frame(fake);
        wl_display_flush(disp);
    }
}

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    int secs = argc > 1 ? atoi(argv[1]) : 30;
    const char *node = argc > 2 ? argv[2] : NULL;

    const char *e;
    if ((e = getenv("TOUCHINJ_W"))) PANEL_W = atoi(e);
    if ((e = getenv("TOUCHINJ_H"))) PANEL_H = atoi(e);
    if ((e = getenv("TOUCHINJ_ROT"))) ROT = e;
    if (!node && (e = getenv("TOUCH_EVENT"))) node = e;
    if (!node) node = "/dev/input/event11";   /* 兜底；调用方应显式给 */

    if (PANEL_W <= 0 || PANEL_H <= 0) {
        if (panel_size_from_drm() != 0) {
            fprintf(stderr,
                "touchinj: 读不到面板尺寸。请用 TOUCHINJ_W/TOUCHINJ_H 指定\n"
                "（旧版写死 3200x2136，那是 piano 的值，在别的设备上会错位）\n");
            return 4;
        }
    }

    disp = wl_display_connect(NULL);
    if (!disp) { fprintf(stderr, "wayland connect failed: %s\n", strerror(errno)); return 1; }
    struct wl_registry *reg = wl_display_get_registry(disp);
    wl_registry_add_listener(reg, &regl, NULL);
    wl_display_roundtrip(disp);
    if (!fake) { fprintf(stderr, "no org_kde_kwin_fake_input global\n"); return 2; }
    org_kde_kwin_fake_input_authenticate(fake, "drm-takeover", "touch-forwarding");
    wl_display_roundtrip(disp);

    int ifd = open(node, O_RDONLY);
    if (ifd < 0) { fprintf(stderr, "open %s: %s\n", node, strerror(errno)); return 3; }
    touch_range_from_evdev(ifd);

    fprintf(stderr, "touchinj ready (%d s, node=%s, rot=%s), touch the panel\n",
            secs, node, ROT);

    int cur = 0;
    time_t end = time(NULL) + secs;
    while (time(NULL) < end) {
        fd_set rf; FD_ZERO(&rf); FD_SET(ifd, &rf);
        struct timeval tv = { 0, 200000 };
        int wfd = wl_display_get_fd(disp);
        if (wl_display_prepare_read(disp) == 0) {
            FD_SET(wfd, &rf);
            if (select((ifd > wfd ? ifd : wfd) + 1, &rf, NULL, NULL, &tv) <= 0) {
                wl_display_cancel_read(disp);
                continue;
            }
            wl_display_read_events(disp);
            wl_display_dispatch_pending(disp);
        } else if (select(ifd + 1, &rf, NULL, NULL, &tv) <= 0) {
            continue;
        }
        struct input_event ev[64];
        ssize_t n = read(ifd, ev, sizeof ev);
        if (n <= 0) continue;
        int syn = 0;
        for (ssize_t i = 0; i < n / (ssize_t)sizeof(ev[0]); i++) {
            if (ev[i].type == EV_SYN && ev[i].code == SYN_REPORT) { syn = 1; continue; }
            if (ev[i].type != EV_ABS) continue;
            switch (ev[i].code) {
            case ABS_MT_SLOT:
                if (ev[i].value >= 0 && ev[i].value < NSLOT) cur = ev[i].value;
                break;
            case ABS_MT_TRACKING_ID: slots[cur].on = ev[i].value >= 0; break;
            case ABS_MT_POSITION_X:  slots[cur].x = ev[i].value; break;
            case ABS_MT_POSITION_Y:  slots[cur].y = ev[i].value; break;
            }
        }
        if (syn) flush_touches();
    }
    close(ifd);
    fprintf(stderr, "touchinj done\n");
    return 0;
}

/* touchtest v2 — same visual contract as v1 (bg + red border + one orange
 * circle per touch point) but the render path no longer amplifies drag
 * latency:
 *   - buffers allocated once (double-buffered memfd pool), rebuilt on resize
 *   - each redraw is a template memcpy instead of a per-pixel fill loop
 *   - damage limited to the bounding box of old ∪ new circle positions
 *   - at most one redraw per compositor frame (wl_surface.frame gating),
 *     motion events coalesce into the latest position instead of queueing
 * v1 filled ~27MB synchronously per touch frame at ~120Hz → event backlog →
 * the dot lagged further behind the finger the longer the drag went on.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/memfd.h>
#include <wayland-client.h>
#include "xdg-shell-protocol.h"

#define BG 0x40101820u
#define FG 0xFFFF30D0u
#define RED 0xFFFF0000u
#define R 40

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct xdg_wm_base *wmbase;
static struct wl_surface *surf;
static struct xdg_surface *xsurf;
static struct xdg_toplevel *xtop;
static struct wl_touch *touch;
static int W = 1280, H = 800;

struct tp { int id, x, y, active; };
static struct tp tps[16];
static struct tp last[16];   /* circles present in the last committed frame */

static uint32_t *tmpl;       /* bg + border, no dots */
static struct wl_buffer *bufs[2];
static uint32_t *pix[2];
static struct wl_shm_pool *pool;
static int poolfd = -1;
static int cur, inflight, pending;
static unsigned motion_count;

static void dot(uint32_t *px, const struct tp *p) {
    if (!p->active) return;
    int x0 = p->x - R, x1 = p->x + R, y0 = p->y - R, y1 = p->y + R;
    if (x0 < 0) x0 = 0;
    if (x1 >= W) x1 = W - 1;
    if (y0 < 0) y0 = 0;
    if (y1 >= H) y1 = H - 1;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            int dx = x - p->x, dy = y - p->y;
            if (dx * dx + dy * dy <= R * R) px[(size_t)y * W + x] = FG;
        }
}

static void render(void);

static void frame_done(void *p, struct wl_callback *cb, uint32_t time) {
    wl_callback_destroy(cb);
    inflight = 0;
    if (pending) { pending = 0; render(); }
}
static const struct wl_callback_listener framelist = { frame_done };

static void render(void) {
    size_t sz = (size_t)W * H * 4;
    memcpy(pix[cur], tmpl, sz);
    for (int i = 0; i < 16; i++) dot(pix[cur], &tps[i]);
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    for (int i = 0; i < 16; i++)
        for (int k = 0; k < 2; k++) {
            const struct tp *p = k ? &tps[i] : &last[i];
            if (!p->active) continue;
            if (!x1 && !y1 && !x0 && !y0) {
                x0 = p->x - R; y0 = p->y - R; x1 = p->x + R; y1 = p->y + R;
            } else {
                if (p->x - R < x0) x0 = p->x - R;
                if (p->y - R < y0) y0 = p->y - R;
                if (p->x + R > x1) x1 = p->x + R;
                if (p->y + R > y1) y1 = p->y + R;
            }
        }
    if (!x1 && !y1 && !x0 && !y0) { x0 = 0; y0 = 0; x1 = W - 1; y1 = H - 1; }
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= W) x1 = W - 1;
    if (y1 >= H) y1 = H - 1;
    wl_surface_attach(surf, bufs[cur], 0, 0);
    wl_surface_damage(surf, x0, y0, x1 - x0 + 1, y1 - y0 + 1);
    struct wl_callback *cb = wl_surface_frame(surf);
    wl_callback_add_listener(cb, &framelist, NULL);
    wl_surface_commit(surf);
    inflight = 1;
    memcpy(last, tps, sizeof last);
    cur ^= 1;
}

static void schedule(void) {
    if (!inflight) render();
    else pending = 1;
}

static int findslot(int id) {
    for (int i = 0; i < 16; i++) if (tps[i].id == id && tps[i].active) return i;
    for (int i = 0; i < 16; i++) if (!tps[i].active) { tps[i].id = id; return i; }
    return -1;
}

static void tp_down(void *p, struct wl_touch *t, uint32_t sn, uint32_t time,
                    struct wl_surface *s, int id, wl_fixed_t x, wl_fixed_t y) {
    int i = findslot(id);
    if (i < 0) return;
    tps[i].active = 1; tps[i].x = wl_fixed_to_int(x); tps[i].y = wl_fixed_to_int(y);
    printf("touch down id=%d at %d,%d (surface %dx%d)\n", id, tps[i].x, tps[i].y, W, H);
    schedule();
}
static void tp_up(void *p, struct wl_touch *t, uint32_t sn, uint32_t time, int id) {
    for (int i = 0; i < 16; i++) if (tps[i].id == id && tps[i].active) tps[i].active = 0;
    schedule();
}
static void tp_motion(void *p, struct wl_touch *t, uint32_t time, int id,
                      wl_fixed_t x, wl_fixed_t y) {
    for (int i = 0; i < 16; i++) if (tps[i].id == id && tps[i].active) {
        tps[i].x = wl_fixed_to_int(x);
        tps[i].y = wl_fixed_to_int(y);
    }
    if (++motion_count % 60 == 0)
        printf("motion %u t=%u latest %d,%d\n", motion_count, time, tps[0].x, tps[0].y);
    schedule();
}
static void tp_frame_ev(void *p, struct wl_touch *t) { }
static void tp_cancel(void *p, struct wl_touch *t) {
    for (int i = 0; i < 16; i++) tps[i].active = 0;
    schedule();
}
static const struct wl_touch_listener touchl = {
    tp_down, tp_up, tp_motion, tp_frame_ev, tp_cancel
};

static void ping(void *p, struct xdg_wm_base *w, uint32_t serial) {
    xdg_wm_base_pong(w, serial);
}
static const struct xdg_wm_base_listener wmbasel = { ping };

static void xconfigure(void *p, struct xdg_surface *x, uint32_t serial) {
    xdg_surface_ack_configure(x, serial);
}
static const struct xdg_surface_listener xsurfl = { xconfigure };

static void alloc_buffers(void) {
    size_t stride = (size_t)W * 4, sz = stride * H;
    if (poolfd >= 0) {
        for (int i = 0; i < 2; i++) if (bufs[i]) wl_buffer_destroy(bufs[i]);
        if (pool) wl_shm_pool_destroy(pool);
        if (pix[0]) munmap(pix[0], sz * 2);
        close(poolfd);
        free(tmpl);
    }
    tmpl = malloc(sz);
    if (!tmpl) { perror("malloc"); exit(1); }
    for (size_t i = 0; i < (size_t)W * H; i++) tmpl[i] = BG;
    for (int i = 0; i < W; i++) { tmpl[i] = RED; tmpl[(size_t)(H - 1) * W + i] = RED; }
    for (int i = 0; i < H; i++) { tmpl[(size_t)i * W] = RED; tmpl[(size_t)i * W + W - 1] = RED; }
    poolfd = (int)syscall(SYS_memfd_create, "tt", MFD_CLOEXEC);
    if (poolfd < 0 || ftruncate(poolfd, (off_t)(sz * 2))) { perror("shm"); exit(1); }
    uint32_t *base = mmap(NULL, sz * 2, PROT_READ | PROT_WRITE, MAP_SHARED, poolfd, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(1); }
    pix[0] = base;
    pix[1] = (uint32_t *)((char *)base + sz);
    pool = wl_shm_create_pool(shm, poolfd, (int32_t)(sz * 2));
    bufs[0] = wl_shm_pool_create_buffer(pool, 0, W, H, (int32_t)stride,
                                        WL_SHM_FORMAT_XRGB8888);
    bufs[1] = wl_shm_pool_create_buffer(pool, (int32_t)sz, W, H, (int32_t)stride,
                                        WL_SHM_FORMAT_XRGB8888);
    memset(last, 0, sizeof last);
    inflight = 0;
    pending = 0;
    cur = 0;
}

static void tconfigure(void *p, struct xdg_toplevel *t, int w, int h,
                       struct wl_array *st) {
    if (w > 0 && h > 0 && (w != W || h != H)) { W = w; H = h; alloc_buffers(); }
    if (w > 0 && h > 0) schedule();
}
static void tclose(void *p, struct xdg_toplevel *t) { exit(0); }
static const struct xdg_toplevel_listener topl = { tconfigure, tclose };

static void global(void *p, struct wl_registry *r, uint32_t id,
                   const char *iface, uint32_t ver) {
    if (!strcmp(iface, "wl_compositor"))
        comp = wl_registry_bind(r, id, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base"))
        wmbase = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat")) {
        struct wl_seat *seat = wl_registry_bind(r, id, &wl_seat_interface, 5);
        touch = wl_seat_get_touch(seat);
        wl_touch_add_listener(touch, &touchl, NULL);
    }
}
static const struct wl_registry_listener regl = { global, NULL };

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &regl, NULL);
    wl_display_roundtrip(dpy);
    if (!comp || !shm || !wmbase || !touch) {
        fprintf(stderr, "missing: comp=%d shm=%d wmbase=%d touch=%d\n",
                !!comp, !!shm, !!wmbase, !!touch);
        return 2;
    }
    xdg_wm_base_add_listener(wmbase, &wmbasel, NULL);
    surf = wl_compositor_create_surface(comp);
    xsurf = xdg_wm_base_get_xdg_surface(wmbase, surf);
    xdg_surface_add_listener(xsurf, &xsurfl, NULL);
    xtop = xdg_surface_get_toplevel(xsurf);
    xdg_toplevel_add_listener(xtop, &topl, NULL);
    xdg_toplevel_set_title(xtop, "touchtest");
    xdg_toplevel_set_app_id(xtop, "touchtest");
    xdg_toplevel_set_fullscreen(xtop, NULL);
    wl_surface_commit(surf);
    wl_display_roundtrip(dpy);
    alloc_buffers();
    render();
    printf("touchtest up %dx%d, waiting for touch\n", W, H);
    while (wl_display_dispatch(dpy) > 0);
    return 0;
}

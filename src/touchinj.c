/* touchinj — read the NVT kernel-direct touchscreen (event11) and inject
 * native touch into kwin via org_kde_kwin_fake_input (bypasses libinput,
 * which rejects our untagged mknod device).
 * usage: touchinj [seconds]   (WAYLAND_DISPLAY + event node from env/defaults)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#include <time.h>
#include <linux/input.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include "fake-input-protocol.h"

#define PANEL_W 3200
#define PANEL_H 2136
#define NSLOT 10

static struct wl_display *disp;
static struct org_kde_kwin_fake_input *fake;

static void global(void *d, struct wl_registry *r, uint32_t id,
                   const char *iface, uint32_t ver) {
    if (!strcmp(iface, org_kde_kwin_fake_input_interface.name)) {
        if (ver > 6) ver = 6;
        fake = wl_registry_bind(r, id, &org_kde_kwin_fake_input_interface, ver);
    }
}
static const struct wl_registry_listener regl = { global, NULL };

struct slot { int on, was, x, y; };
static struct slot slots[NSLOT];

static void flush_touches(void) {
    int any = 0;
    for (int s = 0; s < NSLOT; s++) {
        struct slot *t = &slots[s];
        int cx = t->y / 100;                 /* event11 Y -> panel width  */
        int cy = PANEL_H - 1 - t->x / 100;   /* event11 X -> height, flipped */
        if (cx < 0) cx = 0; if (cx >= PANEL_W) cx = PANEL_W - 1;
        if (cy < 0) cy = 0; if (cy >= PANEL_H) cy = PANEL_H - 1;
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
    const char *node = argc > 2 ? argv[2] : "/dev/input/event11";
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
    fprintf(stderr, "touchinj ready (%d s), touch the panel\n", secs);
    int cur = 0;
    time_t end = time(NULL) + secs;
    while (time(NULL) < end) {
        fd_set rf; FD_ZERO(&rf); FD_SET(ifd, &rf);
        struct timeval tv = { 0, 200000 };
        if (wl_display_prepare_read(disp) == 0) {
            FD_SET(wl_display_get_fd(disp), &rf);
            if (select(ifd + 1 > wl_display_get_fd(disp) + 1 ?
                       ifd + 1 : wl_display_get_fd(disp) + 1, &rf, NULL, NULL, &tv) <= 0) {
                wl_display_cancel_read(disp);
                continue;
            }
            wl_display_read_events(disp);
            wl_display_dispatch_pending(disp);
        } else if (select(ifd + 1, &rf, NULL, NULL, &tv) <= 0) continue;
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

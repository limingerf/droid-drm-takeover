/* raw atomic probe: send DRM_IOCTL_MODE_ATOMIC directly (bypass libdrm
 * helpers) with single-object single-prop requests; print raw errno each
 * time, plus DRM core debug state around it. Needs master (script stops
 * Android first). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <drm.h>
#include <drm_mode.h>
#include <xf86drmMode.h>

static int fd;

static void one(const char *label, uint32_t obj, uint32_t prop, uint64_t val,
                uint32_t extra_flags) {
    uint32_t objs[1] = { obj };
    uint32_t cnts[1] = { 1 };
    uint32_t props[1] = { prop };
    uint64_t vals[1] = { val };
    struct drm_mode_atomic a;
    memset(&a, 0, sizeof a);
    a.flags = DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_ATOMIC_TEST_ONLY |
              extra_flags;
    a.count_objs = obj ? 1 : 0;
    a.objs_ptr = (uint64_t)(unsigned long)objs;
    a.count_props_ptr = (uint64_t)(unsigned long)cnts;
    a.props_ptr = (uint64_t)(unsigned long)props;
    a.prop_values_ptr = (uint64_t)(unsigned long)vals;
    errno = 0;
    int ret = ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &a);
    printf("%-52s raw ret=%d errno=%d (%s)\n", label, ret, errno,
           ret ? strerror(errno) : "ok");
}

static void two(const char *label, uint32_t obj,
                uint32_t p1, uint64_t v1, uint32_t p2, uint64_t v2) {
    uint32_t objs[1] = { obj };
    uint32_t cnts[1] = { 2 };
    uint32_t props[2] = { p1, p2 };
    uint64_t vals[2] = { v1, v2 };
    struct drm_mode_atomic a;
    memset(&a, 0, sizeof a);
    a.flags = DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_ATOMIC_TEST_ONLY;
    a.count_objs = 1;
    a.objs_ptr = (uint64_t)(unsigned long)objs;
    a.count_props_ptr = (uint64_t)(unsigned long)cnts;
    a.props_ptr = (uint64_t)(unsigned long)props;
    a.prop_values_ptr = (uint64_t)(unsigned long)vals;
    errno = 0;
    int ret = ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &a);
    printf("%-52s raw ret=%d errno=%d (%s)\n", label, ret, errno,
           ret ? strerror(errno) : "ok");
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    if (drmSetMaster(fd)) printf("SetMaster: %s (continuing, TEST_ONLY may not need it)\n", strerror(errno));
    else printf("master ok\n");

    struct { uint64_t name; uint64_t value; } cap = { 3 /*ATOMIC*/, 1 };
    errno = 0;
    long rc = ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
    printf("SET_CLIENT_CAP(ATOMIC,1) rc=%ld errno=%d (%s)\n", rc, errno,
           rc ? strerror(errno) : "ok");
    struct { uint64_t name; uint64_t value; } cap2 = { 2 /*UNIVERSAL_PLANE*/, 1 };
    rc = ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap2);
    printf("SET_CLIENT_CAP(UNIVERSAL,1) rc=%ld errno=%d (%s)\n", rc, errno,
           rc ? strerror(errno) : "ok");

    /* empty commit with cap on (control) */
    one("Z empty TEST_ONLY with cap", 0, 0, 0, 0);

    /* enable core debug via module param path? already done by script */

    one("A crtc206 ACTIVE(22)=1  [NOT attached]", 206, 22, 1, 0);
    one("B crtc206 prop99999=1   [nonexistent]", 206, 99999, 1, 0);
    one("C crtc206 VRR_ENABLED(24)=0 [ATTACHED]", 206, 24, 0, 0);
    one("D crtc206 core_clk(210)=100 [ATTACHED range]", 206, 210, 100, 0);
    one("E conn67 DPMS(2)=0      [ATTACHED legacy]", 67, 2, 0, 0);
    one("F conn67 CRTC_ID(20)=206 [NOT attached]", 67, 20, 206, 0);
    one("G plane161 zpos(99)=1   [ATTACHED]", 161, 99, 1, 0);
    one("H plane161 SRC_X(9)=0   [NOT attached]", 161, 9, 0, 0);
    one("I plane161 FB_ID(17)=0  [NOT attached]", 161, 17, 0, 0);
    one("J crtc206 ACTIVE(22)=0  [NOT attached]", 206, 22, 0, 0);
    /* bogus object id: does object lookup itself work? */
    one("K obj999999 prop22=1", 999999, 22, 1, 0);

    /* --- round 2: pairs actually present in drmatomic's failing request --- */
    uint32_t blob = 0;
    drmModeCrtcPtr cc = drmModeGetCrtc(fd, 206);
    if (cc) {
        if (drmModeCreatePropertyBlob(fd, &cc->mode, sizeof cc->mode, &blob))
            printf("blob: %s\n", strerror(errno));
        else
            printf("blob %u from crtc206 mode %dx%d\n", blob,
                   cc->mode.hdisplay, cc->mode.vdisplay);
        drmModeFreeCrtc(cc);
    } else printf("GetCrtc206 failed: %s\n", strerror(errno));

    one("L conn67 MODE_ID(23)=blob", 67, 23, blob, 0);
    one("M crtc206 MODE_ID(23)=blob", 206, 23, blob, 0);
    one("N crtc206 MODE_ID(23)=0", 206, 23, 0, 0);
    two("O conn67 CRTC_ID(20)=206+MODE_ID(23)=blob", 67, 20, 206, 23, blob);
    two("P crtc206 ACTIVE(22)=1+MODE_ID(23)=blob", 206, 22, 1, 23, blob);
    one("Q plane157 FB_ID(17)=0", 157, 17, 0, 0);
    one("R plane157 CRTC_ID(20)=206", 157, 20, 206, 0);
    one("S plane157 SRC_W(11)=0", 157, 11, 0, 0);
    one("T plane157 CRTC_X(13)=0", 157, 13, 0, 0);
    one("U plane157 CRTC_H(16)=0", 157, 16, 0, 0);
    one("V plane157 FB_DAMAGE_CLIPS(21)=0", 157, 21, 0, 0);
    printf("DONE\n");
    return 0;
}

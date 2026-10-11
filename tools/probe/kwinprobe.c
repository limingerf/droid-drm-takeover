/* kwinprobe — replay kwin DrmBackend::addGpu's exact check chain on the
 * (hijacked) card fd, under whatever wrapper context we are testing. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <drm/drm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(void)
{
    errno = 0;
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    printf("open ret=%d errno=%d(%s)\n", fd, errno, strerror(errno));
    if (fd < 0) return 1;
    errno = 0;
    int kms = drmIsKMS(fd);
    printf("drmIsKMS=%d errno=%d(%s)\n", kms, errno, strerror(errno));
    errno = 0;
    drmVersion *v = drmGetVersion(fd);
    printf("drmGetVersion=%s%s%s %d.%d\n", v ? v->name : "FAIL",
           v ? "" : " errno=", v ? "" : strerror(errno),
           v ? v->version_major : -1, v ? v->version_minor : -1);
    errno = 0;
    int m = drmIsMaster(fd);
    printf("drmIsMaster=%d errno=%d(%s)\n", m, errno, strerror(errno));
    errno = 0;
    int rc = drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);
    printf("SetClientCap(ATOMIC)=%d errno=%d(%s)\n", rc, errno, strerror(errno));
    errno = 0;
    drmModeRes *r = drmModeGetResources(fd);
    printf("GetResources=%s crtcs=%d encoders=%d connectors=%d errno=%d(%s)\n",
           r ? "OK" : "FAIL", r ? r->count_crtcs : -1,
           r ? r->count_encoders : -1, r ? r->count_connectors : -1,
           errno, strerror(errno));
    errno = 0;
    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    printf("GetPlaneResources=%s n=%u errno=%d(%s)\n", pr ? "OK" : "FAIL",
           pr ? pr->count_planes : 0, errno, strerror(errno));
    /* AddFB is DRM_MASTER|DRM_AUTH: -1/ENOENT = master gate passed,
     * -1/EACCES = treated as non-master by this vendor kernel */
    errno = 0;
    uint32_t fb_id = 0;
    int fb = drmModeAddFB(fd, 1, 1, 32, 24, 4, 0xdeadbeef, &fb_id);
    printf("AddFB=%d errno=%d(%s)\n", fb, errno, strerror(errno));
    /* THE master gate: empty TEST_ONLY atomic — EACCES iff not current master,
     * 0 iff master; touches no hardware state */
    struct drm_mode_atomic at = { .flags = DRM_MODE_ATOMIC_TEST_ONLY };
    errno = 0;
    int ar = ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &at);
    printf("ATOMIC-EMPTY=%d errno=%d(%s)\n", ar, errno, strerror(errno));
    if (v) drmFreeVersion(v);
    return 0;
}

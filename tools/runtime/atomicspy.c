/* atomicspy.so — LD_PRELOAD shim logging every DRM_IOCTL_MODE_ATOMIC made
 * by the wrapped process, then passing it through unchanged.
 * UAPI (multi-object form, drivers/gpu/drm/drm_mode.h):
 *   objs_ptr          __u32[count_objs]     object id per group
 *   count_props_ptr   __u32[count_objs]     props in each group
 *   props_ptr         __u32[total_props]    flat prop ids, groups concatenated
 *   prop_values_ptr   __u64[total_props]    matching values
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

static FILE *out;
static int (*real_ioctl)(int, unsigned long, ...);

static void init(void) {
    if (out) return;
    const char *p = getenv("DRMSPY_OUT");
    out = fopen(p && *p ? p : "/tmp/atomicspy.log", "ae");
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    if (out) {
        fprintf(out, "== shim loaded, pid=%d, ioctl_sym=%p ==\n",
                getpid(), (void *)real_ioctl);
        fflush(out);
    }
}

__attribute__((constructor)) static void ctor(void) { init(); }

int ioctl(int fd, unsigned long req, ...) {
    void *argp;
    va_list ap;
    va_start(ap, req);
    argp = va_arg(ap, void *);
    va_end(ap);

    init();
    if (!real_ioctl)
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    if (req == DRM_IOCTL_MODE_ATOMIC && out) {
        struct drm_mode_atomic *a = argp;
        __u32 *objs = (__u32 *)(unsigned long)a->objs_ptr;
        __u32 *cnts = (__u32 *)(unsigned long)a->count_props_ptr;
        __u32 *props = (__u32 *)(unsigned long)a->props_ptr;
        __u64 *vals = (__u64 *)(unsigned long)a->prop_values_ptr;
        fprintf(out, "COMMIT fd=%d flags=0x%x nobjs=%u\n",
                fd, a->flags, a->count_objs);
        unsigned off = 0;
        for (__u32 o = 0; o < a->count_objs; o++) {
            fprintf(out, "  obj=%u nprops=%u%s\n", objs[o], cnts[o],
                    (a->flags & DRM_MODE_ATOMIC_TEST_ONLY) ? " [TEST_ONLY]" : "");
            for (__u32 i = 0; i < cnts[o]; i++)
                fprintf(out, "    prop=%-4u val=0x%llx\n",
                        props[off + i], (unsigned long long)vals[off + i]);
            off += cnts[o];
        }
        fflush(out);
    }
    int ret = real_ioctl(fd, req, argp);
    if (req == DRM_IOCTL_MODE_ATOMIC && out) {
        int e = errno;
        fprintf(out, "  -> ret=%d errno=%d (%s)\n", ret, e, strerror(e));
        fflush(out);
    }
    return ret;
}

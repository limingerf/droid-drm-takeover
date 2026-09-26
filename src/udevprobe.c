#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysmacros.h>
#include <libudev.h>

int main(int argc, char **argv) {
    struct udev *u = udev_new();
    if (!u) { printf("udev_new FAIL\n"); return 1; }

    struct udev_device *d = udev_device_new_from_devnum(u, 'c', makedev(226, 0));
    printf("from_devnum 226:0 -> %s\n", d ? "OK" : "NULL");
    if (d) {
        printf("  devnode=%s syspath=%s subsystem=%s devtype=%s\n",
               udev_device_get_devnode(d), udev_device_get_syspath(d),
               udev_device_get_subsystem(d), udev_device_get_devtype(d));
    }

    struct udev_enumerate *e = udev_enumerate_new(u);
    udev_enumerate_add_match_subsystem(e, "drm");
    udev_enumerate_scan_devices(e);
    struct udev_list_entry *l;
    int n = 0;
    udev_list_entry_foreach (l, udev_enumerate_get_list_entry(e)) {
        const char *syspath = udev_list_entry_get_name(l);
        struct udev_device *dd = udev_device_new_from_syspath(u, syspath);
        const char *node = dd ? udev_device_get_devnode(dd) : NULL;
        const char *dt = dd ? udev_device_get_devtype(dd) : NULL;
        if (dt && strcmp(dt, "drm_minor") == 0) {
            printf("  enum[%d] %s node=%s\n", n, node ?: "(null)", syspath);
            n++;
        } else if (dt) printf("  (skipped devtype=%s %s)\n", dt, syspath);
    }
    printf("drm_minor enumerated: %d\n", n);
    return 0;
}

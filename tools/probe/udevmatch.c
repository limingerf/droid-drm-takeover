#include <stdio.h>
#include <string.h>
#include <sys/sysmacros.h>
#include <libudev.h>

static void dump(struct udev_device *d, const char *tag) {
    printf("%s: node=%s sysname=%s ID_SEAT=%s ID_INPUT=%s devtype=%s DRIVER=%s\n",
           tag,
           udev_device_get_devnode(d) ?: "(null)",
           udev_device_get_sysname(d) ?: "(null)",
           udev_device_get_property_value(d, "ID_SEAT") ?: "(null)",
           udev_device_get_property_value(d, "ID_INPUT") ?: "(null)",
           udev_device_get_devtype(d) ?: "(null)",
           udev_device_get_property_value(d, "DRIVER") ?: "(null)");
}

int main() {
    struct udev *u = udev_new();

    struct udev_enumerate *e = udev_enumerate_new(u);
    udev_enumerate_add_match_subsystem(e, "drm");
    udev_enumerate_add_match_sysname(e, "card[0-9]");
    udev_enumerate_scan_devices(e);
    printf("glob card[0-9]:\n");
    struct udev_list_entry *l;
    udev_list_entry_foreach(l, udev_enumerate_get_list_entry(e)) {
        struct udev_device *d = udev_device_new_from_syspath(u, udev_list_entry_get_name(l));
        printf("  %s\n", udev_list_entry_get_name(l));
        if (d)
            dump(d, "   ");
    }

    struct udev_device *c = udev_device_new_from_devnum(u, 'c', makedev(226, 0));
    if (c)
        dump(c, "from_devnum");
    else
        printf("from_devnum NULL\n");
    return 0;
}

#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DRM_IOCTL_SET_MASTER 0x4004641E

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    int ret = ioctl(fd, DRM_IOCTL_SET_MASTER, 0);
    if (ret)
        perror("SET_MASTER");
    else
        printf("SET_MASTER OK (tid-owner thread, same as opener)\n");
    return ret != 0;
}

/*
 * blobdump —— 读 DRM property blob 的原始内容（用于看面板期望的 DSC 参数）。
 *
 * 背景（2026-10-12）：DSI 链路实测正常（两条 ctrl 都 ON、时钟对称），
 * 但面板解不出画面（彩色噪声）。面板期望的 DSC 参数写在连接器的
 * mode_properties / capabilities blob 里，只有 DRM master 能读。
 *
 * 用法: blobdump <card> <blob_id> [最大字节数]
 *       blobdump <card> --conn=<id>      列出该连接器所有 blob 属性并逐个 dump
 * 打印 BLOBDUMP_DONE。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm/drm_mode.h>

static int FD = -1;

static void dump_blob(uint32_t id, int maxb)
{
    drmModePropertyBlobPtr b = drmModeGetPropertyBlob(FD, id);
    if (!b) {
        printf("  blob %u: 读取失败 (%s)\n", id, strerror(errno));
        return;
    }
    printf("  blob %u: %u 字节\n", id, b->length);
    const unsigned char *p = b->data;
    int n = (int)b->length;
    if (maxb > 0 && n > maxb) n = maxb;
    /* ★ 关键：qcom 的 mode_properties / capabilities blob 是**纯文本**的
     *   "k=v\n" 列表（不是二进制结构）。直接原样打印出来最有用 ——
     *   之前只看 hex 根本读不出 DSC 期望值。 */
    int printable = 1;
    for (unsigned i = 0; i < b->length; i++) {
        unsigned char c = p[i];
        if (c != '\n' && c != '\t' && (c < 32 || c > 126)) { printable = 0; break; }
    }
    if (printable && b->length > 1) {
        printf("    ── 文本内容 ──\n");
        const unsigned char *s = p;
        unsigned i = 0;
        while (i < b->length) {
            unsigned j = i;
            while (j < b->length && p[j] != '\n') j++;
            if (j > i) {
                printf("    ");
                fwrite(p + i, 1, j - i, stdout);
                printf("\n");
            }
            i = j + 1;
        }
        drmModeFreePropertyBlob(b);
        return;
    }

    for (int i = 0; i < n; i += 16) {
        printf("    %04x:", i);
        for (int j = 0; j < 16 && i + j < n; j++)
            printf(" %02x", p[i + j]);
        printf("  ");
        for (int j = 0; j < 16 && i + j < n; j++) {
            unsigned char c = p[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("\n");
    }
    /* 顺便按 uint32 解释一遍，方便看 DSC 数值 */
    if (b->length % 4 == 0 && b->length <= 256) {
        printf("    按 u32 解释: ");
        for (unsigned i = 0; i + 4 <= b->length; i += 4) {
            uint32_t v;
            memcpy(&v, p + i, 4);
            printf("%u ", v);
        }
        printf("\n");
    }
    drmModeFreePropertyBlob(b);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <card> <blob_id> [maxbytes]\n"
                        "      %s <card> --conn=<id>\n", argv[0], argv[0]);
        return 2;
    }
    FD = open(argv[1], O_RDWR | O_CLOEXEC);
    if (FD < 0) { fprintf(stderr, "打开 %s 失败: %s\n", argv[1], strerror(errno)); return 1; }

    if (!strncmp(argv[2], "--conn=", 7)) {
        uint32_t cn = (uint32_t)strtoul(argv[2] + 7, NULL, 0);
        drmModeObjectPropertiesPtr ps =
            drmModeObjectGetProperties(FD, cn, DRM_MODE_OBJECT_CONNECTOR);
        if (!ps) { fprintf(stderr, "取连接器属性失败: %s\n", strerror(errno)); close(FD); return 1; }
        printf("连接器 %u 的 blob 属性:\n", cn);
        for (uint32_t i = 0; i < ps->count_props; i++) {
            drmModePropertyPtr p = drmModeGetProperty(FD, ps->props[i]);
            if (!p) continue;
            if (p->flags & DRM_MODE_PROP_BLOB) {
                printf("── %s (prop=%u) blob=%u\n", p->name, p->prop_id,
                       (uint32_t)ps->prop_values[i]);
                if (ps->prop_values[i])
                    dump_blob((uint32_t)ps->prop_values[i], 0);
            }
            drmModeFreeProperty(p);
        }
        drmModeFreeObjectProperties(ps);
    } else {
        uint32_t id = (uint32_t)strtoul(argv[2], NULL, 0);
        int maxb = argc > 3 ? atoi(argv[3]) : 0;
        dump_blob(id, maxb);
    }

    close(FD);
    printf("BLOBDUMP_DONE\n");
    return 0;
}

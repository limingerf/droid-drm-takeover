// h4framing-test.cpp — h4framing.h 的宿主机单测（不需要设备、不需要 NDK）。
//
// 为什么值得单独写：h4framing.h 里那两段逻辑是"内核 H4 解析器一旦跑偏就永久哑"的入口。
// 一次 HAL 回调里可能带多个包、pty 又可能只吃掉半包 —— 这两件事在设备上出错的代价是
// 蓝牙彻底哑掉（而且症状是"命令全哑、事件洪水"，非常难反推）。所以先在宿主机断言。
//
// 编译运行： sh bt/build.sh 会自动跑；也可 c++ -std=c++17 -o t bt/h4framing-test.cpp && ./t
#include "h4framing.h"

#include <cstdio>
#include <cstring>
#include <vector>

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, ...)                                     \
    do {                                                     \
        if (cond) {                                          \
            ++g_pass;                                        \
        } else {                                             \
            ++g_fail;                                        \
            printf("  ✗ %s:%d  ", __FILE__, __LINE__);       \
            printf(__VA_ARGS__);                             \
            printf("\n");                                    \
        }                                                    \
    } while (0)

using namespace h4;

// ── 1. frame_len：每种类型的总长（含类型字节）────────────────────────
static void test_frame_len() {
    printf("[1] frame_len\n");
    // Command: [01][op_lo][op_hi][plen][..]  总长 = 4 + plen
    const uint8_t cmd[] = {0x01, 0x03, 0x0c, 0x00};
    CHECK(frame_len(cmd, sizeof(cmd)) == 4, "Command 空参 应为 4，得到 %zu",
          frame_len(cmd, sizeof(cmd)));
    // ACL: [02][h_lo][h_hi][dl_lo][dl_hi][..] 总长 = 5 + dlen（小端）
    const uint8_t acl[] = {0x02, 0x01, 0x00, 0x10, 0x00};
    CHECK(frame_len(acl, sizeof(acl)) == 0x15, "ACL dlen=0x0010 应为 21，得到 %zu",
          frame_len(acl, sizeof(acl)));
    // SCO: [03][h_lo][h_hi][len][..] 总长 = 4 + len
    const uint8_t sco[] = {0x03, 0x01, 0x00, 0x08};
    CHECK(frame_len(sco, sizeof(sco)) == 12, "SCO len=8 应为 12，得到 %zu",
          frame_len(sco, sizeof(sco)));
    // Event: [04][code][plen][..] 总长 = 3 + plen
    const uint8_t evt[] = {0x04, 0x0e, 0x04};
    CHECK(frame_len(evt, sizeof(evt)) == 7, "Event plen=4 应为 7，得到 %zu",
          frame_len(evt, sizeof(evt)));
    // ISO：长度算法不确定 ⇒ 返回 0（整块原样，绝不瞎拆）
    const uint8_t iso[] = {0x05, 0x01, 0x02, 0x03};
    CHECK(frame_len(iso, sizeof(iso)) == 0, "ISO 应返回 0（不拆）");
    // 未知类型 ⇒ (size_t)-1
    const uint8_t bad[] = {0x09, 0x00};
    CHECK(frame_len(bad, sizeof(bad)) == (size_t)-1, "未知类型应返回 -1");
    // 头不全 ⇒ 0
    const uint8_t shortcmd[] = {0x01, 0x03};
    CHECK(frame_len(shortcmd, sizeof(shortcmd)) == 0, "Command 头不全应返回 0");
}

// ── 2. classify：拆包决策 ────────────────────────────────────────────
static void test_classify() {
    printf("[2] classify\n");
    size_t n = 0;
    // 正好一个完整 Event
    const uint8_t one[] = {0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00};
    CHECK(classify(one, sizeof(one), &n) == Kind::kWhole && n == 7,
          "整包应 kWhole/7，得到 %d/%zu", (int)classify(one, sizeof(one), &n), n);

    // 一个完整包 + 后面还跟着一个包的头 ⇒ 必须拆（kMulti）
    const uint8_t two[] = {0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00, 0x04, 0x0e};
    Kind k = classify(two, sizeof(two), &n);
    CHECK(k == Kind::kMulti && n == 7, "应 kWhole 前 7 字节（kMulti），得到 %d/%zu", (int)k, n);

    // 声称更长却没给够 ⇒ kShort（上游已截断），n 填"应有"的长度
    const uint8_t trunc[] = {0x04, 0x0e, 0x10, 0x01};
    k = classify(trunc, sizeof(trunc), &n);
    CHECK(k == Kind::kShort && n == 0x13, "应 kShort/19，得到 %d/%zu", (int)k, n);

    // 头不全 ⇒ kWhole 且 out_len = n（整块原样，等更多字节由调用方决定）
    const uint8_t partial[] = {0x04, 0x0e};
    k = classify(partial, sizeof(partial), &n);
    CHECK(k == Kind::kWhole && n == 2, "头不全应 kWhole/2（整块原样），得到 %d/%zu", (int)k, n);

    // 未知类型 ⇒ kBadType
    const uint8_t bad[] = {0x42, 0x00, 0x00};
    CHECK(classify(bad, sizeof(bad), &n) == Kind::kBadType, "未知类型应 kBadType");

    // ISO ⇒ 整块原样（不猜长度）
    const uint8_t iso[] = {0x05, 0x01, 0x02, 0x03, 0x04};
    k = classify(iso, sizeof(iso), &n);
    CHECK(k == Kind::kWhole && n == sizeof(iso), "ISO 应整块原样 %zu 字节，得到 %d/%zu",
          sizeof(iso), (int)k, n);

    // 空缓冲 ⇒ kMore
    CHECK(classify(nullptr, 0, &n) == Kind::kMore, "空缓冲应 kMore");
}

// ── 3. write_full：短写必须续写；写不进且超时才能放弃 ─────────────────
static void test_write_full() {
    printf("[3] write_full\n");
    const uint8_t data[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};

    // 每次只写 3 字节 ⇒ 必须续写到写完
    {
        size_t off = 0, calls = 0;
        size_t got = write_full(data, sizeof(data), &off,
                                [&](const uint8_t*, size_t len) -> size_t {
                                    ++calls;
                                    return len < 3 ? len : 3;
                                },
                                false);
        CHECK(got == sizeof(data) && off == sizeof(data), "短写续写应写完，得到 %zu/%zu", got, off);
        CHECK(calls == 4, "10 字节每次 3 字节应 4 次调用，得到 %zu", calls);
    }

    // 写不进（返回 0）+ 未超时 ⇒ 停下并把 off 停在已写位置，绝不假装成功
    {
        size_t off = 2;
        size_t got = write_full(data, sizeof(data), &off,
                                [](const uint8_t*, size_t) -> size_t { return 0; }, false);
        CHECK(got == 2 && off == 2, "写不进应停在 off=2，得到 %zu/%zu", got, off);
    }

    // 已经超时 ⇒ 一个字节都不写
    {
        size_t off = 0;
        size_t got = write_full(data, sizeof(data), &off,
                                [](const uint8_t*, size_t len) -> size_t { return len; }, true);
        CHECK(got == 0 && off == 0, "超时应不写，得到 %zu/%zu", got, off);
    }
}

// ── 4. may_drop：只有"一个字节都没写出去"才允许丢 ─────────────────────
static void test_may_drop() {
    printf("[4] may_drop\n");
    CHECK(may_drop(0, 5000, 1000) == true, "off=0 且超时应允许丢");
    CHECK(may_drop(0, 500, 1000) == false, "off=0 但没超时不应丢");
    CHECK(may_drop(1, 999999, 1000) == false,
          "★ off>0（已写一半）**永远不许丢** —— 半包会把内核 H4 解析器带偏");
}

int main() {
    printf("h4framing 宿主机单测\n");
    test_frame_len();
    test_classify();
    test_write_full();
    test_may_drop();
    printf("\n结果：%d 通过，%d 失败\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}

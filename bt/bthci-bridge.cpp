// bthci-bridge.cpp — DRM 接管期的蓝牙 HCI 桥（HIDL 客户端版）
//
// 一个进程干两件事（安卓侧 root 运行）：
//   1) 开一对 pty，在 slave 上挂 N_HCI + HCIUARTSETPROTO(H4) → 共享内核里注册出真 hci0
//      （已实测：零新内核模块；进程退出 → tty 关闭 → hci_unregister_dev 自动回收）
//   2) 做 vendor 蓝牙 HAL 的 **HIDL/hwbinder 客户端**：
//      getService("default") → initialize(回调) → pty 上的 H4 帧与 HAL 双向搬运。
//      上电、固件下载、glink/IBS 全部仍由 HAL 负责，我们只是在它上面多挂一个客户端。
//
// ══════════════════════════════════════════════════════════════════════════
// 为什么是 HIDL 而不是 AIDL
// ══════════════════════════════════════════════════════════════════════════
// 本机（Lenovo TB710FU；移植 ColorOS 后 ro.product.model 报成 OPPO Pad OPD2511，
// ro.board.platform=pineapple）的 BT HAL 注册在 **hwservicemanager**（/dev/hwbinder）：
//   lshal → android.hardware.bluetooth@1.0::IBluetoothHci/default  (DM,FC  Y)
// 而 `service check android.hardware.bluetooth...` 在 framework servicemanager 里
// 查不到 —— 这就是旧 AIDL 桥（binder_ndk）连不上的根本原因。
//
// ══════════════════════════════════════════════════════════════════════════
// 回调节点怎么造（实测反推，见 probe/bt/HIDL-探针结论.md）
// ══════════════════════════════════════════════════════════════════════════
// 不自己写 IBluetoothHciCallbacks 实现类（虚继承 + vbase offset + RefBase 布局，
// 手写必错）。改用 **vendor .so 自己导出的 BsBluetoothHciCallbacks 构造器**：
//
//   _ZN7android8hardware9bluetooth4V1_023BsBluetoothHciCallbacksC1ENS_2spINS2_22IBluetoothHciCallbacksEEE
//   ABI: void ctor(void* self, const sp<IBluetoothHciCallbacks>* impl)   // sp 按值 → 不可见引用
//
// 构造出来的对象布局（实测）：
//   +0x00  主 vptr
//   +0x08  HidlInstrumentor 子对象（自带 vptr）
//   +0x60  sp<IBluetoothHciCallbacks> mImpl
//   +0x68  TaskRunner
//   +0x78  RefBase（真 RefBase::RefBase() 已调用）
//   vptr[-4..-1] = 0x0 0x78 0x0 0x0   ← offset-to-top, vbase: RefBase@0x78, IInterface@0, IBase@0
//
// Bs 的**每个**方法都 `ldr x21,[x21,#0x60]` 转发给 mImpl ⇒ 把 mImpl 指向自己，
// 再补丁主 vtable 就全部接管。主 vtable 槽位（实测）：
//   0 isRemote / 1 interfaceChain / 2 debug / 3 interfaceDescriptor / 4 getHashChain
//   5 setHALInstrumentation / 6 linkToDeath / 7 ping / 8 getDebugInfo
//   9 notifySyspropsChanged / 10 unlinkToDeath / 11 getInterfaceVersion / 12 getInterfaceHash
//   13 initializationComplete / 14 hciEventReceived / 15 aclDataReceived / 16 scoDataReceived
//
// ⚠️ 两个必须踩对的坑：
//   A) 平台带 -fsanitize=cfi-vcall：虚调用前有 vtable 范围校验（锚点
//      _ZTV...BpHwBluetoothHciCallbacksE 的地址点）。vptr 换成我们自己二进制里的表
//      会被判失败 → __cfi_slowpath。**必须 mprotect vendor .data.rel.ro 就地改那张表**，
//      vptr 保持原值。退出时把页权限改回 R（父 agent 提醒：别留 W 给下一个加载者）。
//   B) 回调 handler 必须返回**非平凡类型**（ReturnVoid），否则编译器不设 x8 传 sret，
//      参数整体错位一格（self 收到 x1、payload 收到 x2 垃圾）→ 段错误。
//      同时 sret 里 offset 32（mCheckedStatus）要置 1，否则平台 Return::onIgnored() 可能 fatal。
//
// ══════════════════════════════════════════════════════════════════════════
// HciPacket 到底带不带 H4 类型字节
// ══════════════════════════════════════════════════════════════════════════
// **不带。** 依据是 AOSP 参考实现（不是猜）：
//   hardware/interfaces/bluetooth/1.1/default/bluetooth_hci.cc
//     Return<void> BluetoothHci::sendHciCommand(const hidl_vec<uint8_t>& command) {
//       sendDataToController(HCI_DATA_TYPE_COMMAND, command); }
//     void BluetoothHci::sendDataToController(uint8_t type, const hidl_vec<uint8_t>& data) {
//       VendorInterface::get()->Send(type, data.data(), data.size()); }
//   hardware/interfaces/bluetooth/hci/h4_protocol.cc
//     size_t H4Protocol::Send(PacketType type, const uint8_t* data, size_t length) {
//       struct iovec iov_array[] = {{&type, sizeof(type)}, {data, length}}; ... }
// 类型是**单独参数**，payload 只有包体。回调方向同理（OnPacketReady 的 packet 不含类型）。
// 但 vendor 是 QTI 自己的实现，所以回调方向做**长度自校验的自动判定**（见 cbHasTypeByte），
// 不靠首字节猜（事件码 / ACL handle 低位与 0x01..0x05 取值范围重叠，首字节启发式必错）。
//
// ══════════════════════════════════════════════════════════════════════════
// 线程模型
// ══════════════════════════════════════════════════════════════════════════
//   binder 池线程 ×N   ：收 HAL 的同步回调 → 只入队（绝不在这里做 pty IO）
//   写线程 ×1          ：出队 → 有界阻塞写 pty master（要么整包写完，要么一个字节都不写）
//   主线程             ：poll pty master → H4 切帧 → 同步调 sendHciCommand/Acl/Sco
//   熔断               ：每 N 秒查 init.svc.surfaceflinger，running 就立刻退场
//
// 绝对不做：不 open /dev/bt_cp_ctrl、不 open /dev/ttyHS0、不打任何 btpower/geni 电源 ioctl、
//           不写 /sys/class/rfkill/*、不 setenforce 0、不 ctl.stop HAL、不碰容器配置。
//
// 编译：sh bt/build.sh（NDK；CI 在 .github/workflows/build.yml 的 btbridge job）
// 运行：adb push bthci-bridge /data/local/tmp/ && adb shell su -c '/data/local/tmp/bthci-bridge --keep 3600'
// 退出：pkill -x bthci-bridge   （-x 精确匹配是硬要求，绝不用 -f）

#include <cerrno>
#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "h4framing.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef TIOCSETD
#define TIOCSETD 0x541b
#endif
#ifndef N_HCI
#define N_HCI 15
#endif
#ifndef N_TTY
#define N_TTY 0
#endif
#ifndef TIOCGPTN
#define TIOCGPTN 0x80045430
#endif
#ifndef TIOCSPTLCK
#define TIOCSPTLCK 0x40045431
#endif
#ifndef HCIUARTSETPROTO
#define HCIUARTSETPROTO 0x400455C8  // _IOW('U', 200, int)
#endif
#ifndef HCIUARTGETDEVICE
#define HCIUARTGETDEVICE 0x800455CA  // _IOR('U', 202, int)
#endif
#define HCI_UART_H4 0

// H4 类型字节
static constexpr uint8_t H4_CMD = 0x01, H4_ACL = 0x02, H4_SCO = 0x03, H4_EVT = 0x04;

// ============================================================ 最小 HIDL ABI 复刻
//
// ★★ 这里每个类型都必须和平台侧**逐字节同布局**，因为我们会跨 DSO 直接调它的成员函数。
//    判据来自实测（btprobe.cpp 打出的 sizeof）与 AOSP 头文件：
//      hidl_string = { hidl_pointer<const char> mBuffer; uint32_t mSize; bool mOwnsBuffer; uint8_t mPad[3]; }
//      hidl_vec<T> = { hidl_pointer<T> mBuffer; uint32_t mSize; bool mOwnsBuffer; uint8_t mPad[3]; }
//      Return<void> = { int32 mException; int32 mErrorCode; std::string mMessage; bool mCheckedStatus; } = 40B
//    hidl_pointer 在 64 位下就是裸指针（无 32 位偏移压缩）。
namespace android {
// 与平台 android::sp<T> 同 ABI：8 字节、非平凡拷贝/析构 → 返回值走 sret
template <typename T>
class sp {
  public:
    T* m_ptr;
    sp() : m_ptr(nullptr) {}
    sp(T* p) : m_ptr(p) {}
    sp(const sp& o) : m_ptr(o.m_ptr) {}
    ~sp() {}
    T* get() const { return m_ptr; }
};
}  // namespace android

namespace android {
namespace hardware {

struct hidl_string {
    const char* mBuffer;
    uint32_t mSize;
    bool mOwnsBuffer;
    uint8_t mPad[3];
    const char* c_str() const { return mBuffer ? mBuffer : ""; }
};

template <typename T>
struct hidl_vec {
    T* mBuffer;
    uint32_t mSize;
    bool mOwnsBuffer;
    uint8_t mPad[3];
};

// 非平凡析构 ⇒ 强制走 x8 隐藏 sret，与平台 Return<void> 的传参方式一致
struct ReturnVoid {
    uint8_t raw[40];
    ~ReturnVoid() {}
    int32_t exceptionCode() const {
        int32_t v;
        memcpy(&v, raw, 4);
        return v;
    }
};

}  // namespace hardware
}  // namespace android

using android::hardware::hidl_string;
using android::hardware::hidl_vec;
using android::hardware::ReturnVoid;

// ============================================================ 符号名（全部来自 llvm-readelf 实测）
#define SO_HCI10 "/vendor/lib64/android.hardware.bluetooth@1.0.so"
#define SO_HIDLBASE "/system/lib64/libhidlbase.so"

#define SYM_GETSERVICE \
    "_ZN7android8hardware9bluetooth4V1_013IBluetoothHci10getServiceERKNSt3__112basic_stringIcNS4_11char_traitsIcEENS4_9allocatorIcEEEEb"
#define SYM_BP(x) "_ZN7android8hardware9bluetooth4V1_016BpHwBluetoothHci" x
#define S_INIT    "10initializeERKNS_2spINS2_22IBluetoothHciCallbacksEEE"
#define S_SENDCMD "14sendHciCommandERKNS0_8hidl_vecIhEE"
#define S_SENDACL "11sendAclDataERKNS0_8hidl_vecIhEE"
#define S_SENDSCO "11sendScoDataERKNS0_8hidl_vecIhEE"
#define S_CLOSE   "5closeEv"

#define SYM_BS_CTOR \
    "_ZN7android8hardware9bluetooth4V1_023BsBluetoothHciCallbacksC1ENS_2spINS2_22IBluetoothHciCallbacksEEE"

#define SYM_CFG_POOL  "_ZN7android8hardware22configureRpcThreadpoolEmb"
#define SYM_JOIN_POOL "_ZN7android8hardware17joinRpcThreadpoolEv"

#define DESC_CB "android.hardware.bluetooth@1.0::IBluetoothHciCallbacks"
#define DESC_BASE "android.hidl.base@1.0::IBase"

// ============================================================ 全局
static volatile sig_atomic_t g_run = 1;
static int g_mfd = -1, g_sfd = -1;
static void* g_hci = nullptr;              // BpHwBluetoothHci*（HIDL 代理对象）
static void** g_hvptr = nullptr;           // 它的 vtable
static int g_slotInit = -1, g_slotSendCmd = -1, g_slotSendAcl = -1, g_slotSendSco = -1, g_slotClose = -1;

static void* g_cbObj = nullptr;            // 回调节点对象
static void** g_cbVptr = nullptr;          // 它的主 vtable（vendor .data.rel.ro 里那张）
static void* g_cbPage = nullptr;           // mprotect 的页基址
static size_t g_cbPageLen = 0;

static bool g_includeType = false;         // send* 时给 HAL 的 payload 带不带 H4 类型字节
static int g_cbTypeLatch = -1;             // 回调 payload 是否自带类型字节：-1 未知 0 不带 1 带
static long long g_w_timeout_ms = 1000;    // 一包写 pty：一个字节都还没写出去时最多等多久
static long long g_w_stuck_ms = 30000;     // 已经写了一半却卡这么久 ⇒ 判定桥不可用，主动退场
static int g_statusEvery = 10;             // 状态打印间隔（秒）
static bool g_fuse = true;                 // 框架熔断
static bool g_close = true;                // 退出时调 HAL close()
static bool g_kick = true;                 // 起来后 hciconfig hci0 up

// 计数
static volatile unsigned long long g_toHal = 0, g_toKernel = 0, g_cbAny = 0, g_cbEvents = 0;
static volatile unsigned long long g_cbInitSeen = 0;
static volatile int g_cbInitStatus = -1000;  // -1000 = 还没收到
static volatile unsigned long long g_qDrop = 0, g_wDrop = 0, g_wBytes = 0, g_wErr = 0;
static volatile unsigned long long g_frameBad = 0;

static void logmsg(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char* fmt, ...) {
    // 带时间戳：内核 hdev->setup 有超时，"哪一步花了多久"是排时序问题的唯一线索。
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    struct tm tm;
    time_t sec = ts.tv_sec;
    localtime_r(&sec, &tm);
    char tb[16];
    strftime(tb, sizeof(tb), "%H:%M:%S", &tm);
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[bthci %s.%03ld] ", tb, ts.tv_nsec / 1000000);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    fflush(stderr);
}

static long long now_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_term(int) { g_run = 0; }

// ============================================================ 回调 → 队列 → 写线程
struct Pkt {
    uint32_t len;
    uint8_t* data;  // 完整 H4 帧（含类型字节）
};
static std::deque<Pkt> g_q;
static std::mutex g_qm;
static std::condition_variable g_qcv;
static const size_t kQMax = 2048;

static void enqueueFrame(const uint8_t* frame, uint32_t n) {
    uint8_t* copy = (uint8_t*)malloc(n ? n : 1);
    if (!copy) return;
    memcpy(copy, frame, n);
    {
        std::lock_guard<std::mutex> lk(g_qm);
        while (g_q.size() >= kQMax) {  // 溢出丢**最老**的：宁可丢历史，不让 binder 线程阻塞
            Pkt old = g_q.front();
            g_q.pop_front();
            free(old.data);
            unsigned long long d = ++g_qDrop;
            if (d <= 5 || d % 100 == 0)
                logmsg("★ 队列溢出，丢弃最老的一包（累计 %llu）—— 说明内核侧收包速度跟不上 HAL",
                       (unsigned long long)d);
        }
        Pkt p{n, copy};
        g_q.push_back(p);
    }
    g_qcv.notify_one();
}

// 把一整帧写进 pty master。
// 铁律：**要么整包写完，要么一个字节都不写**。写到一半放弃会让内核 H4 解析器永久跑偏，
// 那正是我们要防的事故 —— 所以"写不进就丢"只在 off==0 时成立。
static void writeFrame(const uint8_t* buf, size_t n) {
    size_t off = 0;
    long long t0 = now_ms();
    long long stuckSince = 0;
    for (;;) {
        if (!g_run) return;
        ssize_t w = write(g_mfd, buf + off, n - off);
        if (w > 0) {
            off += (size_t)w;
            if (off == n) {
                ++g_toKernel;
                g_wBytes += n;
                return;
            }
            stuckSince = 0;
            continue;
        }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (off == 0 && now_ms() - t0 >= g_w_timeout_ms) {
                ++g_wDrop;
                logmsg("★ 一包 %zu 字节写不进 pty，且一个字节都没写出去 ⇒ 整包丢弃（累计 %llu）",
                       n, (unsigned long long)g_wDrop);
                return;
            }
            if (off > 0) {
                if (stuckSince == 0) stuckSince = now_ms();
                if (now_ms() - stuckSince > g_w_stuck_ms) {
                    logmsg("★ 已写 %zu/%zu 字节却卡住超过 %lldms ⇒ 判定桥不可用，主动退场"
                           "（绝不留下半包把内核 H4 解析器带偏）",
                           off, n, g_w_stuck_ms);
                    g_run = 0;
                    return;
                }
            }
            struct pollfd pf{g_mfd, POLLOUT, 0};
            poll(&pf, 1, (int)h4::poll_slice_ms(now_ms() - t0));
            continue;
        }
        if (w < 0 && errno == EINTR) continue;
        ++g_wErr;
        logmsg("★ 写 pty 失败: %s（off=%zu/%zu）", strerror(errno), off, n);
        return;
    }
}

static void* writerThread(void*) {
    for (;;) {
        Pkt p{0, nullptr};
        {
            std::unique_lock<std::mutex> lk(g_qm);
            g_qcv.wait(lk, [] { return !g_q.empty() || !g_run; });
            if (g_q.empty()) {
                if (!g_run) return nullptr;
                continue;
            }
            p = g_q.front();
            g_q.pop_front();
        }
        writeFrame(p.data, p.len);
        free(p.data);
    }
    return nullptr;
}

// 判定回调 payload 是否自带 H4 类型字节。
// 判据是"包内声明的长度是否等于实际长度"，**不是**首字节 ——
// 事件码 / ACL handle 低位与 0x01..0x05 的取值范围重叠，首字节启发式一定会读错。
// 判不出来就沿用已锁定值（默认"不带"，与 AOSP 参考实现一致）。
static bool cbHasTypeByte(uint8_t expect, const uint8_t* d, uint32_t n) {
    bool withType = false, without = false;
    switch (expect) {
        case H4_EVT:  // 不带: [code][len][...]      带: [04][code][len][...]
            if (n >= 2) without = (2u + (uint32_t)d[1] == n);
            if (n >= 3 && d[0] == H4_EVT) withType = (3u + (uint32_t)d[2] == n);
            break;
        case H4_ACL:  // 不带: [h][h][dl][dh][...]   带: [02][h][h][dl][dh][...]
            if (n >= 4) without = (4u + (uint32_t)(d[2] | (d[3] << 8)) == n);
            if (n >= 5 && d[0] == H4_ACL) withType = (5u + (uint32_t)(d[3] | (d[4] << 8)) == n);
            break;
        case H4_SCO:  // 不带: [h][h][len][...]      带: [03][h][h][len][...]
            if (n >= 3) without = (3u + (uint32_t)d[2] == n);
            if (n >= 4 && d[0] == H4_SCO) withType = (4u + (uint32_t)d[3] == n);
            break;
        default:
            return g_cbTypeLatch > 0;
    }
    if (withType && !without) {
        if (g_cbTypeLatch < 0) {
            g_cbTypeLatch = 1;
            logmsg("· 回调方向自动判定：payload **自带** H4 类型字节（长度自校验通过）");
        }
        return true;
    }
    if (without && !withType) {
        if (g_cbTypeLatch < 0) {
            g_cbTypeLatch = 0;
            logmsg("· 回调方向自动判定：payload **不带** H4 类型字节（与 AOSP 参考实现一致）");
        }
        return false;
    }
    return g_cbTypeLatch > 0;
}

// 把 HAL 回调里的一包 H4 帧入队（给写线程）。expect 由"是哪个回调"决定，不用猜。
static void onHalPacket(uint8_t expect, const void* vRaw) {
    ++g_cbAny;
    if (expect == H4_EVT) ++g_cbEvents;
    auto* v = (const hidl_vec<uint8_t>*)vRaw;
    if (!v || !v->mBuffer || v->mSize == 0) return;
    const uint8_t* d = v->mBuffer;
    uint32_t n = v->mSize;
    if (n > 4096) {
        logmsg("★ 回调包异常大（%u 字节），丢弃", n);
        return;
    }
    uint8_t frame[4097];
    uint32_t fl;
    if (cbHasTypeByte(expect, d, n)) {
        memcpy(frame, d, n);
        fl = n;
    } else {
        frame[0] = expect;
        memcpy(frame + 1, d, n);
        fl = n + 1;
    }
    enqueueFrame(frame, fl);
}

// ============================================================ vtable 槽实现
//
// ★ 必须返回 ReturnVoid（非平凡类型）—— 否则编译器不设 x8，参数错位一格。
static ReturnVoid okRet() {
    ReturnVoid r;
    memset(&r, 0, sizeof(r));
    r.raw[32] = 1;  // Return<void>::mCheckedStatus = true，避免平台 onIgnored() 自杀
    return r;
}

// 不加 extern "C"：这几个函数的地址只被塞进 vtable，名字怎么修饰无所谓；
// 加了反而会触发 -Wreturn-type-c-linkage（C 链接不允许返回 C++ 非平凡类型）。
ReturnVoid h_interfaceDescriptor(void* self, const void* cbRaw) {
    (void)self;
    auto* cb = (const std::function<void(const hidl_string&)>*)cbRaw;
    hidl_string s{DESC_CB, (uint32_t)(sizeof(DESC_CB) - 1), false, {0, 0, 0}};
    if (cb && *cb) (*cb)(s);
    return okRet();
}

ReturnVoid h_interfaceChain(void* self, const void* cbRaw) {
    (void)self;
    auto* cb = (const std::function<void(const hidl_vec<hidl_string>&)>*)cbRaw;
    static hidl_string chain[2] = {
        {DESC_CB, (uint32_t)(sizeof(DESC_CB) - 1), false, {0, 0, 0}},
        {DESC_BASE, (uint32_t)(sizeof(DESC_BASE) - 1), false, {0, 0, 0}},
    };
    hidl_vec<hidl_string> v{chain, 2, false, {0, 0, 0}};
    if (cb && *cb) (*cb)(v);
    return okRet();
}

ReturnVoid h_generic(void* self, ...) {
    (void)self;
    return okRet();
}

ReturnVoid h_initComplete(void* self, int32_t status) {
    (void)self;
    g_cbInitStatus = status;
    g_cbInitSeen = g_cbInitSeen + 1;
    logmsg("★ ← initializationComplete(status=%d %s)", status,
           status == 0 ? "SUCCESS" : (status == 1 ? "TRANSPORT_ERROR"
                                     : status == 2 ? "INITIALIZATION_ERROR" : "UNKNOWN"));
    return okRet();
}

ReturnVoid h_hciEvent(void* self, const void* v) {
    (void)self;
    onHalPacket(H4_EVT, v);
    return okRet();
}
ReturnVoid h_aclData(void* self, const void* v) {
    (void)self;
    onHalPacket(H4_ACL, v);
    return okRet();
}
ReturnVoid h_scoData(void* self, const void* v) {
    (void)self;
    onHalPacket(H4_SCO, v);
    return okRet();
}

// ============================================================ 内核侧：pty
// 只建 pty 对。挂 N_HCI 是 setLdiscH4()，**故意分开**：顺序错了 mgmt 就看不到设备。
static bool openPty() {
    int mfd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (mfd < 0) {
        logmsg("✗ open /dev/ptmx 失败: %s", strerror(errno));
        return false;
    }
    int n = 0;
    if (ioctl(mfd, TIOCGPTN, &n) < 0) {
        logmsg("✗ TIOCGPTN 失败: %s", strerror(errno));
        close(mfd);
        return false;
    }
    char sp[64];
    snprintf(sp, sizeof(sp), "/dev/pts/%d", n);
    int lk = 0;
    ioctl(mfd, TIOCSPTLCK, &lk);
    int sfd = open(sp, O_RDWR | O_NOCTTY);
    if (sfd < 0) {
        logmsg("✗ open %s 失败: %s", sp, strerror(errno));
        close(mfd);
        return false;
    }
    g_mfd = mfd;
    g_sfd = sfd;
    // master 设非阻塞：默认阻塞写会在 pty 缓冲满时把写线程堵住。
    // （写线程已经和 binder 回调线程解耦，但非阻塞 + 有界等待仍然更可控。）
    int fl = fcntl(mfd, F_GETFL, 0);
    if (fl >= 0) fcntl(mfd, F_SETFL, fl | O_NONBLOCK);
    logmsg("✓ pty 已建立：%s（**还没**挂 N_HCI —— 等 HAL 初始化完再挂，见 setLdiscH4）", sp);
    return true;
}

// ★ 挂 N_HCI + H4。**必须等 HAL 初始化完成之后再调**，这是实测踩出来的顺序要求：
//
//   内核一收到 HCIUARTSETPROTO 就 hci_register_dev() 并立刻跑它自己的初始化序列
//   （HCI_Reset / Read_Local_Version / Read_BD_ADDR / Set_Event_Mask ... 几十条命令），
//   而且 hdev->setup 是有**超时**的。如果这时候桥还没 initialize HAL、主循环还没在
//   poll pty，那几十条命令就堆在 pty 缓冲里没人转发 → 内核侧 setup 超时失败 →
//   `HCI_SETUP` 这个 dev_flag 清不掉 → 内核 mgmt 的索引表里**永远不会有这个设备**。
//
//   症状极具误导性：`hciconfig -a hci0` 一切正常（它自己另发 HCI 命令读版本/特性，
//   与内核 setup 无关），`/sys/class/bluetooth/hci0` 也在，但容器里的 BlueZ
//   （bluetoothctl / btmgmt）报 "No default controller available"，
//   `btmgmt info` 报 "Index list with 0 items" —— 因为 mgmt 的 read_index_list
//   会跳过 `test_bit(HCI_SETUP)` 的设备。
//
//   ⇒ 顺序固定为：openPty → initialize(HAL) → 起主循环 → setLdiscH4 → hci0 出现。
static bool setLdiscH4() {
    if (g_sfd < 0) {
        logmsg("✗ 还没建 pty");
        return false;
    }
    int disc = N_HCI;
    if (ioctl(g_sfd, TIOCSETD, &disc) < 0) {
        logmsg("✗ TIOCSETD N_HCI 失败: %s（需要 root）", strerror(errno));
        return false;
    }
    int proto = HCI_UART_H4;
    ioctl(g_sfd, HCIUARTSETPROTO, proto);
    ioctl(g_sfd, HCIUARTSETPROTO, proto);  // 本机 legacy hci_uart 第二次才 register（实测）
    int idx = -1;
    ioctl(g_sfd, HCIUARTGETDEVICE, &idx);
    logmsg("✓ N_HCI+H4 已挂上，hci0 正在注册（GETDEVICE=%d 不可信，判据看 /sys/class/bluetooth）",
           idx);
    return true;
}

// ============================================================ 回调节点构造
static bool buildCallbackNode(void* so) {
    typedef void (*BsCtorFn)(void* self, const void* spImpl);
    BsCtorFn ctor = (BsCtorFn)dlsym(so, SYM_BS_CTOR);
    if (!ctor) {
        logmsg("✗ 找不到 BsBluetoothHciCallbacks 构造器：%s", dlerror());
        return false;
    }
    uint8_t* mem = (uint8_t*)calloc(0x200, 1);
    if (!mem) return false;
    struct SpRaw {
        void* p;
    };
    SpRaw nullsp{nullptr};
    ctor(mem, &nullsp);

    void** vptr = *(void***)mem;
    g_cbObj = mem;
    g_cbVptr = vptr;
    logmsg("✓ 回调节点 @%p vptr=%p  mImpl(+0x60)=%p", (void*)mem, (void*)vptr,
           *(void**)(mem + 0x60));
    logmsg("  vptr[-4..-1]=%p %p %p %p  [3]=%p [13]=%p [14]=%p [15]=%p [16]=%p", vptr[-4], vptr[-3],
           vptr[-2], vptr[-1], vptr[3], vptr[13], vptr[14], vptr[15], vptr[16]);

    // ★ CFI：平台带 -fsanitize=cfi-vcall，虚调用前会校验 vptr 是否落在本类 vtable 区间。
    //   把 vptr 换成我们二进制里的表必然被判失败，所以**就地改 vendor 那张表**。
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    void* base = (void*)((uintptr_t)vptr & ~(uintptr_t)(pg - 1));
    size_t len = (size_t)pg * 2;
    if (mprotect(base, len, PROT_READ | PROT_WRITE) != 0) {
        logmsg("✗ mprotect(%p) 失败: %s —— CFI 会拒绝自建 vtable，无法继续", base, strerror(errno));
        return false;
    }
    g_cbPage = base;
    g_cbPageLen = len;
    for (int i = 1; i <= 12; i++) vptr[i] = (void*)h_generic;
    vptr[1] = (void*)h_interfaceChain;
    vptr[3] = (void*)h_interfaceDescriptor;
    vptr[13] = (void*)h_initComplete;
    vptr[14] = (void*)h_hciEvent;
    vptr[15] = (void*)h_aclData;
    vptr[16] = (void*)h_scoData;
    *(void**)(mem + 0x60) = mem;  // mImpl = self：Bs 的转发全部回到自己 vtable
    logmsg("✓ vtable 已就地打补丁（页 %p 临时 RW），mImpl 自指", base);
    return true;
}

static void restoreVtableProt(void) {
    if (g_cbPage) {
        if (mprotect(g_cbPage, g_cbPageLen, PROT_READ) != 0)
            logmsg("· 恢复 vtable 页只读失败: %s（不影响正确性，但会留一张可写的 .data.rel.ro）",
                   strerror(errno));
        else
            logmsg("· vtable 页已恢复 PROT_READ");
    }
}

// ============================================================ HAL 调用
static void sendToHal(uint8_t h4type, const uint8_t* body, size_t blen) {
    int slot = h4type == H4_CMD ? g_slotSendCmd
               : h4type == H4_ACL ? g_slotSendAcl
               : h4type == H4_SCO ? g_slotSendSco
                                  : -1;
    if (slot < 0) {
        logmsg("· 忽略 H4 类型 0x%02x（HIDL 1.0 没有对应方法；ISO 走 1.1）", h4type);
        return;
    }
    hidl_vec<uint8_t> v;
    if (g_includeType) {
        v.mBuffer = (uint8_t*)body - 1;
        v.mSize = (uint32_t)(blen + 1);
    } else {
        v.mBuffer = (uint8_t*)body;
        v.mSize = (uint32_t)blen;
    }
    v.mOwnsBuffer = false;
    memset(v.mPad, 0, sizeof(v.mPad));
    ++g_toHal;
    typedef ReturnVoid (*SendFn)(void* self, const hidl_vec<uint8_t>* p);
    SendFn f = (SendFn)g_hvptr[slot];
    ReturnVoid rv = f(g_hci, &v);
    if (rv.exceptionCode() != 0)
        logmsg("★ → HAL 0x%02x 事务失败 exceptionCode=%d", h4type, rv.exceptionCode());
}

// pty master → HAL：按 H4 切帧后逐包转发
static void pumpToHal() {
    static std::vector<uint8_t> acc;
    uint8_t tmp[4096];
    ssize_t got = read(g_mfd, tmp, sizeof(tmp));
    if (got <= 0) return;
    acc.insert(acc.end(), tmp, tmp + got);
    size_t pos = 0;
    while (pos < acc.size()) {
        size_t need = h4::frame_len(acc.data() + pos, acc.size() - pos);
        if (need == (size_t)-1) {
            ++g_frameBad;
            logmsg("★ 未知 H4 类型 0x%02x，丢 1 字节（累计 %llu）", acc[pos],
                   (unsigned long long)g_frameBad);
            ++pos;
            continue;
        }
        if (need == 0) break;  // 头不全 / ISO：等更多字节
        if (pos + need > acc.size()) break;
        uint8_t t = acc[pos];
        sendToHal(t, acc.data() + pos + 1, need - 1);
        pos += need;
    }
    if (pos) acc.erase(acc.begin(), acc.begin() + (long)pos);
}

// ============================================================ 环境判据
static bool readFileInt(const char* path, int* out) {
    FILE* f = fopen(path, "r");
    if (!f) return false;
    int v = 0;
    bool ok = (fscanf(f, "%d", &v) == 1);
    fclose(f);
    if (ok) *out = v;
    return ok;
}

static int rfSoft() {
    int v = -1;
    if (!readFileInt("/sys/class/rfkill/rfkill0/soft", &v)) return -2;
    return v;
}

// 自熔断判据：安卓框架活着 = 它的蓝牙栈和**我们**同时持有 IBluetoothHci 客户端位，
// 两颗客户端抢同一颗 WiFi+BT combo 芯片的电源协调（btpower/cnss）。
// 历史实测：连着两轮把安卓 WiFi 打进 `is_driver_recovering 1 / Driver Loading Timed-out!!`
// 死循环，停桥也解不开，只能整机重启。⇒ 绝不允许"安卓活着 + 桥也活着"。
// 读不到属性时不自杀（判据不确定就别动手）。
static bool frameworkAlive() {
    FILE* f = popen("getprop init.svc.surfaceflinger 2>/dev/null", "r");
    if (!f) return false;
    char buf[32] = {};
    bool got = (fgets(buf, sizeof(buf), f) != nullptr);
    pclose(f);
    return got && strncmp(buf, "running", 7) == 0;
}

// 按 /proc/*/comm 精确找 pid（不用 pgrep/pkill：正则匹配会误伤无关进程）。
// 注意 /proc/PID/comm 最长 15 字符（内核硬限制），长进程名会被截断 ——
// 所以既接受完全相等，也接受"comm 是 want 的前 15 字符"（前缀匹配）。
static int pidByComm(const char* want) {
    size_t wl = strlen(want);
    if (wl > 15) wl = 15;
    for (int p = 1; p < 100000; p++) {
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/comm", p);
        FILE* f = fopen(path, "r");
        if (!f) continue;
        char buf[64] = {};
        bool ok = (fgets(buf, sizeof(buf), f) != nullptr);
        fclose(f);
        if (!ok) continue;
        size_t n = strlen(buf);
        while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
        if (n == strlen(want) && !strcmp(buf, want)) return p;
        if (n == wl && !strncmp(buf, want, wl)) return p;
    }
    return -1;
}

// hciconfig hci0 up：实测"自己开 AF_BLUETOOTH socket 打 HCIDEVUP"会 ENODEV，
// 而 nsenter 进容器 ns 跑 hciconfig 成功过。它会阻塞等 init-complete，所以放后台。
static void kickHci(int up) {
    int pid = pidByComm("bluetoothd");
    if (pid <= 0) {
        logmsg("· 容器里没找到 bluetoothd，跳过 hciconfig hci0 %s", up ? "up" : "down");
        return;
    }
    char cmd[320];
    snprintf(cmd, sizeof(cmd),
             "nsenter -t %d -m -p -- /usr/bin/hciconfig hci0 %s >/dev/null 2>&1 %s", pid,
             up ? "up" : "down", up ? "&" : "");
    int rc = system(cmd);
    logmsg("· hciconfig hci0 %s（经 bluetoothd pid=%d 的 ns）rc=%d", up ? "up" : "down", pid, rc);
}

// HAL 自己很啰嗦，它抱怨的那一行往往就是答案（固件下载失败/IBS 超时/权限）。
// 安卓 framework 死了 logd 照样在（class core），所以接管期也能读。
static void dumpHalLog(int n) {
    char cmd[224];
    snprintf(cmd, sizeof(cmd),
             "logcat -d -t %d 2>/dev/null | grep -iE 'bluetooth|btpower|ibs_|vendor.qti|bt_vendor|"
             "hal_bluetooth' | tail -18",
             n);
    FILE* g = popen(cmd, "r");
    if (!g) return;
    char ln[512];
    while (fgets(ln, sizeof(ln), g)) {
        size_t e = strlen(ln);
        while (e && (ln[e - 1] == '\n' || ln[e - 1] == '\r')) ln[--e] = 0;
        fprintf(stderr, "[bthci]  HAL| %s\n", ln);
    }
    pclose(g);
}

static int findSlot(void** vptr, void* fn, int maxSlots) {
    if (!fn) return -1;
    for (int i = 0; i < maxSlots; i++)
        if (vptr[i] == fn) return i;
    return -1;
}

static void* joinThread(void*) {
    typedef void (*JoinFn)();
    JoinFn j = (JoinFn)dlsym(RTLD_DEFAULT, SYM_JOIN_POOL);
    if (j) j();
    return nullptr;
}

// ============================================================ main
static void usage(const char* a0) {
    fprintf(stderr,
            "用法: %s [选项]\n"
            "  默认：注册 hci0 + initialize + 双向搬运（--keep 秒后退出）\n"
            "  --keep <秒>          运行时长，0=不限（默认 3600）\n"
            "  --no-kick            不调 hciconfig hci0 up\n"
            "  --no-close           退出时不调 HAL close()（让 binder 死亡通知回收）\n"
            "  --no-fuse            关闭框架熔断（**危险**，只用于调试）\n"
            "  --send-with-type     send* 给 HAL 的 payload 带 H4 类型字节（默认不带，见文件头依据）\n"
            "  --cb-with-type       强制认为回调 payload 自带类型字节（默认长度自校验自动判定）\n"
            "  --w-timeout <ms>     一包写 pty：一个字节都没写出去时最多等多久（默认 1000）\n"
            "  --status-every <秒>  状态打印间隔（默认 10）\n"
            "  --codes              只打印槽位表和环境判据后退出\n",
            a0);
}

int main(int argc, char** argv) {
    int keep = 3600;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--keep") && i + 1 < argc)
            keep = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-kick"))
            g_kick = false;
        else if (!strcmp(argv[i], "--no-close"))
            g_close = false;
        else if (!strcmp(argv[i], "--no-fuse"))
            g_fuse = false;
        else if (!strcmp(argv[i], "--send-with-type"))
            g_includeType = true;
        else if (!strcmp(argv[i], "--cb-with-type"))
            g_cbTypeLatch = 1;
        else if (!strcmp(argv[i], "--w-timeout") && i + 1 < argc)
            g_w_timeout_ms = atoll(argv[++i]);
        else if (!strcmp(argv[i], "--status-every") && i + 1 < argc)
            g_statusEvery = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--codes")) {
            printf("BpHwBluetoothHci vtable: initialize=13 sendHciCommand=14 sendAclData=15 "
                   "sendScoData=16 close=17\n");
            printf("回调 vtable: 0=isRemote 1=interfaceChain 2=debug 3=interfaceDescriptor "
                   "4=getHashChain 5=setHALInstrumentation 6=linkToDeath 7=ping 8=getDebugInfo "
                   "9=notifySyspropsChanged 10=unlinkToDeath 11=getInterfaceVersion "
                   "12=getInterfaceHash 13=initializationComplete 14=hciEventReceived "
                   "15=aclDataReceived 16=scoDataReceived\n");
            printf("HAL pid=%d rfkill0.soft=%d\n", pidByComm("android.hardware.bluetooth@1.1-service-qti"),
                   rfSoft());
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    signal(SIGINT, on_term);
    signal(SIGTERM, on_term);
    signal(SIGPIPE, SIG_IGN);

    logmsg("== bthci-bridge (HIDL 客户端) 启动 ==");
    logmsg("sizeof(std::function)=%zu sizeof(std::string)=%zu sizeof(ReturnVoid)=%zu",
           sizeof(std::function<void(const hidl_string&)>), sizeof(std::string), sizeof(ReturnVoid));

    // ---- dlopen：先把 libhidlbase 等以 RTLD_GLOBAL 拉进来，再拉 vendor HAL ----
    const char* pre[] = {"/system/lib64/libhidlbase.so", "/system/lib64/libutils.so",
                         "/system/lib64/libcutils.so",   "/system/lib64/libbase.so",
                         "/system/lib64/liblog.so",      "/system/lib64/libc++.so"};
    for (size_t i = 0; i < sizeof(pre) / sizeof(pre[0]); i++) {
        if (!dlopen(pre[i], RTLD_NOW | RTLD_GLOBAL)) logmsg("· dlopen %s: %s", pre[i], dlerror());
    }
    void* so = dlopen(SO_HCI10, RTLD_NOW | RTLD_GLOBAL);
    if (!so) {
        logmsg("✗ dlopen %s 失败: %s", SO_HCI10, dlerror());
        return 1;
    }
    logmsg("✓ dlopen %s", SO_HCI10);

    // ---- binder 线程池（必须在任何 binder 交互之前）----
    typedef void (*CfgFn)(size_t, bool);
    CfgFn cfg = (CfgFn)dlsym(RTLD_DEFAULT, SYM_CFG_POOL);
    if (cfg) cfg(4, false);
    for (int i = 0; i < 2; i++) {
        pthread_t t;
        if (pthread_create(&t, nullptr, joinThread, nullptr) == 0)
            pthread_detach(t);
    }
    usleep(150000);

    // ---- getService ----
    typedef android::sp<void> (*GetServiceFn)(const std::string& name, bool getStub);
    GetServiceFn gs = (GetServiceFn)dlsym(so, SYM_GETSERVICE);
    if (!gs) {
        logmsg("✗ 找不到 IBluetoothHci::getService：%s", dlerror());
        return 1;
    }
    std::string inst = "default";
    android::sp<void> handle = gs(inst, false);
    g_hci = handle.m_ptr;
    if (!g_hci) {
        logmsg("✗ getService(\"default\") 返回空 —— HAL 活着吗？（lshal | grep bluetooth）");
        return 1;
    }
    g_hvptr = *(void***)g_hci;
    logmsg("✓ 拿到 android.hardware.bluetooth@1.0::IBluetoothHci/default @%p", g_hci);

    // 槽位定位：优先用 dlsym 拿真实函数地址在 vtable 里搜（符号名已用 llvm-readelf 核对过）。
    // dlsym 万一失败（厂商换 .so 布局 / 符号被裁）就退回**探针实测**的固定槽位 ——
    // 两条路互相印证，任一条走通都能跑。
    g_slotInit = findSlot(g_hvptr, dlsym(so, SYM_BP(S_INIT)), 80);
    g_slotSendCmd = findSlot(g_hvptr, dlsym(so, SYM_BP(S_SENDCMD)), 80);
    g_slotSendAcl = findSlot(g_hvptr, dlsym(so, SYM_BP(S_SENDACL)), 80);
    g_slotSendSco = findSlot(g_hvptr, dlsym(so, SYM_BP(S_SENDSCO)), 80);
    g_slotClose = findSlot(g_hvptr, dlsym(so, SYM_BP(S_CLOSE)), 80);
    logmsg("  槽位(dlsym) initialize=%d sendHciCommand=%d sendAclData=%d sendScoData=%d close=%d",
           g_slotInit, g_slotSendCmd, g_slotSendAcl, g_slotSendSco, g_slotClose);
    if (g_slotInit < 0 || g_slotSendCmd < 0 || g_slotSendAcl < 0 || g_slotSendSco < 0) {
        logmsg("· dlsym 定位不全，退回探针实测的固定槽位"
               "（initialize=13 cmd=14 acl=15 sco=16 close=17）");
        g_slotInit = 13;
        g_slotSendCmd = 14;
        g_slotSendAcl = 15;
        g_slotSendSco = 16;
        g_slotClose = 17;
    }
    if (g_slotClose < 0) g_slotClose = 17;
    {
        const int slots[5] = {g_slotInit, g_slotSendCmd, g_slotSendAcl, g_slotSendSco, g_slotClose};
        for (int i = 0; i < 5; i++) {
            if (slots[i] < 0 || slots[i] > 200 || g_hvptr[slots[i]] == nullptr) {
                logmsg("✗ 槽位 %d 不可用（vtable 布局与预期不符），拒绝继续", slots[i]);
                return 1;
            }
        }
    }

    // ---- ① 先建 pty（**不**挂 N_HCI）----
    if (!openPty()) return 1;

    // ---- ② 回调节点 ----
    if (!buildCallbackNode(so)) {
        restoreVtableProt();
        return 1;
    }

    // ---- ③ 写线程（HAL 回调 → 队列 → pty）----
    pthread_t wt;
    if (pthread_create(&wt, nullptr, writerThread, nullptr) != 0) {
        logmsg("✗ 写线程创建失败");
        restoreVtableProt();
        return 1;
    }
    pthread_detach(wt);

    // ---- ④ initialize(callbacks)：HAL 上电 + 固件下载全在这一步里 ----
    {
        struct SpRaw {
            void* p;
        };
        SpRaw cb{g_cbObj};
        typedef ReturnVoid (*InitFn)(void* self, const void* spCallbacks);
        InitFn init = (InitFn)g_hvptr[g_slotInit];
        logmsg("→ initialize(callbacks=@%p) ...", g_cbObj);
        ReturnVoid rv = init(g_hci, &cb);
        logmsg("  initialize 返回 exceptionCode=%d", rv.exceptionCode());
        if (rv.exceptionCode() != 0) {
            logmsg("✗ initialize 事务失败 —— 回调节点没被接受");
            restoreVtableProt();
            return 1;
        }
        int waited = 0;
        while (g_run && g_cbInitSeen == 0 && waited < 24) {
            usleep(500000);
            waited++;
        }
        if (g_cbInitSeen == 0) {
            logmsg("✗ HAL 一个回调都没发 → 客户端位没坐上（查回调 binder 的送达/稳定性）");
            dumpHalLog(120);
            restoreVtableProt();
            return 1;
        }
        if (g_cbInitStatus != 0) {
            logmsg("★ status=%d（非 0）→ HAL 自己怎么说的：", g_cbInitStatus);
            dumpHalLog(120);
            // 继续跑：有些 vendor 会先报错再补一次成功；但把状态记在日志里。
        }
    }

    // ---- ⑤ 现在才挂 N_HCI：hci0 一出现，内核的初始化序列就有人转发了 ----
    if (!setLdiscH4()) {
        restoreVtableProt();
        return 1;
    }

    if (g_kick) kickHci(1);

    // ---- 主循环 ----
    {
        long long until = keep > 0 ? now_ms() + (long long)keep * 1000 : 0;
        int tick = 0;
        while (g_run) {
            if (until && now_ms() >= until) break;
            struct pollfd pf{g_mfd, POLLIN, 0};
            int s = poll(&pf, 1, 1000);
            if (s > 0 && (pf.revents & POLLIN)) pumpToHal();
            if (s < 0 && errno != EINTR) break;
            if (++tick % (g_statusEvery > 0 ? g_statusEvery : 10) == 0) {
                if (g_fuse && frameworkAlive()) {
                    logmsg("★ 熔断：安卓框架已活着（surfaceflinger=running）⇒ 立刻退场，"
                           "把 HAL 客户端位和 hci0 还给安卓（桥与安卓蓝牙栈不能同时存在）");
                    break;
                }
                // 注意：桥跑在安卓侧，这里**没有** /sys/class/bluetooth/hci0（那是容器侧的视图），
                // 恒打 NO-SYSFS-ON-ANDROID 是正常的，不代表设备没了。
                char fl[64] = "?";
                FILE* g = popen("cat /sys/class/bluetooth/hci0/flags 2>/dev/null || echo NO-SYSFS-ON-ANDROID", "r");
                if (g) {
                    if (!fgets(fl, sizeof(fl), g)) snprintf(fl, sizeof(fl), "ERR");
                    pclose(g);
                }
                size_t e = strlen(fl);
                while (e && (fl[e - 1] == '\n' || fl[e - 1] == '\r')) fl[--e] = 0;
                logmsg("状态 hci0.sysfs=%s 转发=%llu 收回=%llu 回调=%llu event=%llu "
                       "队列=%zu 队列丢=%llu 写pty丢=%llu 写错=%llu 字节=%llu 坏帧=%llu "
                       "cb带类型=%s rfkill0.soft=%d",
                       fl, (unsigned long long)g_toHal, (unsigned long long)g_toKernel,
                       (unsigned long long)g_cbAny, (unsigned long long)g_cbEvents, g_q.size(),
                       (unsigned long long)g_qDrop, (unsigned long long)g_wDrop,
                       (unsigned long long)g_wErr, (unsigned long long)g_wBytes,
                       (unsigned long long)g_frameBad,
                       g_cbTypeLatch < 0 ? "未判定" : (g_cbTypeLatch ? "是" : "否"), rfSoft());
            }
        }
    }

    // ---- 退场 ----
    logmsg("== 退场 ==");
    if (g_close && g_slotClose >= 0) {
        typedef ReturnVoid (*CloseFn)(void* self);
        ReturnVoid cr = ((CloseFn)g_hvptr[g_slotClose])(g_hci);
        logmsg("  HAL close() 返回 exceptionCode=%d", cr.exceptionCode());
    } else {
        logmsg("  不调 close()：进程一退 binder 死亡通知会让 HAL 自己回收这个客户端");
    }
    restoreVtableProt();
    if (g_sfd >= 0) {
        int back = N_TTY;
        ioctl(g_sfd, TIOCSETD, &back);
        close(g_sfd);
    }
    if (g_mfd >= 0) close(g_mfd);
    logmsg("  已恢复 N_TTY 并关闭 pty ⇒ 内核自动 hci_unregister_dev（hci0 消失）");
    return 0;
}

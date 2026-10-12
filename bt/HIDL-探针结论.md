# 蓝牙桥 HIDL 移植 — 第 0 步探针结论（实测）

设备：Lenovo TB710FU（移植 ColorOS 后 `ro.product.model` 报成 OPPO Pad OPD2511，
`ro.board.platform=pineapple`）/ adb `HA2HZAW2` / Android 17 SDK37 / arm64 / KernelSU root / SELinux Enforcing
HAL：`android.hardware.bluetooth@1.1-service-qti`（PID 1935），注册在 **hwservicemanager**（`/dev/hwbinder`）
探针：`probe/bt/btprobe.cpp`（步骤 0a）、`probe/bt/btprobe2.cpp`（步骤 0b）
构建：WSL + NDK r27c，`probe/bt/build-probe.sh`

---

## 0a. 能连上 HAL（已实测）

```
>>> getService("default") -> IBluetoothHci* = 0xb4000074034572a0  *** 连上了 ***
obj vptr=0x737f3f71e0  _ZTV(1.0)=0x737f3f71c8  delta=24
  ping                   fn=...  slot=7   vptr+0x38
  interfaceChain         fn=...  slot=1   vptr+0x08
  interfaceDescriptor    fn=...  slot=3   vptr+0x18
  getHashChain           fn=...  slot=4
  initialize             fn=...  slot=13  vptr+0x68
  sendHciCommand         fn=...  slot=14
  sendAclData            fn=...  slot=15
  sendScoData            fn=...  slot=16
  close                  fn=...  slot=17  vptr+0x88
>>> ping() -> exceptionCode=0  *** HIDL 往返成功 ***
>>> interfaceDescriptor() -> exc=0 desc="android.hardware.bluetooth@1.1::IBluetoothHci"
```

关键：`dlopen("/vendor/lib64/android.hardware.bluetooth@1.0.so")` 从 `/data/local/tmp` 直接可用；
HIDL 的 `sp<T>` / `Return<void>` 都是非平凡返回类型，函数指针必须声明成真实返回类型，否则 x8 不会设 → 段错误。

## 0b. 回调节点 + `initialize()` 成功（已实测）

`btprobe2.cpp` 用 **vendor .so 自己导出的 `BsBluetoothHciCallbacks` 构造器** 造出一个布局完全正确的
`IBluetoothHciCallbacks` 对象，再把它的 vtable 打补丁，然后调 `initialize()`：

```
BsBluetoothHciCallbacks::C1 = 0x7451faa268
回调对象 @0xb4000074d244a200  vptr=0x7451fb4780
  vptr[-4..-1] = 0x0 0x78 0x0 0x0      ← vbase offset: RefBase@+0x78, IInterface@0, IBase@0
  vptr[0]  isRemote              = ...  (mov w0,wzr; ret → false)
  vptr[1]  interfaceChain        = ...
  vptr[3]  interfaceDescriptor   = ...
  vptr[13] initializationComplete= ...
  vptr[14] hciEventReceived      = ...
  vptr[15] aclDataReceived       = ...
  vptr[16] scoDataReceived       = ...
  mImpl @+0x60 = 0x0
>>> 调用 initialize(callbacks=@0xb4000074d244a200) ...
  <<< [h] interfaceDescriptor() self=0xb4000074d244a200 cbRaw=0x7fee36c2e0
       wrapper 已回填 descriptor
>>> initialize 返回 exceptionCode=0 (HIDL 事务 OK)
>>> 等待回调 6 秒 ...
  <<< *** initializationComplete(status=0) ***
>>> 调用 close() slot=17 ...
>>> close() 返回 exceptionCode=0
== done ==
```

**`initializationComplete(status=0)` = SUCCESS。芯片真的被初始化了。**

`close()` 之后设备状态（实测）：
```
/sys/class/bluetooth/            → 空
rfkill0 bt_power state=1 soft=0 hard=0   （与 rfkill1 wlan 同状态，基线一致）
/proc/tty/ldiscs                 → n_hci 15
surfaceflinger                   → stopped
```

---

## 三条硬结论（后面写桥必须遵守）

### 1. `BsBluetoothHciCallbacks` 构造器是造回调节点的正确入口
符号：`_ZN7android8hardware9bluetooth4V1_023BsBluetoothHciCallbacksC1ENS_2spINS2_22IBluetoothHciCallbacksEEE`
（1.1 版：`...V1_123BsBluetoothHciCallbacksC1...`）
ABI：`void ctor(void* self, const sp<IBluetoothHciCallbacks>* impl)` —— `sp` 按值传 → 不可见引用。
传 null 也可以；构造后对象布局：
```
+0x00  主 vptr
+0x08  HidlInstrumentor 子对象（自带 vptr）
+0x60  sp<IBluetoothHciCallbacks> mImpl
+0x68  TaskRunner
+0x78  RefBase（真实 RefBase::RefBase() 已调用，mRefs 已分配）
```
`Bs` 的**每个**方法都是 `ldr x21,[x21,#0x60]` 然后转发给 `mImpl`。
所以 **把 `mImpl` 指向自己（self-reference）**，所有转发就回到自己 vtable 上，只要补丁主 vtable 即可。

### 2. vtable 槽位（实测，两个方向都验证过）
```
index 0      isRemote()                 （0x13678: mov w0,wzr;ret → false）
index 1      interfaceChain
index 2      debug
index 3      interfaceDescriptor
index 4      getHashChain
index 5      setHALInstrumentation
index 6      linkToDeath
index 7      ping
index 8      getDebugInfo
index 9      notifySyspropsChanged
index 10     unlinkToDeath
index 11     getInterfaceVersion
index 12     getInterfaceHash
index 13     initializationComplete
index 14     hciEventReceived
index 15     aclDataReceived
index 16     scoDataReceived
```
（`BpHwBluetoothHci` 代理侧同样：initialize=13, sendHciCommand=14, sendAclData=15, sendScoData=16, close=17）

### 3. 两个必须踩对的坑
**坑 A — CFI。** 平台带 `-fsanitize=cfi-vcall`：虚调用前有 vtable 范围校验
（`sub/ror #5/cmp #0x92/b.hi __cfi_slowpath`，锚点 `_ZTV...BpHwBluetoothHciCallbacksE` 的地址点）。
把 vptr 换成**我们自己二进制里的表**会被判失败。正确做法：`mprotect` vendor `.data.rel.ro`
对应页为 RW，**就地改 vendor 那张表**，vptr 保持原值。

**坑 B — handler 返回类型。** 回调 handler 必须声明成返回非平凡类型（如 `ReturnVoid`），
否则编译器不会用 x8 传 sret，参数整体错位一格（`self` 收到 x1、`cbRaw` 收到 x2 垃圾）→ 段错误。
同时 sret 要填 `{exception=0, errorCode=0, message="", mCheckedStatus=1}`（offset 32 置 1），
否则平台的 `Return::onIgnored()` 可能 fatal。

### 4. 回调线程池
回调是**同步**的（非 oneway），必须有 binder 线程收事务：
`configureRpcThreadpool(4,false)` + 若干 `joinRpcThreadpool()` 线程。
否则 HAL 调 `initializationComplete` 会永远卡住。

---

## 反推用到的分析脚本（都在 `probe/bt/`）
`dumpv.py`（带重定位解析的 vaddr 转储）、`range.sh`（llvm-objdump 地址区间）、
`dis-bs.sh`、`mystery.sh`、`dumpvt2.sh`、`sym-bs.sh`、`pool.sh`、`read-support.sh`、`read-cached.sh`

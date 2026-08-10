# 重启功能修复日记

## 核心踩坑：RB_AUTOBOOT 的正确值

- macOS SDK `<sys/reboot.h>`: `#define RB_AUTOBOOT 0x400`
- iOS/XNU kernel: `#define RB_AUTOBOOT 0`
- **之前所有方案都用了 `0x400`，导致 reboot() 行为等价于 shutdown（关机不重启）**
- DevelopCubeLab/RebootTools 使用 `reboot(0)` — 这才是正确值

## iOS 设备重启的前提条件

在 iOS 上触发全设备重启，有两种方式：
1. `reboot(RB_AUTOBOOT)` syscall — XNU 中 `RB_AUTOBOOT = 0`，需要 root
2. `FBSSystemService.shutdown` — 需要 **com.apple.frontboard.shutdown** entitlement（无需 root）

## 方案 1：bin/reboot（原方案）— ❌ 失败

**方法**：使用项目自带 `bin/reboot`（链接了 libjailbreak.dylib 的预编译二进制）

**表现**：`reboot 失败，错误码：1`

**根因**：`bin/reboot` 依赖 `@rpath/libjailbreak.dylib`，非越狱环境下该库不存在，dyld 加载阶段失败。

## 方案 2：launchctl reboot — ❌ 失败

**方法**：通过 persona-mgmt 的 spawnAndWait 执行 `bin/launchctl reboot`

**表现**：`reboot 失败，错误码：154`

**根因**：iOS 上 `launchctl reboot` 需要 userspace 参数，但 `launchctl reboot userspace` 只是用户空间重启（respring），不是真正的设备重启。不带参数的 reboot 返回错误码 154（不支持）。

## 方案 3：reboot_helper.c 编译的裸 C 二进制 — ❌ 无反应

**方法**：编译最小 C 二进制直接调用 `reboot(RB_AUTOBOOT)`，通过 persona-mgmt 以 root spawn

**表现**：日志显示"正在执行：重启...."后无任何反应，设备不重启，无错误信息

**根因**：裸 C 二进制无 entitlements。persona-mgmt 只能让子进程以 root 运行，但无法注入 entitlements。子进程缺少 `com.apple.system.reboot` 权限，MAC 策略静默拒绝。

编译问题：`<sys/reboot.h>` 在 iOS SDK 中不存在，需 `extern int reboot(int)` + `#define RB_AUTOBOOT 0x400` 手动声明。

## 方案 4：自产卵（spawn 主二进制 + --reboot 标志）— ❌ 无反应

**方法**：spawn 主二进制自身，传入 `--reboot` 参数，在 main.swift 拦截后调用 `reboot()`

**表现**：无反应，无错误

**根因**：虽然主二进制有 `com.apple.system.reboot` entitlement，但该 entitlement 在 TrollStore 环境下可能不被内核认可（需要苹果平台签名而非 ldid 伪签名）。

## 方案 5：FBSSystemService.shutdown + com.apple.frontboard.shutdown — ⚠️ 执行了关机而非重启

**方法**：逆向分析 TrollAutoScript（壳），发现其使用 `FBSSystemService` + `com.apple.frontboard.shutdown`。

使用了 `perform(NSSelectorFromString("shutdown"))`。

**表现**：设备关机（power off），而非重启。用户反馈"这是关机，不是重启"。

**根因**：`FBSSystemService` 有两个方法：
- `-[FBSSystemService shutdown]` — 关机
- `-[FBSSystemService reboot]` — 重启

壳中这两个被注册为独立命令（`shutdown` 和 `reboot`），各自调用不同的 selector。之前错误地用了 `shutdown` selector。

## 方案 6：FBSSystemService.reboot + com.apple.frontboard.shutdown — ⚠️ 仍是关机，未重启

**方法**：将 selector 从 `"shutdown"` 改为 `"reboot"`。

```swift
svc.perform(NSSelectorFromString("reboot"))
```

**表现**：设备关机（power off），没有自动重启。用户反馈"还是关机，没有自动重启"。

**根因**：不确定。可能是该 iOS 版本上 `FBSSystemService.reboot` 行为等同于 `shutdown`，或者是
FrontBoard 的 XPC 通信在 reboot 模式下存在 bug。壳可能依赖其他机制（如 `rebackboardd` 命令）实现重启。

**逆向深入分析**：
- `bin/reboot` 依赖 `libjailbreak.dylib`（`jb_oneshot_entitle_now`），jailbreak-only
- 壳的命令注册列表：`rebackboardd.reboot.shutdown.refreshUicache` — 四个独立命令
- `rebootView` 和 `shutdownView` 是独立的 SwiftUI 视图
- FBSSystemService 在壳中被两处引用（`_OBJC_CLASS_$_FBSSystemService`）
- `sharedService` selector 旁就是命令处理逻辑
- `com.apple.frontboard.shutdown` 权限同时覆盖 shutdown 和 reboot 两个操作

## 方案 7：reboot_helper + reboot(0) + persona root（当前方案）— ❌ 已确认：仍是关机

**方法**：参照 DevelopCubeLab/RebootTools 的完整实现：
1. 编译 `reboot_helper.c` 调用 `reboot(0)`（RB_AUTOBOOT = 0，不是 0x400！）
2. 通过 persona-mgmt 以 root 身份 spawn 该 helper
3. 降级方案：helper 失败时尝试 `FBSSystemService.shutdown`

**验证结果**：在 TrollStore 环境下，所有重启方案（1-7）最终行为均为关机，无法触发真正的设备重启。已将 UI 按钮和日志统一改为"关机"。

```c
// reboot_helper.c
int main() {
    sync();
    reboot(0);   // RB_AUTOBOOT = 0 in XNU
    return 1;
}
```

```swift
// ViewController.swift
private func shutdownDevice() {
    let helperBin = binPath("reboot_helper")
    let result = spawnAndWait(path: helperBin, args: ["reboot_helper"])
    if result == 0 { return }
    // 降级: FBSSystemService.reboot
    ...
}
```

**为什么这次应该能工作**：
- RebootTools 是已验证的 TrollStore 重启方案，使用完全相同的 `reboot(0)` + root helper 模式
- 核心差异：`reboot(0)` vs `reboot(0x400)` — macOS SDK 头文件中 `RB_AUTOBOOT = 0x400`，但 XNU 内核中 `RB_AUTOBOOT = 0`
- 之前方案 3 的 `reboot_helper.c` 用了 `0x400`，这才是导致无声关机而非重启的根本原因

### 当前改动
| 文件 | 改动 |
|------|------|
| `reboot_helper.c` | 重建，`reboot(0)` 替代 `reboot(0x400)` |
| `ViewController.swift` | `shutdownDevice()` 优先 spawn helper，失败降级 FBSSystemService.shutdown |
| `build.sh` | 恢复 reboot_helper 编译步骤 |
| `.github/workflows/build.yml` | 恢复 reboot_helper 编译步骤 |
| `TrollServer.entitlements` | 保持 `com.apple.frontboard.shutdown` |

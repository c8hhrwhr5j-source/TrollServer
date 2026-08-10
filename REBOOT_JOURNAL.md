# 重启功能修复日记

## iOS 设备重启的前提条件

在 iOS 上触发全设备重启，有两种方式：
1. `reboot(RB_AUTOBOOT)` syscall — 需要 **com.apple.system.reboot** entitlement + root
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

## 方案 6：FBSSystemService.reboot + com.apple.frontboard.shutdown（当前方案）— ⏳ 待验证

**方法**：将 selector 从 `"shutdown"` 改为 `"reboot"`。

```swift
svc.perform(NSSelectorFromString("reboot"))
```

**逆向深入分析**：
- `bin/reboot` 依赖 `libjailbreak.dylib`（`jb_oneshot_entitle_now`），jailbreak-only
- 壳的命令注册列表：`rebackboardd.reboot.shutdown.refreshUicache` — 四个独立命令
- `rebootView` 和 `shutdownView` 是独立的 SwiftUI 视图
- FBSSystemService 在壳中被两处引用（`_OBJC_CLASS_$_FBSSystemService`）
- `sharedService` selector 旁就是命令处理逻辑
- `com.apple.frontboard.shutdown` 权限同时覆盖 shutdown 和 reboot 两个操作

### 当前改动
| 文件 | 改动 |
|------|------|
| `TrollServer.entitlements` | `com.apple.frontboard.shutdown` |
| `ViewController.swift` | `rebootDevice()` 用 `FBSSystemService.reboot` selector |
| `reboot_helper.c` | 已删除 |
| `build.sh` / CI | 已清理

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

## 方案 5：FBSSystemService + com.apple.frontboard.shutdown（当前方案）— ⏳ 待验证

**方法**：逆向分析 TrollAutoScript（壳）的实现，发现其使用 `FBSSystemService` + `com.apple.frontboard.shutdown`，而非裸 reboot() syscall。

```swift
let cls = NSClassFromString("FBSSystemService") as? NSObject.Type
let svc = cls?.value(forKey: "sharedService") as? NSObject
svc?.perform(NSSelectorFromString("shutdown"))
```

**逆向发现**：
- TrollAutoScript 二进制中不含 `com.apple.system.reboot`，但含 `com.apple.frontboard.shutdown`
- 二进制引用了 `_OBJC_CLASS_$_FBSSystemService`（FrontBoardServices.framework）
- `bin/reboot` 依赖 `libjailbreak.dylib`（jailbreak-only），不是实际使用的重启工具
- 重启功能在 SwiftUI 的 `rebootView`/`shutdownView` 中，走的是主二进制自身逻辑

**优势**：
- `com.apple.frontboard.shutdown` 是苹果公开的内部权限，TrollStore/ldid 可正常签署
- 不需要 root 权限（FBSSystemService 通过 XPC 与 backboardd 通信）
- 不需要 external helper 二进制
- 与 TrollAutoScript 完全相同的实现方式

### 改动清单
| 文件 | 改动 |
|------|------|
| `TrollServer.entitlements` | 替换 `com.apple.system.reboot` → `com.apple.frontboard.shutdown` |
| `main.swift` | 移除 `--reboot` 自产卵逻辑 |
| `ViewController.swift` | `rebootDevice()` 改用 `FBSSystemService.sharedService.shutdown` |
| `reboot_helper.c` | 删除（不再需要） |
| `build.sh` | 移除 reboot_helper.c 编译步骤 |
| `.github/workflows/build.yml` | 移除 reboot_helper.c 编译步骤 |

### 预期结果
- 调用 `[FBSSystemService.sharedService shutdown]` 后设备立即黑屏重启
- 无需 root 权限，无需外部 helper

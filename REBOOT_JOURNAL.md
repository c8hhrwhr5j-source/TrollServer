# 重启功能修复日记

## iOS reboot() 系统调用的必要条件

在 iOS 上调用 `reboot()` 需要同时满足两个条件：
1. **root 权限**（UID 0）
2. **com.apple.system.reboot**  entitlement

缺一不可。即使进程是 root，没有该 entitlement 也会被 MAC 策略静默拒绝。

## 方案 1：bin/reboot（原方案）— ❌ 失败

**方法**：使用项目自带 `bin/reboot`（链接了 libjailbreak.dylib 的预编译二进制）

**表现**：`reboot 失败，错误码：1`

**根因**：`bin/reboot` 依赖 `@rpath/libjailbreak.dylib`，非越狱环境下该库不存在，dyld 加载阶段就失败了（非 reboot 调用失败）。

**结论**：不可用，依赖越狱环境。

## 方案 2：launchctl reboot — ❌ 失败

**方法**：通过 persona-mgmt 的 spawnAndWait 执行 `bin/launchctl reboot`

**表现**：`reboot 失败，错误码：154`

**根因**：iOS 上 `launchctl reboot` 需要 userspace 参数（`launchctl reboot userspace`），但后者只是用户空间重启（respring），不是真正的设备重启。不带参数的 reboot 返回 154（不支持）。

**结论**：不可用，iOS 的 launchctl 不支持完整重启。

## 方案 3：reboot_helper.c（编译的 C 二进制）— ❌ 无反应

**方法**：编译一个最小 C 二进制直接调用 `reboot(RB_AUTOBOOT)`，通过 persona-mgmt 以 root spawn

**表现**：日志显示"正在执行：重启...."后无任何反应，设备不重启

**根因**：`reboot_helper.c` 编译后是裸 Mach-O，没有任何 entitlements。persona-mgmt 只能让子进程以 root 身份运行，但无法注入 entitlements。子进程缺少 `com.apple.system.reboot` 权限，MAC 策略静默拒绝了 `reboot()` 调用。

编译问题：`<sys/reboot.h>` 在 iOS SDK 中不存在，需要用 `extern int reboot(int);` + `#define RB_AUTOBOOT 0x400` 手动声明。

**结论**：不可用，裸 C 二进制无 entitlements。

## 方案 4：自产卵（当前方案）— ⏳ 待验证

**方法**：不再依赖外部 helper，而是让主 Swift 二进制 spawn 自身：
```
spawnAndWait(path: Bundle.main.executablePath!, args: [selfPath, "--reboot"])
```

- `main.swift` 中在 `UIApplicationMain` 之前检测 `--reboot` 参数
- 检测到后直接调用 `reboot(RB_AUTOBOOT)` + `exit(1)` 兜底
- 走 persona-mgmt spawn，子进程以 root 运行
- **关键**：子进程是主二进制自身，天生继承完整 entitlements（含新增的 `com.apple.system.reboot`）

### 改动清单
| 文件 | 改动 |
|------|------|
| `TrollServer.entitlements` | 新增 `com.apple.system.reboot` |
| `main.swift` | 新增 `--reboot` 参数拦截，直接调 `reboot()` |
| `ViewController.swift` | `rebootDevice()` 改为 spawn 自身 + `--reboot` |

### 预期结果
- 子进程同时满足 root + reboot entitlement → `reboot()` 应成功执行
- 设备立即黑屏重启

### 可能失败原因
- `com.apple.system.reboot` 在 TrollStore 环境下可能不被内核认可（需平台签名）
- 可尝试的备选：`RB_AUTOBOOT`(0x400) vs `RB_HALT`(0x8) vs 裸 syscall number

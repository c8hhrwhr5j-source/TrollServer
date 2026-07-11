# libiPadSpoof — TrollStore 设备伪装方案（增强版）

> 目标：让 **QQ / 微信** 识别当前设备为 iPad，实现 iPad+iPhone 同时在线（绕过互踢），获得 iPad 版布局 / 功能。

## ⚠️ 关键前提（必读）

TrollStore **不是越狱**，无法修改系统全局状态。“一个插件让所有 App 都以为自己是 iPad”
在免越狱下**做不到**——必须**针对每个 App 注入**。

用 **TrollFools** 可以直接给「App Store 正版」微信/QQ 注入 dylib，
无需先 dump 解密 IPA。App 运行时由系统内核当场解密。

> `libiPadSpoof.dylib` 默认【开启】，注入即生效。

---

## 方法一（推荐 ✅）：TrollFools 注入正版微信 / QQ

**全程在手机上完成，不需要解密 IPA。**

1. 巨魔商店（TrollStore）安装 **TrollFools**（最新版）。
2. 把 `libiPadSpoof.dylib` 通过 AirDrop / 文件 App 传到 iPhone。
3. 打开 **TrollFools** → 选 **微信**（或 QQ）→ **注入 dylib** → 选 `libiPadSpoof.dylib`。
4. 回到桌面，**上滑彻底杀掉微信/QQ 进程**，重新打开。
5. 登录后设备列表直接显示 **iPad**，可与手机同时在线（不会互踢）。
6.（可选）打开 **TrollServer** → 设备伪装 → 切换开关 / 选择具体 iPad 型号。
   配置通过本地 HTTP（`127.0.0.1:51111/api/spoof`）回传给 dylib。

> 微信/QQ App Store 更新后，TrollFools 注入会失效，重新注入一次即可（约 1 秒）。

## 方法二（备选）：TrollServer 内置注入引擎

TrollServer App 内置了 Mach-O 修补 + IPA 打包功能，可在手机上直接生成注入版 IPA：

1. 打开 TrollServer → 往下滑到「dylib 注入」区域
2. 对微信/QQ 点击「生成注入 IPA」
3. 生成完成后点击「安装到 TrollStore」

> 注意：此方法要求 App 二进制未被 FairPlay DRM 加密。App Store 安装的正版应用
> 含有加密，需先用 AppDump 等工具解密。推荐使用方法一（TrollFools）。

---

## 编译 dylib（在 macOS 上）

```bash
cd TrollServer/spoof
./build_spoof.sh
# 产物: libiPadSpoof.dylib
```

---

## Hook 覆盖一览（增强版 v3.0）

### C 函数（fishhook 重绑定）

| 函数 | 伪装行为 |
|------|---------|
| `sysctlbyname("hw.machine")` | 返回 iPd 型号（如 `iPad14,2`） |
| `sysctlbyname("hw.model")` | 同上 |
| `sysctlbyname("hw.product")` | 同上 |
| `sysctlbyname("hw.memsize")` | 返回 8 GB（iPad Pro 特征） |
| `sysctlbyname("hw.targettype")` | 返回 `"iPad"` |
| `uname()` → `utsname.machine` | 返回 iPad 型号 |
| `sysctl(CTL_HW, ...)` | 拦截 `HW_MACHINE` / `HW_MODEL` |
| `getifaddrs()` | 过滤蜂窝接口（pdp_ip*/ap*），伪装 WiFi-only iPad |
| `_dyld_get_image_name()` | 隐藏本 dylib，防注入检测 |
| `CFPreferencesCopyAppValue()` | 拦截 MobileGestalt 键值查询（ProductType/DeviceClass 等） |

### ObjC 方法（method swizzling）

| 类 / 方法 | 伪装行为 |
|-----------|---------|
| `UIDevice.model` | 返回 `"iPad"` |
| `UIDevice.localizedModel` | 返回 `"iPad"` |
| `UIDevice.userInterfaceIdiom` | 返回 `UIUserInterfaceIdiomPad` |
| `UIDevice.systemName` | 返回 `"iPadOS"`（替换 "iPhone OS"） |
| `UIDevice.systemVersion` | 保持不变（iOS/iPadOS 版本号一致） |
| `UIDevice.name` | 返回 `"iPad"` |
| `UIDevice.identifierForVendor` | 返回派生的 iPad 风格 UUID（每次启动相同，与真实 IDFV 不可互推） |
| `NSProcessInfo.operatingSystemVersionString` | 替换 "iPhone OS" → "iPadOS" |
| `NSMutableURLRequest.setValue:forHTTPHeaderField:` | User-Agent 中机型/OS 名改为 iPad 版本 |
| `WKWebView.customUserAgent` | 同上 |
| `CTTelephonyNetworkInfo.subscriberCellularProvider` | 返回 `nil`（WiFi-only iPad） |
| `CTTelephonyNetworkInfo.currentRadioAccessTechnology` | 返回 `nil` |

### 防检测

| 措施 | 说明 |
|------|------|
| `_dyld_get_image_name` 重写 | 枚举镜像时隐藏 `libiPadSpoof.dylib`，返回 `libSystem.B.dylib` |
| 蜂窝接口过滤 | `getifaddrs` 移除 pdp_ip*/ap* 接口，模拟 WiFi-only iPad |

---

## 后台保活机制

### TrollServer Daemon（Swift 侧）

| 策略 | 实现 |
|------|------|
| **静音音频** | `SilentAudioPlayer` 无限循环静音 WAV，iOS 给予无限后台权限 |
| **后台任务续期** | `KeepAliveManager` 每 15s 通过主线程续期 `beginBackgroundTask` |
| **禁止休眠** | `UIApplication.isIdleTimerDisabled = true` |
| **音频健康监控** | 每 30s 检测播放状态并自动恢复 |
| **看门狗** | `ServiceMonitor` 每 5s BSD socket 端口检查 + 连续 2 次失败自动重启 |
| **LaunchDaemon** | `DaemonBootstrap` 安装系统 daemon，`KeepAlive: true` + `RunAtLoad: true` |
| **Background Modes** | `audio` + `fetch` + `processing`（Info.plist 已配置） |

### Dylib 保活心跳（ObjC 侧）

| 措施 | 说明 |
|------|------|
| **心跳检测** | 每 120s 向 `http://127.0.0.1:51111/api/spoof` 发送检测请求 |
| **自动恢复** | 连续 3 次不可达时执行 `launchctl kickstart` 重启 daemon |
| **Common RunLoop Modes** | 计时器注册到 `NSRunLoopCommonModes`，滚动时不挂起 |

---

## 绕过互踢原理

微信/QQ 的设备互踢机制基于多维指纹判定：
1. **硬件型号**（`sysctlbyname` / `uname` / MobileGestalt）→ 全部伪装为 iPad
2. **设备唯一标识**（`identifierForVendor`）→ 派生 iPad 风格 UUID，不与真机相同
3. **蜂窝能力**（`CTTelephonyNetworkInfo` / 网络接口）→ 伪装 WiFi-only iPad
4. **系统名称**（"iPhone OS" → "iPadOS"）→ 全链路替换
5. **应用层 UA**（HTTP 请求头）→ 机型号/OS 名全部改写

当所有维度都统一返回 iPad 信息后，微信/QQ 服务器判定为「一个 iPad + 一个 iPhone 同时登录」，
这是微信官方支持的模式，不会触发互踢。

> **关键**：`identifierForVendor` 的确定性派生确保每次登录时设备 ID 一致，
> 避免被判定为「新设备登录」。

---

## 验证 & 排查

- 在 QQ/微信内查看「关于/设备」或触发 iPad 布局
- 登录后观察是否互踢其他设备（互踢说明伪装不完整）
- 日志：`NSLog("[libiPadSpoof] ✅ 增强版已加载 ...")`
- 若未生效：(a) App 是否已注入 dylib；(b) 是否已杀进程重开；(c) TrollServer 伪装开关是否开启

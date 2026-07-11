# libiPadSpoof — TrollStore 设备伪装方案

> 目标：让 **QQ / 微信** 识别当前设备为 iPad，从而获得 iPad 版布局 / 功能。

## ⚠️ 关键前提（必读）

TrollStore **不是越狱**，它无法修改系统全局状态、也无法改变其它进程行为。
“一个插件让所有 App 都以为自己是 iPad”在免越狱下**做不到**——必须**针对每个 App 注入**。

但好消息是：**用 TrollFools 可以直接给「App Store 正版」微信/QQ 注入 dylib，
无需先 dump 解密 IPA**。因为 App 运行时由系统内核当场解密，TrollFools 只往二进制加一条
`LC_LOAD_DYLIB` 加载命令并拷入 dylib 即可。所以方法②（TrollFools 注入）是目前
免越狱 + 正版 App 的**唯一真正可行路径**。

> `libiPadSpoof.dylib` 默认【开启】，注入即生效；可在 TrollServer App 里开关/换型号。

---

## 方法一（推荐 ✅）：TrollFools 注入正版微信 / QQ

**不需要解密 IPA，不需要 macOS 电脑改包，全程在手机上完成。**

1. 巨魔商店（TrollStore）安装 **TrollFools**（最新版）。
2. 在 macOS 上编译 dylib（见下方「编译 dylib」），把 `libiPadSpoof.dylib`
   通过 AirDrop / 文件 App 传到 iPhone。
3. 打开 **TrollFools** → 选 **微信**（或 QQ）→ **注入 dylib** → 选 `libiPadSpoof.dylib`。
4. 回到桌面，**上滑彻底杀掉微信/QQ 进程**，重新打开。
5. 登录后设备列表直接显示 **iPad**，可与手机同时在线。
6.（可选）打开 **TrollServer** → 设备伪装 → 切换开关 / 选择具体 iPad 型号。
   配置通过本地 HTTP（`127.0.0.1:51111/api/spoof`）回传给 dylib，无需文件权限。

> 微信/QQ App Store 更新后，TrollFools 注入会失效，重新注入一次即可（约 1 秒）。

## 方法二（备选）：手动注入重签 IPA 用 TrollStore 安装

适合想在电脑上一次性打包、或没有 TrollFools 的场景。

### 编译 dylib（在 macOS 上）
```bash
cd TrollServer/spoof
./build_spoof.sh
# 产物: libiPadSpoof.dylib
```

### 注入 dylib 到 IPA
使用 `insert_dylib`（或 `optool`）：

```bash
# 解包
mkdir -p work && cd work
unzip -q ../QQ.ipa

# 把 dylib 放进 bundle 的 Frameworks 目录
mkdir -p Payload/QQ.app/Frameworks
cp ../libiPadSpoof.dylib Payload/QQ.app/Frameworks/

# 在二进制中插入 LC_LOAD_DYLIB（指向 @executable_path/Frameworks/libiPadSpoof.dylib）
insert_dylib --strip-codesig --inplace \
  "@executable_path/Frameworks/libiPadSpoof.dylib" \
  Payload/QQ.app/QQ

# 重新打包
zip -qr ../QQ-spoofed.ipa Payload
```

对微信重复同样步骤（把 `QQ` 换成 `WeChat`）。

### 通过 TrollStore 安装
把 `QQ-spoofed.ipa` / `WeChat-spoofed.ipa` 用 TrollStore 安装。
TrollStore 会自动处理 `skip-library-validation`，让 dylib 在 App 启动时加载。

---

## 3. 用 TrollServer App 控制伪装

1. 打开 **TrollServer**，进入「设备伪装」区域。
2. 点 **📱 改为 iPad** 快速开启（默认 iPad14,2），或点 **⚙️ 设置** 选择具体型号 / 开关。
3. 配置写入共享文件 `/var/mobile/Library/Preferences/com.trollserver.spoof.plist`
   （并 chmod 0644），dylib 在 QQ/微信进程内读取。
4. **彻底关闭并重新打开 QQ / 微信**（上滑杀进程），伪装即生效。

> dylib 每 30s 会重新读取配置；网络回退：若沙盒读不到文件，会向
> `http://127.0.0.1:51111/api/spoof`（TrollServer 常驻服务）拉取配置。

---

## 4. Hook 覆盖点

| API | 返回值（启用时） |
|-----|----------------|
| `sysctlbyname("hw.machine")` | 目标 iPad 标识符（如 `iPad14,2`） |
| `sysctlbyname("hw.model")` / `hw.product` | 同上 |
| `uname()` → `utsname.machine` | 同上 |
| `sysctl(CTL_HW, HW_MACHINE/HW_MODEL)` | 同上 |
| `UIDevice.model` / `localizedModel` | `"iPad"` |
| `UIDevice.userInterfaceIdiom` | `.pad` |

QQ / 微信主流机型检测均基于上述 API，基本覆盖。

---

## 5. 验证 & 排查

- 在 QQ/微信内查看“关于/设备”或触发 iPad 布局；或在 App 内打开任意会打印机型的页面。
- 日志：dylib 加载时会 `NSLog("[libiPadSpoof] loaded ...")`，可用日志工具（如 TrollServer 的
  `/var/mobile/Library/Logs`）确认是否加载成功。
- 若未生效：确认 (a) App 是 TrollStore 安装且 dylib 已注入；(b) 已杀进程重开；
  (c) TrollServer 中伪装开关为开启。

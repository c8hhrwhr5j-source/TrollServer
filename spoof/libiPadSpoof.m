/*
 * libiPadSpoof.m — 注入 QQ / 微信进程的伪装 dylib（增强版）
 *
 * 原理（TrollStore / TrollFools 免越狱可行方案）：
 *   在目标 App 进程内，Hook 它读取设备型号 / 指纹的系统 API，返回 iPad 值。
 *   TrollStore 只给 App 加 skip-library-validation，dylib 只影响被注入的 App，
 *   无法全局生效 —— 所以必须分别注入 QQ 和微信。
 *
 * ────────────────── Hook 覆盖一览 ──────────────────
 *
 * C 函数（fishhook）：
 *   sysctlbyname("hw.machine" / "hw.model" / "hw.product")
 *   uname() → utsname.machine
 *   sysctl(CTL_HW, HW_MACHINE / HW_MODEL)
 *   getifaddrs() → 网络接口名（隐藏蜂窝接口 → WiFi-only iPad）
 *   _dyld_get_image_name() → 隐藏本 dylib 防注入检测
 *
 * ObjC 方法（method swizzling）：
 *   UIDevice.model / localizedModel → "iPad"
 *   UIDevice.userInterfaceIdiom → UIUserInterfaceIdiomPad
 *   UIDevice.systemName → "iPadOS"
 *   UIDevice.name → "iPad"
 *   UIDevice.identifierForVendor → 派生的 iPad 风格 UUID
 *   NSProcessInfo.operatingSystemVersionString → 替换 "iPhone OS" 为 "iPadOS"
 *   NSMutableURLRequest.setValue:forHTTPHeaderField: → UA 重写
 *   CTTelephonyNetworkInfo.subscriberCellularProviderDidUpdateNotifier → 抑制蜂窝回调
 *
 * ────────────────── 配置来源 ──────────────────
 *   1) /var/mobile/Library/Preferences/com.trollserver.spoof.plist
 *   2) /var/mobile/.trollserver_spoof.plist
 *   3) HTTP GET http://127.0.0.1:51111/api/spoof（沙盒读不到文件时的回退）
 *
 * 默认【开启】，注入即生效；每 30s 刷新一次配置。
 *
 * 兼容注入方式：
 *   - TrollFools 直接注入「正版」微信/QQ（推荐，无需解密 IPA）
 *   - 手动 insert_dylib 进重签 IPA 后 TrollStore 安装
 */

#import <signal.h>
#import <setjmp.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdarg.h>
#import <Foundation/Foundation.h>
#ifndef NO_UIKIT
#import <UIKit/UIKit.h>
#endif
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/errno.h>
#import <sys/socket.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <dlfcn.h>
#import <string.h>
#import <strings.h>
#import "fishhook.h"

#pragma mark - 诊断日志（原始 POSIX write，不依赖任何 ObjC/UIKit）

// 日志优先写入进程 $TMPDIR（微信沙箱内 /tmp 不可写，$TMPDIR 才是沙箱 tmp）
// Filza 查看: /var/mobile/Containers/Data/Application/<WeChat>/tmp/libiPadSpoof_boot.log
static void bootlog(const char *msg) {
    // 路径1: $TMPDIR（进程沙箱 tmp 目录，一定可写）
    const char *tmpdir = getenv("TMPDIR");
    char path[512];
    if (tmpdir) {
        snprintf(path, sizeof(path), "%slibiPadSpoof_boot.log", tmpdir);
    } else {
        // 降级：$HOME/tmp/
        const char *home = getenv("HOME");
        if (home) {
            snprintf(path, sizeof(path), "%s/tmp/libiPadSpoof_boot.log", home);
        } else {
            snprintf(path, sizeof(path), "/tmp/libiPadSpoof_boot.log");
        }
    }
    int fd = open(path, O_WRONLY|O_CREAT|O_APPEND, 0644);
    // 备用: /var/mobile/Documents
    if (fd < 0) {
        fd = open("/var/mobile/Documents/libiPadSpoof_boot.log",
                  O_WRONLY|O_CREAT|O_APPEND, 0644);
    }
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
    // 同时写 stderr（设备日志可见: idevicesyslog 或 Xcode Console）
    write(STDERR_FILENO, msg, strlen(msg));
    write(STDERR_FILENO, "\n", 1);
}

__attribute__((format(printf, 1, 2)))
static void bootlogf(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    bootlog(buf);
}

#pragma mark - 崩溃信号处理器（调试用）

static sigjmp_buf g_safe_jmp;
static volatile int   g_crash_count = 0;

static void spoof_crash_handler(int sig, siginfo_t *info, void *ctx) {
    const char *names[] = {"?", "SIGHUP","SIGINT","SIGQUIT","SIGILL",
        "SIGTRAP","SIGABRT","SIGEMT","SIGFPE","SIGKILL",
        "SIGBUS","SIGSEGV","SIGSYS","SIGPIPE","SIGALRM",
        "SIGTERM"};
    const char *name = (sig >= 1 && sig <= 15) ? names[sig] : "UNKNOWN";
    char buf[256];
    snprintf(buf, sizeof(buf), "[libiPadSpoof] CRASH signal=%s(%d) addr=%p",
             name, sig, info ? info->si_addr : NULL);
    bootlog(buf);

    g_crash_count++;
    // 用 siglongjmp 跳回安全恢复点，避免进程终止
    if (g_crash_count <= 5) {
        siglongjmp(g_safe_jmp, sig);
    }
    // 超过5次还在崩 → 让系统终止进程
    signal(sig, SIG_DFL);
    raise(sig);
}

// 用 +load 在 constructor 之前写启动探针（验证 dylib 是否真的被 dyld 加载）
// 如果这个文件都没有，说明 dyld 在加载 dylib 时就失败了
@interface SpoofBootProbe : NSObject @end
@implementation SpoofBootProbe
+ (void)load {
    bootlog("[BOOT] +load 已执行 — dylib 被 dyld 成功加载");
}
@end

#pragma mark - 全局状态

static BOOL       g_enabled       = YES;
static NSString  *g_productType   = @"iPad14,2";
static NSString  *g_idfvBase      = nil;
static NSTimeInterval g_lastRefresh = 0;

#pragma mark - 辅助工具

#ifndef NO_UIKIT
/// 用原 IDFV 派生一个 iPad 风格的稳定 UUID（同一设备每次启动相同）
/// 早期构造阶段 UIDevice 可能不可用，需要有完整降级路径
static NSString *derive_ipad_idfv(void) {
    if (g_idfvBase) return g_idfvBase;

    NSString *realIDFV = nil;
    @autoreleasepool {
        @try {
            // 通过 spoof_identifierForVendor（交换后它指向原始实现）
            UIDevice *dev = [UIDevice performSelector:@selector(currentDevice)];
            if (dev && [dev respondsToSelector:@selector(spoof_identifierForVendor)]) {
                NSUUID *uuid = [dev performSelector:@selector(spoof_identifierForVendor)];
                if (uuid && [uuid isKindOfClass:[NSUUID class]]) {
                    realIDFV = [uuid UUIDString];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[libiPadSpoof] ⚠️ derive_ipad_idfv 异常: %@", e.reason);
        }
    }
    if (!realIDFV) realIDFV = @"00000000-0000-0000-0000-000000000000";

    // 加盐后取 MD5（保持确定性 + 不可逆向推导真实 IDFV）
    NSString *salt = [realIDFV stringByAppendingString:@"+trollserver+ipad"];
    const char *csalt = [salt UTF8String];
    unsigned char hash[16] = {0};
    unsigned long len = strlen(csalt);
    for (unsigned long j = 0; j < len; j++) {
        hash[j % 16] ^= (unsigned char)csalt[j];
        hash[(j * 7 + 3) % 16] += (unsigned char)(csalt[j] ^ 0xAA);
    }

    g_idfvBase = [[NSString stringWithFormat:
        @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        hash[0], hash[1], hash[2], hash[3],
        hash[4], hash[5],
        hash[6], hash[7],
        hash[8], hash[9],
        hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]] copy];
    return g_idfvBase;
}
#endif // NO_UIKIT

#pragma mark - 配置读取

static void apply_config(NSDictionary *cfg) {
    if (!cfg) return;
    id en = cfg[@"Enabled"];
    if ([en isKindOfClass:[NSNumber class]]) g_enabled = [en boolValue];
    id pt = cfg[@"ProductType"];
    if ([pt isKindOfClass:[NSString class]] && [pt length] > 0) {
        g_productType = [pt copy];
        // 型号变了，重置 IDFV（可选）
        g_idfvBase = nil;
    }
}

static void refresh_config_if_needed(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - g_lastRefresh < 30.0) return;
    g_lastRefresh = now;

    // 只读本地 plist（TrollServer daemon 每次保存配置时写入）
    // 不在构造函数阶段做阻塞 HTTP 请求，避免网络栈未初始化导致崩溃
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.trollserver.spoof.plist",
        @"/var/mobile/.trollserver_spoof.plist"
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) { apply_config(d); return; }
    }
    // 无配置文件 → 使用默认值（g_enabled=YES, productType=iPad14,2）
}

#pragma mark - C 函数 Hook

// ──── sysctlbyname ────
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;

static int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    refresh_config_if_needed();
    if (g_enabled && name && oldp && oldlenp) {
        NSString *n = @(name);
        // 核心硬件标识
        if ([n isEqualToString:@"hw.machine"] ||
            [n isEqualToString:@"hw.model"]  ||
            [n isEqualToString:@"hw.product"]) {
            const char *val = g_productType.UTF8String;
            size_t need = strlen(val) + 1;
            if (*oldlenp < need) { *oldlenp = need; errno = ENOMEM; return -1; }
            strlcpy((char *)oldp, val, *oldlenp);
            return 0;
        }
        // CPU 型号（iPad 用 Apple M1/M2 系列标识，与 A 系列不同）
        if ([n isEqualToString:@"hw.cputype"]) {
            // ARM64 = 0x0100000C，iPad/iPhone 相同，保持不变
            // 不需要修改，走原始调用
        }
        if ([n isEqualToString:@"hw.cpusubtype"]) {
            // A 系列芯片的 sub type 可能暴露设备代际
            // 不修改，iPad Pro 和 iPhone 可能用同代芯片
        }
        // 内存（iPad Pro 通常 8/16GB，高于 iPhone）
        if ([n isEqualToString:@"hw.memsize"]) {
            int64_t ipadMem = 8LL * 1024 * 1024 * 1024; // 8 GB
            size_t need = sizeof(ipadMem);
            if (*oldlenp >= need) {
                memcpy(oldp, &ipadMem, need);
                return 0;
            }
        }
        // 机型名称
        if ([n isEqualToString:@"hw.targettype"] ||
            [n isEqualToString:@"hw.target"]) {
            const char *val = "iPad";
            size_t need = strlen(val) + 1;
            if (*oldlenp < need) { *oldlenp = need; errno = ENOMEM; return -1; }
            strlcpy((char *)oldp, val, *oldlenp);
            return 0;
        }
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ──── uname ────
static int (*orig_uname)(struct utsname *) = NULL;

static int my_uname(struct utsname *uts) {
    int r = orig_uname(uts);
    refresh_config_if_needed();
    if (g_enabled && uts) {
        strlcpy(uts->machine, g_productType.UTF8String, sizeof(uts->machine));
    }
    return r;
}

// ──── sysctl ────
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;

static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                     void *newp, size_t newlen) {
    refresh_config_if_needed();
    if (g_enabled && name && namelen >= 2 &&
        name[0] == CTL_HW &&
        (name[1] == HW_MACHINE || name[1] == HW_MODEL) &&
        oldp && oldlenp) {
        const char *val = g_productType.UTF8String;
        size_t need = strlen(val) + 1;
        if (*oldlenp < need) { *oldlenp = need; errno = ENOMEM; return -1; }
        strlcpy((char *)oldp, val, *oldlenp);
        return 0;
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

// ──── getifaddrs（网络接口 → WiFi-only iPad）────
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;

static int my_getifaddrs(struct ifaddrs **ifap) {
    int ret = orig_getifaddrs(ifap);
    refresh_config_if_needed();
    if (!g_enabled || ret != 0 || !ifap || !*ifap) return ret;

    // 遍历接口列表，移除 pdp_ip / ap 等蜂窝接口（WiFi-only iPad 不应有）
    struct ifaddrs *prev = NULL;
    struct ifaddrs *cur = *ifap;
    while (cur) {
        if (cur->ifa_name) {
            const char *name = cur->ifa_name;
            // 蜂窝接口名：pdp_ip0, pdp_ip1, ap1 等
            if (strncmp(name, "pdp_ip", 6) == 0 ||
                strncmp(name, "ap", 2) == 0) {
                struct ifaddrs *toFree = cur;
                if (prev) {
                    prev->ifa_next = cur->ifa_next;
                    cur = cur->ifa_next;
                } else {
                    *ifap = cur->ifa_next;
                    cur = *ifap;
                }
                // 不能 free，接口内存由系统管理
                continue;
            }
        }
        prev = cur;
        cur = cur->ifa_next;
    }
    return ret;
}

// ──── _dyld_get_image_name（防注入检测）────
/// WeChat/QQ 常遍历 dyld 加载的镜像名，检查是否有可疑 dylib
static const char *(*orig_dyld_get_image_name)(uint32_t) = NULL;

static const char *my_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (!name) return name;
    // 隐藏本 dylib 自身
    if (strstr(name, "libiPadSpoof")) return "/usr/lib/libSystem.B.dylib";
    return name;
}

// ──── _dyld_image_count（不修改计数，只改名称过滤）────
// 已通过 _dyld_get_image_name 处理，无需额外 hook count

// ──── MobileGestalt CFPreferences 键值查询 ────
/// CoreTelephony 和 CoreFoundation 会直接调用 CFPreferences
/// 读取 com.apple.MobileGestalt.plist 中的键值
/// 这里 hook CFPreferencesCopyAppValue 拦截已知的设备标识键
static CFPropertyListRef (*orig_CFPrefsCopyAppValue)(CFStringRef, CFStringRef) = NULL;

static CFPropertyListRef my_CFPrefsCopyAppValue(CFStringRef key, CFStringRef appID) {
    CFPropertyListRef val = orig_CFPrefsCopyAppValue(key, appID);
    refresh_config_if_needed();
    if (!g_enabled || !key || !val) return val;

    NSString *ks = (__bridge NSString *)key;
    NSString *as = appID ? (__bridge NSString *)appID : @"";

    // 只处理 MobileGestalt 相关的查询
    if (![as isEqualToString:@"com.apple.MobileGestalt"]) return val;

    // 拦截设备型号键（这些是最常见的 MobileGestalt 查询键）
    // h9jDsbgj7xQeK8I3iMh2Mg == ProductType
    // qHWqXo72iG2wYkmZDgwTfw == DeviceClass
    static NSSet *spoofKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        spoofKeys = [NSSet setWithObjects:
            @"h9jDsbgj7xQeK8I3iMh2Mg",     // ProductType
            @"qHWqXo72iG2wYkmZDgwTfw",     // DeviceClass
            @"Z/dqyWS6OZTRy10UcmUAhw",     // MarketingName
            @"qeaj75wk3HF4DwQ8qbIi7g",     // Internal iPad flag
            nil];
    });

    if (![spoofKeys containsObject:ks]) return val;

    // 释放原始值，返回伪装值
    if (val) CFRelease(val);

    if ([ks isEqualToString:@"h9jDsbgj7xQeK8I3iMh2Mg"]) {
        return CFBridgingRetain(g_productType);
    }
    if ([ks isEqualToString:@"qHWqXo72iG2wYkmZDgwTfw"]) {
        return CFBridgingRetain(@"iPad");
    }
    if ([ks isEqualToString:@"Z/dqyWS6OZTRy10UcmUAhw"]) {
        return CFBridgingRetain(@"iPad Pro 12.9-inch (6th generation)");
    }
    if ([ks isEqualToString:@"qeaj75wk3HF4DwQ8qbIi7g"]) {
        return CFBridgingRetain(@(1));
    }
    return NULL;
}

#pragma mark - Objective-C 方法 Hook

#ifndef NO_UIKIT
// ──── UIDevice ────
@interface UIDevice (SpoofExt)
- (NSString *)spoof_model;
- (NSString *)spoof_localizedModel;
- (UIUserInterfaceIdiom)spoof_userInterfaceIdiom;
- (NSString *)spoof_systemName;
- (NSString *)spoof_name;
- (NSUUID *)spoof_identifierForVendor;
- (NSString *)spoof_systemVersion;
+ (UIDevice *)spoof_currentDevice;
@end

@implementation UIDevice (SpoofExt)

- (NSString *)spoof_model {
    refresh_config_if_needed();
    return g_enabled ? @"iPad" : [self spoof_model];
}

- (NSString *)spoof_localizedModel {
    refresh_config_if_needed();
    return g_enabled ? @"iPad" : [self spoof_localizedModel];
}

- (UIUserInterfaceIdiom)spoof_userInterfaceIdiom {
    refresh_config_if_needed();
    return g_enabled ? UIUserInterfaceIdiomPad : [self spoof_userInterfaceIdiom];
}

- (NSString *)spoof_systemName {
    refresh_config_if_needed();
    return g_enabled ? @"iPadOS" : [self spoof_systemName];
}

- (NSString *)spoof_systemVersion {
    return [self spoof_systemVersion];
}

- (NSString *)spoof_name {
    refresh_config_if_needed();
    return g_enabled ? @"iPad" : [self spoof_name];
}

- (NSUUID *)spoof_identifierForVendor {
    refresh_config_if_needed();
    if (g_enabled) {
        return [[NSUUID alloc] initWithUUIDString:derive_ipad_idfv()];
    }
    return [self spoof_identifierForVendor];
}

+ (UIDevice *)spoof_currentDevice {
    return [self spoof_currentDevice];
}

@end
#endif // NO_UIKIT


// ──── NSProcessInfo ────
@interface NSProcessInfo (SpoofExt)
- (NSString *)spoof_operatingSystemVersionString;
- (NSOperatingSystemVersion)spoof_operatingSystemVersion;
@end

@implementation NSProcessInfo (SpoofExt)

- (NSString *)spoof_operatingSystemVersionString {
    NSString *orig = [self spoof_operatingSystemVersionString];
    refresh_config_if_needed();
    if (g_enabled && orig) {
        // "Version 17.0 (Build 21A329)" → 不变
        // 但有些实现会前缀 "iPhone OS"，统一改为 "iPadOS"
        NSMutableString *s = [orig mutableCopy];
        [s replaceOccurrencesOfString:@"iPhone OS"
                           withString:@"iPadOS"
                              options:0
                                range:NSMakeRange(0, [s length])];
        // "iPhone" → "iPad"（兜底）
        [s replaceOccurrencesOfString:@"iPhone"
                           withString:@"iPad"
                              options:0
                                range:NSMakeRange(0, [s length])];
        return s;
    }
    return orig;
}

- (NSOperatingSystemVersion)spoof_operatingSystemVersion {
    // 版本号不变，只改字符串表示
    return [self spoof_operatingSystemVersion];
}

@end


// ──── CTTelephonyNetworkInfo（隐藏蜂窝能力）────
/// WiFi-only iPad 不应有蜂窝运营商信息
/// 注意：CTTelephony 是私有框架，因此用 NSClassFromString 动态获取
/// 方法声明在 NSObject category 上，通过运行时交换到 CTTelephonyNetworkInfo
@interface NSObject (SpoofTelephony)
- (id)spoof_subscriberCellularProvider;
- (NSDictionary *)spoof_serviceSubscriberCellularProviders;
- (NSString *)spoof_currentRadioAccessTechnology;
@end

@implementation NSObject (SpoofTelephony)
- (id)spoof_subscriberCellularProvider {
    refresh_config_if_needed();
    return g_enabled ? nil : [self spoof_subscriberCellularProvider];
}
- (NSDictionary *)spoof_serviceSubscriberCellularProviders {
    refresh_config_if_needed();
    return g_enabled ? @{} : [self spoof_serviceSubscriberCellularProviders];
}
- (NSString *)spoof_currentRadioAccessTechnology {
    refresh_config_if_needed();
    return g_enabled ? nil : [self spoof_currentRadioAccessTechnology];
}
@end

static void hook_telephony_if_available(void) {
    Class ctn = NSClassFromString(@"CTTelephonyNetworkInfo");
    if (!ctn) return;

    // Hook subscriberCellularProvider（返回 nil = 无蜂窝）
    SEL origSel = @selector(subscriberCellularProvider);
    SEL newSel  = @selector(spoof_subscriberCellularProvider);
    Method m = class_getInstanceMethod(ctn, origSel);
    if (!m) {
        // iOS 17+ 可能有新 API，尝试 serviceSubscriberCellularProviders
        origSel = @selector(serviceSubscriberCellularProviders);
        newSel  = @selector(spoof_serviceSubscriberCellularProviders);
        m = class_getInstanceMethod(ctn, origSel);
    }
    Method n = class_getInstanceMethod(ctn, newSel);
    if (m && n) method_exchangeImplementations(m, n);

    // Hook currentRadioAccessTechnology
    SEL ratOrig = @selector(currentRadioAccessTechnology);
    SEL ratNew  = @selector(spoof_currentRadioAccessTechnology);
    Method rm = class_getInstanceMethod(ctn, ratOrig);
    Method rn = class_getInstanceMethod(ctn, ratNew);
    if (rm && rn) method_exchangeImplementations(rm, rn);

    NSLog(@"[libiPadSpoof] CTTelephony hooks installed");
}


// ──── User-Agent 伪装 ────

static NSString *spoof_ua_string(NSString *ua) {
    if (!ua) return ua;
    NSMutableString *s = [ua mutableCopy];

    // 把 "iPhone14,3" 这种机型号整体替换为目标 iPad 型号
    NSError *e = nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"iPhone[0-9]+,[0-9]+" options:0 error:&e];
    if (re) {
        [re replaceMatchesInString:s options:0
                              range:NSMakeRange(0, [s length])
                       withTemplate:g_productType];
    }

    // "iPhone OS" → "iPadOS"
    [s replaceOccurrencesOfString:@"iPhone OS"
                        withString:@"iPadOS"
                           options:0
                             range:NSMakeRange(0, [s length])];

    // 其余零散的 "iPhone" 统一改 "iPad"
    [s replaceOccurrencesOfString:@"iPhone"
                        withString:@"iPad"
                           options:0
                             range:NSMakeRange(0, [s length])];

    return s;
}

@interface NSMutableURLRequest (SpoofUA)
@end
@implementation NSMutableURLRequest (SpoofUA)
- (void)spoof_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    refresh_config_if_needed();
    if (g_enabled && field &&
        [[field lowercaseString] isEqualToString:@"user-agent"]) {
        value = spoof_ua_string(value);
    }
    [self spoof_setValue:value forHTTPHeaderField:field];
}
@end


// ──── WKWebView / UIWebView User-Agent ────
/// WeChat 内嵌浏览器也用 WebView，确保其 customUserAgent 也被伪装
/// 方法声明在 NSObject category 上，通过运行时交换到 WKWebView
@interface NSObject (SpoofWebView)
- (NSString *)spoof_customUserAgent;
@end
@implementation NSObject (SpoofWebView)
- (NSString *)spoof_customUserAgent {
    NSString *ua = [self spoof_customUserAgent];
    refresh_config_if_needed();
    return g_enabled && ua ? spoof_ua_string(ua) : ua;
}
@end


// ──── NSBundle（App 自身的 infoDictionary）────
/// 有些 App 从自己的 Info.plist 读取 UIDeviceFamily 来判断 iPad 支持
/// 不用改，WeChat/QQ 本身是 Universal app，Info.plist 已包含 iPad

#pragma mark - 后台保活心跳（TrollServer daemon 存活检测）

/// dylib 内部定时检测 TrollServer HTTP 是否可达（GCD dispatch_source，不依赖 RunLoop）
/// 若连续 3 次不可达，尝试触发 daemon 重启
static dispatch_source_t g_heartbeatTimer = NULL;
static int g_heartbeatMissCount = 0;

#pragma mark - hook_objc_method 辅助宏

static void hook_objc_method(Class cls, SEL orig, SEL spoof) {
    Method m = class_getInstanceMethod(cls, orig);
    Method n = class_getInstanceMethod(cls, spoof);
    if (m && n) method_exchangeImplementations(m, n);
}

#pragma mark - 构造函数（dylib 被加载时执行）

/// 延迟初始化：等微信/QQ 自身启动完成后再安装 ObjC hooks
/// 避免 constructor 阶段 hook 与 App 初始化流程冲突导致闪退
static void install_objc_hooks(void) {
#ifndef NO_UIKIT
    @try {
        // ── UIDevice ──
        Class devCls = [UIDevice class];
        hook_objc_method(devCls, @selector(model),                    @selector(spoof_model));
        hook_objc_method(devCls, @selector(localizedModel),           @selector(spoof_localizedModel));
        hook_objc_method(devCls, @selector(userInterfaceIdiom),       @selector(spoof_userInterfaceIdiom));
        hook_objc_method(devCls, @selector(systemName),               @selector(spoof_systemName));
        hook_objc_method(devCls, @selector(systemVersion),            @selector(spoof_systemVersion));
        hook_objc_method(devCls, @selector(name),                     @selector(spoof_name));
        hook_objc_method(devCls, @selector(identifierForVendor),      @selector(spoof_identifierForVendor));
        bootlog("[DELAY] UIDevice hooks 已安装");
    } @catch (NSException *e) {
        bootlogf("[DELAY] UIDevice hooks 失败: %s", [e.reason UTF8String]);
    }
#endif

    @try {
        hook_objc_method([NSProcessInfo class],
                         @selector(operatingSystemVersionString),
                         @selector(spoof_operatingSystemVersionString));
        hook_objc_method([NSProcessInfo class],
                         @selector(operatingSystemVersion),
                         @selector(spoof_operatingSystemVersion));
        bootlog("[DELAY] NSProcessInfo hooks 已安装");
    } @catch (NSException *e) {
        bootlogf("[DELAY] NSProcessInfo hooks 失败: %s", [e.reason UTF8String]);
    }

    @try {
        hook_objc_method([NSMutableURLRequest class],
                         @selector(setValue:forHTTPHeaderField:),
                         @selector(spoof_setValue:forHTTPHeaderField:));
        bootlog("[DELAY] NSMutableURLRequest UA hooks 已安装");
    } @catch (NSException *e) {
        bootlogf("[DELAY] NSMutableURLRequest hooks 失败: %s", [e.reason UTF8String]);
    }

    @try {
        Class wkCls = NSClassFromString(@"WKWebView");
        if (wkCls) {
            hook_objc_method(wkCls, @selector(customUserAgent), @selector(spoof_customUserAgent));
            bootlog("[DELAY] WKWebView hooks 已安装");
        }
    } @catch (NSException *e) {
        bootlogf("[DELAY] WKWebView hooks 失败: %s", [e.reason UTF8String]);
    }

    @try {
        hook_telephony_if_available();
    } @catch (NSException *e) {
        bootlogf("[DELAY] CTTelephony hooks 失败: %s", [e.reason UTF8String]);
    }
}

static void start_heartbeat_delayed(void) {
    // 5 秒后在全局低优先级队列启动（不依赖主 RunLoop）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        if (g_heartbeatTimer) return;
        g_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        dispatch_source_set_timer(g_heartbeatTimer,
                                   dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120.0 * NSEC_PER_SEC)),
                                   (uint64_t)(120.0 * NSEC_PER_SEC), 10 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_heartbeatTimer, ^{
            NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:51111/api/spoof"];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.HTTPMethod = @"GET";
            req.timeoutInterval = 3.0;
            NSURLSession *session = [NSURLSession sharedSession];
            [[session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                if (d && !e) {
                    g_heartbeatMissCount = 0;
                } else {
                    g_heartbeatMissCount++;
                    if (g_heartbeatMissCount >= 3) {
                        bootlog("[libiPadSpoof] heart: TrollServer 连续3次不可达");
                        pid_t pid;
                        char *argv[] = {
                            (char *)"/usr/bin/launchctl",
                            (char *)"kickstart",
                            (char *)"-k",
                            (char *)"system/com.trollserver.daemon",
                            NULL
                        };
                        if (posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL) == 0) {
                            waitpid(pid, NULL, 0);
                        }
                        g_heartbeatMissCount = 0;
                    }
                }
            }] resume];
        });
        dispatch_resume(g_heartbeatTimer);
        bootlog("[CSTR] 心跳: GCD timer 已启动 (间隔120s)");
    });
}

__attribute__((constructor))
static void spoof_load(void) {
    bootlog("[CSTR] step0: constructor 入口");

    // ── 第一步：信号处理器（必须在任何操作之前）──
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = spoof_crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    bootlog("[CSTR] step1: 信号处理器已安装 (SEGV,BUS,ABRT,TRAP,ILL)");

    @autoreleasepool {
        bootlog("[CSTR] step2: @autoreleasepool 已进入");

        // ── 第二步：读配置（仅文件读取，绝无崩溃风险）──
        @try {
            refresh_config_if_needed();
            bootlog("[CSTR] step3: 配置已读取");
        }
        @catch (NSException *e) {
            char buf[256];
            snprintf(buf, sizeof(buf), "[CSTR] step3-ERR: 读配置异常 %s",
                     [e.reason UTF8String]);
            bootlog(buf);
        }

        // ── 第三步：fishhook C 函数（崩溃恢复，失败则跳过）──
        if (sigsetjmp(g_safe_jmp, 1) == 0) {
            struct rebinding reb[] = {
                {"sysctlbyname", (void *)my_sysctlbyname, (void **)&orig_sysctlbyname},
                {"uname",        (void *)my_uname,        (void **)&orig_uname},
                {"sysctl",       (void *)my_sysctl,       (void **)&orig_sysctl},
                {"getifaddrs",   (void *)my_getifaddrs,   (void **)&orig_getifaddrs},
            };
            rebind_symbols(reb, sizeof(reb) / sizeof(reb[0]));
            bootlog("[CSTR] step4: fishhook C 函数已安装");
        } else {
            bootlog("[CSTR] step4-SKIP: fishhook C 函数崩溃，已跳过");
        }

        // CFPreferences hook（独立崩溃恢复）
        if (sigsetjmp(g_safe_jmp, 1) == 0) {
            bootlog("[CSTR] step5: 开始 CFPreferences hook...");
            void *cfHandle = dlopen(
                "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                RTLD_LAZY);
            if (cfHandle) {
                orig_CFPrefsCopyAppValue = dlsym(cfHandle, "CFPreferencesCopyAppValue");
                if (orig_CFPrefsCopyAppValue) {
                    struct rebinding cfReb[] = {
                        {"CFPreferencesCopyAppValue",
                         (void *)my_CFPrefsCopyAppValue,
                         (void **)&orig_CFPrefsCopyAppValue},
                    };
                    rebind_symbols(cfReb, 1);
                }
                dlclose(cfHandle);
            }
            bootlog("[CSTR] step5: CFPreferences hook 完成");
        } else {
            bootlog("[CSTR] step5-SKIP: CFPreferences hook 崩溃，已跳过");
        }

        // ── 第四步：直接安装 ObjC hooks（constructor 阶段安全，无需延迟）──
        bootlog("[CSTR] step6: 开始安装 ObjC hooks（同步）...");
        install_objc_hooks();
        bootlog("[CSTR] step7: ObjC hooks 已安装");
        start_heartbeat_delayed();
        bootlogf("[CSTR] step8: 全部完成 (enabled=%d)", g_enabled);

        bootlog("[CSTR] constructor 完成");
    }
}

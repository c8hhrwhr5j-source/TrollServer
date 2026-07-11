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

#import <spawn.h>
#import <sys/wait.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

#pragma mark - 全局状态

static BOOL       g_enabled       = YES;
static NSString  *g_productType   = @"iPad14,2";
static NSString  *g_idfvBase      = nil;
static NSTimeInterval g_lastRefresh = 0;

#pragma mark - 辅助工具

/// 用原 IDFV 派生一个 iPad 风格的稳定 UUID（同一设备每次启动相同）
static NSString *derive_ipad_idfv(void) {
    if (g_idfvBase) return g_idfvBase;

    // 获取真实 IDFV — 通过 spoof_identifierForVendor（交换后它指向原始实现）
    NSString *realIDFV = nil;
    @autoreleasepool {
        NSUUID *uuid = [[UIDevice currentDevice] performSelector:@selector(spoof_identifierForVendor)];
        if (uuid && [uuid isKindOfClass:[NSUUID class]]) {
            realIDFV = [uuid UUIDString];
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
    // "iPhone OS" → "iPadOS"
    return g_enabled ? @"iPadOS" : [self spoof_systemName];
}

- (NSString *)spoof_systemVersion {
    // 系统版本号不变（iOS 17 和 iPadOS 17 版本号相同）
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
    // 这个类方法比较特殊，保持返回真实实例，由实例方法处理伪装
    return [self spoof_currentDevice];
}

@end


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

/// dylib 内部定时检测 TrollServer HTTP 是否可达
/// 若连续 3 次不可达，尝试触发 daemon 重启
static NSTimer *g_heartbeatTimer = nil;
static int g_heartbeatMissCount = 0;

static void start_heartbeat(void) {
    if (g_heartbeatTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:120.0
                                                           repeats:YES
                                                             block:^(NSTimer *t) {
            // 每 120 秒尝试访问 TrollServer
            NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:51111/api/spoof"];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.HTTPMethod = @"GET";
            req.timeoutInterval = 3.0;

            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
            [[session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                if (d && !e) {
                    g_heartbeatMissCount = 0;
                } else {
                    g_heartbeatMissCount++;
                    if (g_heartbeatMissCount >= 3) {
                        NSLog(@"[libiPadSpoof] ⚠️ TrollServer 连续 %d 次不可达，尝试重启 daemon",
                              g_heartbeatMissCount);
                        // 尝试通过 launchctl 重启 daemon（posix_spawn 替代 system()）
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
        }];

        // 添加到 common modes 确保滚动时也触发
        [[NSRunLoop mainRunLoop] addTimer:g_heartbeatTimer forMode:NSRunLoopCommonModes];
        // 立即触发一次
        [g_heartbeatTimer fire];
        NSLog(@"[libiPadSpoof] 💓 心跳检测已启动（间隔 120s）");
    });
}


#pragma mark - hook_objc_method 辅助宏

static void hook_objc_method(Class cls, SEL orig, SEL spoof) {
    Method m = class_getInstanceMethod(cls, orig);
    Method n = class_getInstanceMethod(cls, spoof);
    if (m && n) method_exchangeImplementations(m, n);
}

#pragma mark - 构造函数（dylib 被加载时执行）

__attribute__((constructor))
static void spoof_load(void) {
    @autoreleasepool {
        @try {
            refresh_config_if_needed();

        // ── C 函数 Hook（fishhook） ──
        struct rebinding reb[] = {
            {"sysctlbyname", (void *)my_sysctlbyname, (void **)&orig_sysctlbyname},
            {"uname",        (void *)my_uname,        (void **)&orig_uname},
            {"sysctl",       (void *)my_sysctl,       (void **)&orig_sysctl},
            {"getifaddrs",   (void *)my_getifaddrs,   (void **)&orig_getifaddrs},
            {"_dyld_get_image_name", (void *)my_dyld_get_image_name, (void **)&orig_dyld_get_image_name},
        };
        rebind_symbols(reb, sizeof(reb) / sizeof(reb[0]));

        // CFPreferences（MobileGestalt 键值拦截）
        {
            void *cfHandle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
            if (cfHandle) {
                orig_CFPrefsCopyAppValue = dlsym(cfHandle, "CFPreferencesCopyAppValue");
                if (orig_CFPrefsCopyAppValue) {
                    struct rebinding cfReb[] = {
                        {"CFPreferencesCopyAppValue", (void *)my_CFPrefsCopyAppValue,
                         (void **)&orig_CFPrefsCopyAppValue},
                    };
                    rebind_symbols(cfReb, 1);
                }
                dlclose(cfHandle);
            }
        }

        // ── UIDevice 方法 Hook ──
        Class devCls = [UIDevice class];
        hook_objc_method(devCls, @selector(model),                    @selector(spoof_model));
        hook_objc_method(devCls, @selector(localizedModel),           @selector(spoof_localizedModel));
        hook_objc_method(devCls, @selector(userInterfaceIdiom),       @selector(spoof_userInterfaceIdiom));
        hook_objc_method(devCls, @selector(systemName),               @selector(spoof_systemName));
        hook_objc_method(devCls, @selector(systemVersion),            @selector(spoof_systemVersion));
        hook_objc_method(devCls, @selector(name),                     @selector(spoof_name));
        hook_objc_method(devCls, @selector(identifierForVendor),      @selector(spoof_identifierForVendor));

        // UIDevice.currentDevice 类方法
        Method cm = class_getClassMethod(devCls, @selector(currentDevice));
        Method cn = class_getClassMethod(devCls, @selector(spoof_currentDevice));
        if (cm && cn) method_exchangeImplementations(cm, cn);

        // ── NSProcessInfo ──
        hook_objc_method([NSProcessInfo class],
                         @selector(operatingSystemVersionString),
                         @selector(spoof_operatingSystemVersionString));
        hook_objc_method([NSProcessInfo class],
                         @selector(operatingSystemVersion),
                         @selector(spoof_operatingSystemVersion));

        // ── NSMutableURLRequest（UA） ──
        hook_objc_method([NSMutableURLRequest class],
                         @selector(setValue:forHTTPHeaderField:),
                         @selector(spoof_setValue:forHTTPHeaderField:));

        // ── WKWebView customUserAgent ──
        Class wkCls = NSClassFromString(@"WKWebView");
        if (wkCls) {
            hook_objc_method(wkCls, @selector(customUserAgent), @selector(spoof_customUserAgent));
        }

        // ── CTTelephonyNetworkInfo（蜂窝隐藏） ──
        hook_telephony_if_available();

        // ── 后台保活心跳 ──
        start_heartbeat();

        NSLog(@"[libiPadSpoof] ✅ 增强版已加载 (enabled=%d, product=%@, idfv=%@)",
              g_enabled, g_productType, [derive_ipad_idfv() substringToIndex:8]);
        } @catch (NSException *e) {
            NSLog(@"[libiPadSpoof] ❌ 初始化异常: %@ %@", e.name, e.reason);
        }
    }
}

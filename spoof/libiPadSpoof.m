/*
 * libiPadSpoof.m — 注入 QQ / 微信进程的伪装 dylib
 *
 * 原理（TrollStore / 免越狱可行方案）：
 *   在目标 App 进程内，Hook 它读取设备型号的系统 API，返回 iPad 值。
 *   TrollStore 只给 App 加了 skip-library-validation，因此 dylib 只能
 *   影响【被注入的那个 App】本身，无法全局生效 —— 所以必须分别注入 QQ 和微信。
 *
 * Hook 目标：
 *   - sysctlbyname("hw.machine" / "hw.model" / "hw.product")
 *   - uname() -> utsname.machine
 *   - sysctl(CTL_HW, HW_MACHINE / HW_MODEL)
 *   - UIDevice.model / localizedModel / userInterfaceIdiom
 *   - NSMutableURLRequest User-Agent（把 iPhone 字样改写为 iPad，覆盖网络层检测）
 *
 * 配置来源（dylib 启动时及之后每 30s 懒加载一次）：
 *   1) 文件 /var/mobile/Library/Preferences/com.trollserver.spoof.plist
 *   2) 文件 /var/mobile/.trollserver_spoof.plist
 *   3) 回退：HTTP GET http://127.0.0.1:51111/api/spoof （由 TrollServer 提供）
 *
 * 默认【开启】，注入即生效；TrollServer 的开关/型号选择可覆盖。
 * 本 dylib 同时兼容两种注入姿势：
 *   - TrollFools 直接注入「正版」微信/QQ（无需解密 IPA，推荐）
 *   - 手动 insert_dylib 进重签 IPA 后用 TrollStore 安装
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/errno.h>
#import <string.h>
#import <strings.h>
#import "fishhook.h"

#pragma mark - 全局状态

static BOOL      g_enabled     = YES;   // 默认开启：注入即生效（TrollServer 可覆盖关闭）
static NSString *g_productType = @"iPad14,2";
static NSTimeInterval g_lastRefresh = 0;

#pragma mark - 配置读取

static void apply_config(NSDictionary *cfg) {
    if (!cfg) return;
    id en = cfg[@"Enabled"];
    if ([en isKindOfClass:[NSNumber class]]) g_enabled = [en boolValue];
    id pt = cfg[@"ProductType"];
    if ([pt isKindOfClass:[NSString class]] && [pt length] > 0) g_productType = pt;
}

// 通过本地 HTTP 从 TrollServer daemon 读取配置（绕过沙盒文件限制）
static NSDictionary *fetch_config_via_http(void) {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:51111/api/spoof"];
        if (!url) return nil;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"GET";
        req.timeoutInterval = 1.5;
        NSURLResponse *resp = nil;
        NSError *err = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req
                                             returningResponse:&resp
                                                         error:&err];
        if (!data || err) return nil;
        return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
}

static void refresh_config_if_needed(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - g_lastRefresh < 30.0) return;   // 30s 冷却，避免频繁 IO/网络
    g_lastRefresh = now;

    // 1) 优先读文件（TrollServer / daemon 写入，chmod 0644）
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.trollserver.spoof.plist",
        @"/var/mobile/.trollserver_spoof.plist"
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) { apply_config(d); return; }
    }
    // 2) 沙盒读不到文件时，回退到本地 HTTP（TrollServer 常驻服务）
    apply_config(fetch_config_via_http());
}

#pragma mark - C 函数 Hook

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_uname)(struct utsname *) = NULL;
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;

static int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    refresh_config_if_needed();
    if (g_enabled && name && oldp && oldlenp) {
        NSString *n = @(name);
        if ([n isEqualToString:@"hw.machine"] ||
            [n isEqualToString:@"hw.model"]  ||
            [n isEqualToString:@"hw.product"]) {
            const char *val = g_productType.UTF8String;
            size_t need = strlen(val) + 1;
            if (*oldlenp < need) { *oldlenp = need; errno = ENOMEM; return -1; }
            strlcpy((char *)oldp, val, *oldlenp);
            return 0;
        }
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int my_uname(struct utsname *uts) {
    int r = orig_uname(uts);
    refresh_config_if_needed();
    if (g_enabled && uts) {
        strlcpy(uts->machine, g_productType.UTF8String, sizeof(uts->machine));
    }
    return r;
}

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

#pragma mark - Objective-C 方法 Hook

@interface UIDevice (SpoofExt)
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
@end

#pragma mark - User-Agent 伪装（网络层检测）

static NSString *spoof_ua_string(NSString *ua) {
    if (!ua) return ua;
    NSMutableString *s = [ua mutableCopy];
    // 先把 "iPhone14,3" 这种机型号整体替换为目标 iPad 型号
    NSError *e = nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"iPhone[0-9]+,[0-9]+" options:0 error:&e];
    if (re) {
        [re replaceMatchesInString:s options:0
                              range:NSMakeRange(0, [s length])
                           withTemplate:g_productType];
    }
    // 其余零散的 "iPhone" 字样统一改成 "iPad"
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

#pragma mark - 构造函数（dylib 被加载时执行）

__attribute__((constructor))
static void spoof_load(void) {
    refresh_config_if_needed();

    // Hook C 函数
    struct rebinding reb[] = {
        {"sysctlbyname", (void *)my_sysctlbyname, (void **)&orig_sysctlbyname},
        {"uname",        (void *)my_uname,        (void **)&orig_uname},
        {"sysctl",       (void *)my_sysctl,       (void **)&orig_sysctl},
    };
    rebind_symbols(reb, sizeof(reb) / sizeof(reb[0]));

    // Hook UIDevice 方法
    Class c = [UIDevice class];
    SEL origs[] = { @selector(model),
                    @selector(localizedModel),
                    @selector(userInterfaceIdiom) };
    SEL news[] = { @selector(spoof_model),
                   @selector(spoof_localizedModel),
                   @selector(spoof_userInterfaceIdiom) };
    for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(c, origs[i]);
        Method n = class_getInstanceMethod(c, news[i]);
        if (m && n) method_exchangeImplementations(m, n);
    }

    // Hook 网络请求 User-Agent（微信/QQ 常把机型写进 UA 判 iPad）
    Class reqCls = [NSMutableURLRequest class];
    Method rm = class_getInstanceMethod(reqCls, @selector(setValue:forHTTPHeaderField:));
    Method rn = class_getInstanceMethod(reqCls, @selector(spoof_setValue:forHTTPHeaderField:));
    if (rm && rn) method_exchangeImplementations(rm, rn);

    NSLog(@"[libiPadSpoof] loaded (enabled=%d, product=%@)", g_enabled, g_productType);
}

/*
 * libTestBoot.m — 极简启动探针 dylib
 * 不链 UIKit，不做任何 hook，只验证 dylib 能否被 dyld 加载进微信
 *
 * Build #T1: 仅 Foundation，纯粹诊断
 * 查看: /tmp/libTestBoot.log 或 /var/mobile/Documents/libTestBoot.log
 * 或用 Mac: idevicesyslog | grep TestBoot
 */

#import <Foundation/Foundation.h>
#import <signal.h>

// ====================== 诊断日志 ======================
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>

static void tlog(const char *msg) {
    // 尝试写入文件
    const char *paths[] = {
        "/tmp/libTestBoot.log",
        "/var/mobile/Documents/libTestBoot.log",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        int fd = open(paths[i], O_WRONLY|O_CREAT|O_APPEND, 0644);
        if (fd >= 0) {
            write(fd, msg, strlen(msg));
            write(fd, "\n", 1);
            close(fd);
        }
    }
    // 同时输出到 stderr (可通过 idevicesyslog 或 Xcode 查看)
    write(STDERR_FILENO, msg, strlen(msg));
    write(STDERR_FILENO, "\n", 1);
}

static void tlogf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void tlogf(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    tlog(buf);
}

// ====================== +load 探针 ======================
@interface TestBootProbe : NSObject @end
@implementation TestBootProbe
+ (void)load {
    tlog("⚡ [TestBoot] +load 执行成功 - dyld 加载了本 dylib");
}
@end

// ====================== constructor 探针 ======================
__attribute__((constructor))
static void test_boot_ctor(void) {
    tlog("⚡ [TestBoot] constructor 入口");

    // 获取进程名确认运行在哪个 APP
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    tlogf("⚡ [TestBoot] 进程: %s, PID: %d",
          [pi.processName UTF8String] ?: "?",
          pi.processIdentifier);

    // 获取沙盒路径
    NSString *home = NSHomeDirectory();
    tlogf("⚡ [TestBoot] 沙盒: %s", home.UTF8String ?: "?");

    tlog("⚡ [TestBoot] constructor 完成 - 极简 dylib 运行正常！");
}

#!/bin/bash
# ============================================================
#  build_ladder.sh — 渐进式诊断编译，精确定位崩溃点
#
#  从最简到完全，每步加一个功能块
#
#  产物:
#    ladder_01_fishhook.dylib   — 仅 fishhook.c (无任何 hook 安装)
#    ladder_02_fishRun.dylib    — fishhook + C hook 安装代码
#    ladder_03_all.dylib        — 完整版 (arm64 only，排除 arm64e 干扰)
#    ladder_03e_all.dylib       — 完整版 (arm64 + arm64e)
# ============================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="14.0"
FLAGS="-isysroot $SDK -miphoneos-version-min=$MIN_IOS -dynamiclib"

filesize() {
    stat -f%z "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo "?"
}

# ── Ladder 01: 纯 fishhook.c, 无 libiPadSpoof.m, 无任何框架 ──
echo "=== Ladder 01: fishhook only (无 hook, 无 Foundation) ==="
cat > _ladder_min.m << 'CEOF'
#import <stdarg.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>

static void bootlog(const char *msg) {
    const char *td = getenv("TMPDIR");
    char p[512];
    if (td) snprintf(p, sizeof(p), "%sladder_boot.log", td);
    else snprintf(p, sizeof(p), "/tmp/ladder_boot.log");
    int fd = open(p, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd >= 0) { write(fd, msg, strlen(msg)); write(fd, "\n", 1); close(fd); }
    write(STDERR_FILENO, msg, strlen(msg));
    write(STDERR_FILENO, "\n", 1);
}
__attribute__((constructor))
static void ld01_init(void) {
    bootlog("[LD01] fishhook-only dylib loaded OK");
}
CEOF
if clang -arch arm64 $FLAGS fishhook.c _ladder_min.m -o ladder_01_fishhook.dylib; then
    ldid -S ladder_01_fishhook.dylib 2>/dev/null || true
    echo "   ✅ ladder_01_fishhook.dylib ($(filesize ladder_01_fishhook.dylib) bytes)"
else
    echo "   ❌ ladder_01_fishhook.dylib 编译失败"
fi
echo ""

# ── Ladder 02: fishhook + C hooks 安装 (sysctlbyname/uname/getifaddrs) ──
echo "=== Ladder 02: fishhook with C hook install ==="
cat > _ladder_run.m << 'CEOF'
#import <stdarg.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/socket.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>
#import <strings.h>
#import <dlfcn.h>
#import "fishhook.h"

static void bootlog(const char *msg) {
    const char *td = getenv("TMPDIR");
    char p[512];
    if (td) snprintf(p, sizeof(p), "%sladder_boot.log", td);
    else snprintf(p, sizeof(p), "/tmp/ladder_boot.log");
    int fd = open(p, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd >= 0) { write(fd, msg, strlen(msg)); write(fd, "\n", 1); close(fd); }
    write(STDERR_FILENO, msg, strlen(msg));
    write(STDERR_FILENO, "\n", 1);
}

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_uname)(struct utsname *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;

static int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
static int my_uname(struct utsname *u) {
    return orig_uname(u);
}
static int my_getifaddrs(struct ifaddrs **ifap) {
    return orig_getifaddrs(ifap);
}

// 崩溃处理器
static void crash_hdlr(int sig, siginfo_t *info, void *ctx) {
    char buf[128];
    snprintf(buf, sizeof(buf), "[LD02] CRASH sig=%d addr=%p", sig, info ? info->si_addr : NULL);
    bootlog(buf);
    signal(sig, SIG_DFL); raise(sig);
}

@interface Ld02Probe : NSObject @end
@implementation Ld02Probe
+ (void)load { bootlog("[LD02] +load OK"); }
@end

__attribute__((constructor))
static void ld02_init(void) {
    // 安装信号处理器
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_hdlr; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    bootlog("[LD02] constructor entry");

    // 安装 fishhook
    struct rebinding reb[] = {
        {"sysctlbyname", (void *)my_sysctlbyname, (void **)&orig_sysctlbyname},
        {"uname",        (void *)my_uname,        (void **)&orig_uname},
        {"getifaddrs",   (void *)my_getifaddrs,   (void **)&orig_getifaddrs},
    };
    rebind_symbols(reb, sizeof(reb) / sizeof(reb[0]));
    bootlog("[LD02] fishhook C hooks installed OK");
}
CEOF
if clang -arch arm64 $FLAGS -fobjc-arc fishhook.c _ladder_run.m -o ladder_02_fishRun.dylib; then
    ldid -S ladder_02_fishRun.dylib 2>/dev/null || true
    echo "   ✅ ladder_02_fishRun.dylib ($(filesize ladder_02_fishRun.dylib) bytes)"
else
    echo "   ❌ ladder_02_fishRun.dylib 编译失败"
fi
echo ""

# ── Ladder 03: 完整 libiPadSpoof, arm64 only (排除 arm64e 干扰) ──
echo "=== Ladder 03: 完整版, arm64 only (无 UIKit) ==="
if clang -arch arm64 \
      $FLAGS \
      -fobjc-arc \
      -DNO_UIKIT=1 \
      fishhook.c libiPadSpoof.m \
      -framework Foundation \
      -o ladder_03_noUI.dylib; then
    ldid -S ladder_03_noUI.dylib 2>/dev/null || true
    echo "   ✅ ladder_03_noUI.dylib ($(filesize ladder_03_noUI.dylib) bytes)"
else
    echo "   ❌ ladder_03_noUI.dylib 编译失败"
fi
echo ""

# ── Ladder 03e: 完整版 arm64 + arm64e ──
echo "=== Ladder 03e: 完整版, arm64+arm64e (无 UIKit) ==="
if clang -arch arm64 -arch arm64e \
      $FLAGS \
      -fobjc-arc \
      -DNO_UIKIT=1 \
      fishhook.c libiPadSpoof.m \
      -framework Foundation \
      -o ladder_03e_noUI.dylib; then
    ldid -S ladder_03e_noUI.dylib 2>/dev/null || true
    echo "   ✅ ladder_03e_noUI.dylib ($(filesize ladder_03e_noUI.dylib) bytes)"
else
    echo "   ❌ ladder_03e_noUI.dylib 编译失败"
fi

# 清理临时文件
rm -f _ladder_min.m _ladder_run.m

echo ""
echo "=============================="
echo " 诊断测试顺序（每次只注入一个）:"
echo ""
echo " 1️⃣ ladder_01_fishhook.dylib   — fishhook.c 编译产物，无任何 hook 安装"
echo " 2️⃣ ladder_02_fishRun.dylib    — fishhook + C hooks 安装 + Foundation ObjC"
echo " 3️⃣ ladder_03_noUI.dylib       — 完整版, arm64 only, 无 UIKit"
echo " 4️⃣ ladder_03e_noUI.dylib      — 完整版, arm64 + arm64e, 无 UIKit"
echo ""
echo " 日志: Filza 搜索 ladder_boot.log"
echo "=============================="

/**
 * reboot_helper — 直接调用 reboot() syscall 执行全量重启
 * 由 persona-mgmt 以 root 身份 spawn，不依赖 libjailbreak.dylib
 */
#include <unistd.h>

// <sys/reboot.h> 在 iOS SDK 中不存在，手动声明
#define RB_AUTOBOOT 0x400
extern int reboot(int howto);

int main(int argc, char *argv[]) {
    sync();
    reboot(RB_AUTOBOOT);
    return 1;  // 若返回说明失败
}

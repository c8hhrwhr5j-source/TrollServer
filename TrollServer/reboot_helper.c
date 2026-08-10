/**
 * reboot_helper — 直接调用 reboot() syscall 执行全量重启
 * 由 persona-mgmt 以 root 身份 spawn，不依赖 libjailbreak.dylib
 */
#include <unistd.h>
#include <sys/reboot.h>

int main(int argc, char *argv[]) {
    sync();
    reboot(RB_AUTOBOOT);    // 0x400
    return 1;               // 若返回说明失败
}

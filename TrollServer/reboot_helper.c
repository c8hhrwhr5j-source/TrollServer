/**
 * reboot_helper — 由主程序以 root persona spawn，直接调用 reboot(0)
 * 参考: DevelopCubeLab/RebootTools 的实现 (reboot(0))
 * RB_AUTOBOOT = 0 in XNU/Darwin, 不是 0x400
 */
#include <unistd.h>

int main(int argc, char *argv[]) {
    sync();
    reboot(0);          // RB_AUTOBOOT — 完整重启
    return 1;           // 若返回说明失败
}

/**
 * reboot_helper — 以 root persona spawn + com.apple.system.reboot entitlement
 * 真正重启设备。
 *
 * 关键：此二进制在构建时由 ldid2 单独签名，嵌入了 com.apple.system.reboot
 * entitlement。配合 posix_spawn persona root，同时满足两个条件：
 *   1. root 权限（persona-mgmt）
 *   2. reboot entitlement（ldid2 签名）
 *
 * 之前的失败原因：helper 未被签名，AMFI 检查 entitlement 时拒绝 reboot()。
 * 方案 8 (kill SIGKILL) 也失败：现代 iOS 内核保护 launchd 不被 SIGKILL 杀死。
 */
#include <unistd.h>

int main(int argc, char *argv[]) {
    sync();
    reboot(0);          // RB_AUTOBOOT = 0 in XNU — 完整重启
    return 1;           // 若返回说明失败
}

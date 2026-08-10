/**
 * reboot_helper — 杀死 launchd (PID 1) 触发内核 panic → 强制重启
 * 
 * 原理：kill(1, SIGKILL) 杀死 PID 1 (launchd)，XNU 内核检测到 init 进程退出后
 * 触发 kernel panic("init died")，导致设备强制重启。
 * 
 * 为什么不直接调 reboot()：reboot() 需要 com.apple.system.reboot entitlement，
 * TrollStore 的伪签名无法通过 AMFI 校验，最终行为只等于关机。
 * kill(1, SIGKILL) 则完全绕过 entitlement 检查，利用内核 panic 实现重启。
 */
#include <signal.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    sync();
    kill(1, SIGKILL);   // 杀死 launchd → 内核 panic → 真正重启
    return 1;           // 若返回说明失败
}

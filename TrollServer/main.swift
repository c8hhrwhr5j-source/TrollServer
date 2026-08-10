import UIKit

// ============================================================
//  无忧辅助控制 - 脚本控制服务入口
// ============================================================

// reboot() syscall — 需要 com.apple.system.reboot entitlement
@_silgen_name("reboot") func reboot(_ howto: Int32) -> Int32

let args = CommandLine.arguments

// --reboot 自产卵模式：当 spawnAndWait 以 persona=root 重新 spawn 自身二进制
// 时，该新进程会携带主二进制的完整 entitlements（含 com.apple.system.reboot）
// 并以 root 身份直接调用 reboot()，无需外部 helper。
if args.contains("--reboot") {
    sync()
    _ = reboot(0x400)   // RB_AUTOBOOT
    exit(1)             // reboot 失败才走到这里
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    NSStringFromClass(UIApplication.self),
    NSStringFromClass(AppDelegate.self)
)

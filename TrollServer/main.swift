import UIKit
import Foundation

// ============================================================
//  巨魔文件服务入口 - 支持双模式运行
// ============================================================

if CommandLine.arguments.contains("--daemon") {
    // 守护进程模式：无 UI，启动服务 + 看门狗自愈
    print("[TrollServer] Daemon mode starting...")
    let runner = DaemonServerRunner()
    runner.start()
    ServiceWatchdog.shared.startDaemonMode(serverRunner: runner)
    RunLoop.main.run()
} else {
    // 普通应用模式：带 UI
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        NSStringFromClass(UIApplication.self),
        NSStringFromClass(AppDelegate.self)
    )
}

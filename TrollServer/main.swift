import UIKit
import Foundation

// ============================================================
//  巨魔文件服务入口 - 支持双模式运行
// ============================================================

if CommandLine.arguments.contains("--daemon") {
    // 守护进程模式：无 UI，直接启动服务器
    DaemonServerRunner().start()
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

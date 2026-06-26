import UIKit
import Foundation

// ============================================================
//  巨魔文件服务入口 - 支持双模式运行
// ============================================================

// 守护进程全局异常处理器 — 捕获 Objective-C/Swift 异常防止进程 crash
private func setupDaemonExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        print("[TrollServer] FATAL: Uncaught exception: \(exception.name) - \(exception.reason ?? "?")")
        print("[TrollServer] Call stack: \(exception.callStackSymbols.joined(separator: "\n"))")
        // 不调用 exit，让 launchd 根据 KeepAlive 决定是否重启
        // 短暂延迟后 exit，避免 launchd 立即重拉造成快速循环
        Thread.sleep(forTimeInterval: 3.0)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--daemon") {
    // 守护进程模式：无 UI，启动服务 + 看门狗自愈
    print("[TrollServer] Daemon mode starting (PID=\(getpid()))...")
    
    setupDaemonExceptionHandler()
    
    let runner = DaemonServerRunner()
    
    // 启动服务（启动失败不退出，交给 Watchdog 修复）
    runner.startDaemon()
    ServiceWatchdog.shared.startDaemonMode(serverRunner: runner)
    
    // 保持进程存活
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

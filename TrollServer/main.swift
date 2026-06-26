import UIKit
import Foundation

// ============================================================
//  巨魔文件服务入口 - 支持双模式运行
// ============================================================

// 守护进程全局异常处理器 — 捕获 Objective-C 异常防止进程 crash
private func setupDaemonExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let logPath = "/var/mobile/Library/Logs/trollserver_crash.log"
        let msg = "[\(Date())] FATAL: Uncaught exception: \(exception.name) - \(exception.reason ?? "?")\n"
        try? msg.data(using: .utf8)?.appendTo(file: logPath)
        let stack = exception.callStackSymbols.joined(separator: "\n")
        try? (stack + "\n---\n").data(using: .utf8)?.appendTo(file: logPath)
        print("[TrollServer] FATAL: \(exception.name) - \(exception.reason ?? "?")")
        // 延迟退出，避免 launchd 快速重拉
        Thread.sleep(forTimeInterval: 5.0)
        exit(EXIT_FAILURE)
    }
}

// Data 扩展：追加到文件
extension Data {
    func appendTo(file path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fh.seekToEndOfFile()
            fh.write(self)
            fh.closeFile()
        } else {
            try write(to: URL(fileURLWithPath: path))
        }
    }
}

if CommandLine.arguments.contains("--daemon") {
    // 守护进程模式：无 UI，启动服务 + 看门狗自愈
    let logPath = "/var/mobile/Library/Logs/trollserver.log"
    try? "[\(Date())] Daemon mode starting (PID=\(getpid()))\n".data(using: .utf8)?.appendTo(file: logPath)
    print("[TrollServer] Daemon mode starting (PID=\(getpid()))...")
    
    setupDaemonExceptionHandler()
    
    // 确保日志目录存在
    try? FileManager.default.createDirectory(atPath: "/var/mobile/Library/Logs", withIntermediateDirectories: true)
    
    let runner = DaemonServerRunner()
    
    // 启动服务（启动失败不退出，交给 Watchdog 修复）
    runner.startDaemon()
    ServiceWatchdog.shared.startDaemonMode(serverRunner: runner)
    
    // 保持进程存活（带心跳日志，降低频率减少开销）
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
        autoreleasepool {
            let uptime = ProcessInfo.processInfo.systemUptime
            print("[TrollServer] Daemon heartbeat (uptime=\(Int(uptime))s)")
        }
    }
    
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

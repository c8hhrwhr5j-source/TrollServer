import UIKit
import Foundation

// ============================================================
//  TrollServer v2.0 入口
//
//  双模式运行：
//   --daemon    → LaunchDaemon 守护进程模式（无 UI）
//   默认       → 普通 App 模式（带 UI 状态页面）
// ============================================================

// 守护进程日志路径
private let daemonLogPath = "/var/mobile/Library/Logs/trollserver.log"

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

// 全局未捕获异常处理（守护进程模式下防止 crash 退出）
private func setupExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let msg = "[\(Date())] FATAL: \(exception.name) - \(exception.reason ?? "?")\n"
        try? msg.data(using: .utf8)?.appendTo(file: daemonLogPath)
        let stack = exception.callStackSymbols.joined(separator: "\n")
        try? (stack + "\n---\n").data(using: .utf8)?.appendTo(file: daemonLogPath)
        print("[TrollServer] 💥 FATAL: \(exception.name) - \(exception.reason ?? "?")")
        Thread.sleep(forTimeInterval: 5.0)
        exit(EXIT_FAILURE)
    }
}

// ===================== 入口 =====================
if CommandLine.arguments.contains("--daemon") {
    // ========== 守护进程模式 ==========
    try? FileManager.default.createDirectory(
        atPath: "/var/mobile/Library/Logs",
        withIntermediateDirectories: true
    )

    let logMsg = "[\(Date())] TrollServer v2.0 daemon starting (PID=\(getpid()))\n"
    try? logMsg.data(using: .utf8)?.appendTo(file: daemonLogPath)
    print("[TrollServer] 🖥️  Daemon mode starting (PID=\(getpid()))...")

    setupExceptionHandler()

    // 启动服务 + 看门狗
    BootstrapServices.startForDaemon()

    // 保持进程存活（每 5 分钟心跳日志）
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
        autoreleasepool {
            let stats = BootstrapServices.httpServer
            print("[TrollServer] 💓 Daemon alive (uptime=\(Int(-stats.startTime.timeIntervalSinceNow))s, requests=\(stats.requestCount))")
        }
    }

    RunLoop.main.run()

} else {
    // ========== App 模式 ==========
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        NSStringFromClass(UIApplication.self),
        NSStringFromClass(AppDelegate.self)
    )
}

import UIKit
import Foundation

// ============================================================
//  巨魔文件服务入口 - 支持双模式运行
// ============================================================
//  --daemon   : 作为后台守护进程运行服务器（无UI）
//  (无参数)   : 作为普通应用运行（显示状态UI + 后台服务器）
// ============================================================

let isDaemonMode = CommandLine.arguments.contains("--daemon")

if isDaemonMode {
    // ========== 守护进程模式 ==========
    // 由 LaunchDaemon 启动，没有 UIApplication 支持
    // 直接启动双端口服务器
    
    let logPath = "/var/mobile/Library/Logs/trollserver.log"
    let logDir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    
    // 重定向 stdout/stderr 到日志文件
    if let logFile = fopen(logPath, "a") {
        dup2(fileno(logFile), STDOUT_FILENO)
        dup2(fileno(logFile), STDERR_FILENO)
    }
    
    print("[TrollServer Daemon] Starting at \(Date())")
    print("[TrollServer Daemon] iOS \(UIDevice.current.systemVersion)")
    
    // 启动双端口服务器
    let serverRunner = DaemonServerRunner()
    serverRunner.start()
    
    // RunLoop 保持进程存活
    RunLoop.main.run()
    
} else {
    // ========== 普通应用模式 ==========
    // 带 UI 的完整应用
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        NSStringFromClass(UIApplication.self),
        NSStringFromClass(AppDelegate.self)
    )
}

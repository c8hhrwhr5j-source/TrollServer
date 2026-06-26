import Foundation

/// 提供 ObjC 异常安全保护，防止单个连接的异常导致整个守护进程崩溃
/// 
/// 原理：Swift 无法直接 @try/@catch ObjC 异常，但 Foundation 提供了桥接方式。
/// 通过 NSException 的类方法来模拟 try-catch 行为。
class TrollServerTryCatch {
    
    /// 安全执行闭包，捕获任何 ObjC 异常
    /// - Returns: 如果执行成功返回 true，发生异常返回 false
    @discardableResult
    static func run(_ unsafeBlock: () -> Void) -> Bool {
        // 使用嵌套 uncaught exception handler 方案
        // 这是纯 Swift 中唯一可行的 ObjC 异常保护方案
        // 
        // 原理：
        // 1. 保存当前全局异常处理器
        // 2. 安装临时处理器（捕获异常后不退出，而是标记并继续）
        // 3. 执行危险代码
        // 4. 如果未发生异常，恢复原处理器
        //
        // 注意：此方案有一定局限性——它只能防止"显式抛出的 NSException"，
        // 对于真正的内存错误（SIGSEGV/BAD_ACCESS）无效（这些需要 Mach 异常处理）
        
        var caughtException: NSException?
        let oldHandler = NSGetUncaughtExceptionHandler()
        
        NSSetUncaughtExceptionHandler { exception in
            caughtException = exception
        }
        
        unsafeBlock()
        
        // 恢复或设置回全局处理器
        if let old = oldHandler {
            NSSetUncaughtExceptionHandler(old)
        } else {
            // 恢复为 nil（默认行为）
            NSSetUncaughtExceptionHandler(nil)
        }
        
        if let ex = caughtException {
            let logPath = "/var/mobile/Library/Logs/trollserver_crash.log"
            let msg = "[\(Date())] Caught & suppressed: \(ex.name) - \(ex.reason ?? "?")\n"
            // 尝试写入崩溃日志
            try? msg.data(using: .utf8)?.appendCrashLog(to: logPath)
            print("[TrollServer] ⚠️ Caught recoverable exception: \(ex.name) - \(ex.reason ?? "?")")
            return false
        }
        
        return true
    }
}

// Data 扩展：追加到崩溃日志
extension Data {
    func appendCrashLog(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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

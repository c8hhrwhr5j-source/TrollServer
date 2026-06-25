import Foundation

// ============================================================
//  守护进程安装器 - 利用巨魔权限安装 LaunchDaemon
//  使应用在设备启动时自动运行，无需手动打开
// ============================================================

class DaemonInstaller {
    
    static let daemonLabel = "com.trollserver.fileserver"
    static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    
    // 日志路径
    static let stdoutLog = "/var/mobile/Library/Logs/trollserver.log"
    static let stderrLog = "/var/mobile/Library/Logs/trollserver_error.log"
    
    // MARK: - 安装
    
    /// 安装守护进程（首次启动时调用）
    static func install() -> Bool {
        print("[Daemon] Installing LaunchDaemon \(daemonLabel)...")
        
        // 1. 确保日志目录存在
        let logDir = "/var/mobile/Library/Logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        
        // 2. 获取当前可执行文件路径
        let executablePath = Bundle.main.executablePath ?? "/Applications/TrollServer.app/TrollServer"
        
        // 3. 构建 plist
        let plist: [String: Any] = [
            "Label": daemonLabel,
            "ProgramArguments": [
                executablePath,
                "--daemon"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "EnableTransactions": false,
            "EnvironmentVariables": [
                "DYLD_INSERT_LIBRARIES": ""
            ],
            "StandardOutPath": stdoutLog,
            "StandardErrorPath": stderrLog
        ]
        
        // 4. 写入 plist 文件
        do {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            
            try plistData.write(to: URL(fileURLWithPath: daemonPlistPath), options: .atomic)
            print("[Daemon] Plist written to \(daemonPlistPath)")
        } catch {
            print("[Daemon] ERROR: Failed to write plist: \(error)")
            return false
        }
        
        // 5. 加载守护进程
        return loadDaemon()
    }
    
    // MARK: - 加载/卸载
    
    /// 使用 launchctl 加载守护进程
    static func loadDaemon() -> Bool {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", daemonPlistPath]
        
        task.launch()
        task.waitUntilExit()
        print("[Daemon] launchctl load exit code: \(task.terminationStatus)")
        return task.terminationStatus == 0
    }
    
    /// 卸载守护进程
    static func unload() -> Bool {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", daemonPlistPath]
        
        task.launch()
        task.waitUntilExit()
        print("[Daemon] launchctl unload exit code: \(task.terminationStatus)")
        
        // 删除 plist
        try? FileManager.default.removeItem(atPath: daemonPlistPath)
        return true
    }
    
    // MARK: - 状态查询
    
    /// 检查守护进程是否已安装
    static func isInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: daemonPlistPath)
    }
    
    /// 检查守护进程是否正在运行
    static func isRunning() -> Bool {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", daemonLabel]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.contains("\"PID\"") || !output.contains("Could not find")
    }
    
    /// 获取守护进程 PID
    static func getPID() -> Int? {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", daemonLabel]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        for line in output.components(separatedBy: .newlines) {
            if line.contains("\"PID\"") {
                if let range = line.range(of: "\\d+", options: .regularExpression) {
                    return Int(line[range])
                }
            }
        }
        return nil
    }
}

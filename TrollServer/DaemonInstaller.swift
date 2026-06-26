import Foundation

// ============================================================
//  守护进程安装器 - 利用巨魔权限安装 LaunchDaemon
//  使应用在设备启动时自动运行，无需手动打开
// ============================================================

/// iOS 兼容的进程启动器（替代 macOS 专用 Process）
private func launchTask(bin: String, args: [String], capture: Bool = false) -> (exitCode: Int32, output: String?) {
    let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    
    var pid: pid_t = 0
    var childAttrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&childAttrs)
    defer { if childAttrs != nil { posix_spawnattr_destroy(&childAttrs) } }
    
    let status: Int32
    if capture {
        var pipeFD: [Int32] = [0, 0]
        pipe(&pipeFD)
        defer { close(pipeFD[0]); close(pipeFD[1]) }
        
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) } }
        
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[1])
        
        status = posix_spawn(&pid, bin, &fileActions, &childAttrs,
                             argv, environ)
        close(pipeFD[1])
        
        var output: String? = nil
        if status == 0 {
            var outData = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(pipeFD[0], &buf, buf.count)
                if n <= 0 { break }
                outData.append(contentsOf: buf[0..<n])
            }
            output = String(data: outData, encoding: .utf8)
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            close(pipeFD[0])
            // 手动计算 exit code: WEXITSTATUS = (st >> 8) & 0xFF
            let exitCode: Int32 = ((st >> 8) & 0xFF)
            return (exitCode, output)
        }
        close(pipeFD[0])
        return (-1, nil)
    } else {
        status = posix_spawn(&pid, bin, nil, &childAttrs,
                             argv, environ)
        if status == 0 {
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            // 手动计算 exit code
            let exitCode: Int32 = ((st >> 8) & 0xFF)
            return (exitCode, nil)
        }
        return (-1, nil)
    }
}

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
        let result = launchTask(bin: "/bin/launchctl", args: ["load", daemonPlistPath])
        print("[Daemon] launchctl load exit code: \(result.exitCode)")
        return result.exitCode == 0
    }
    
    /// 卸载守护进程
    static func unload() -> Bool {
        let result = launchTask(bin: "/bin/launchctl", args: ["unload", daemonPlistPath])
        print("[Daemon] launchctl unload exit code: \(result.exitCode)")
        
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
        let result = launchTask(bin: "/bin/launchctl", args: ["list", daemonLabel], capture: true)
        let output = result.output ?? ""
        // launchctl list 如果找到服务会输出包含 PID 的行，格式如: "PID\tStatus\tLabel"
        // 如果找不到服务则输出 "Could not find specified service"
        if output.contains("Could not find") {
            return false
        }
        // 检查第一列是否为有效数字 PID（排除错误消息中含 "PID" 字符串的误判）
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("Could not find") {
                let firstColumn = trimmed.components(separatedBy: "\t").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if let _ = Int(firstColumn) {
                    return true
                }
            }
        }
        return false
    }
    
    /// 获取守护进程 PID
    static func getPID() -> Int? {
        let result = launchTask(bin: "/bin/launchctl", args: ["list", daemonLabel], capture: true)
        let output = result.output ?? ""
        
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

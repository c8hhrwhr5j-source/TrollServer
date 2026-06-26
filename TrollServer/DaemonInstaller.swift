import Foundation

// ============================================================
//  守护进程安装器 - 利用巨魔权限安装 LaunchDaemon
//  使应用在设备启动时自动运行，无需手动打开
//  支持 rootless 和传统越狱环境
// ============================================================

/// iOS 兼容的进程启动器（替代 macOS 专用 Process）
/// 注意：capture 模式下会同时捕获 stdout 和 stderr
private func launchTask(bin: String, args: [String], capture: Bool = false) -> (exitCode: Int32, output: String?) {
    let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    
    var pid: pid_t = 0
    var childAttrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&childAttrs)
    defer { if childAttrs != nil { posix_spawnattr_destroy(&childAttrs) } }
    
    if capture {
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else {
            return (-1, nil)
        }
        // 不再用 defer 关闭 pipeFD，改为在分支中精确关闭，避免 double-close
        
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) } }
        
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[1])
        
        let spawnResult = posix_spawn(&pid, bin, &fileActions, &childAttrs,
                                      argv, environ)
        close(pipeFD[1])  // 关闭写端，让子进程可以退出
        
        if spawnResult != 0 {
            close(pipeFD[0])  // 关闭读端
            return (-1, nil)
        }
        
        var outData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(pipeFD[0], &buf, buf.count)
            if n <= 0 { break }
            outData.append(contentsOf: buf[0..<n])
        }
        close(pipeFD[0])  // 读完后关闭读端
        
        let output = String(data: outData, encoding: .utf8)
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        let exitCode: Int32 = ((st >> 8) & 0xFF)
        return (exitCode, output)
    } else {
        let spawnResult = posix_spawn(&pid, bin, nil, &childAttrs,
                                      argv, environ)
        if spawnResult != 0 {
            return (-1, nil)
        }
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        let exitCode: Int32 = ((st >> 8) & 0xFF)
        return (exitCode, nil)
    }
}

class DaemonInstaller {
    
    static let daemonLabel = "com.trollserver.fileserver"
    
    /// plist 路径 - 支持传统 jailbreak 和 rootless 两种路径
    static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let rootlessPlistPath = "/var/jb/Library/LaunchDaemons/\(daemonLabel).plist"
    
    /// 实际使用的 plist 路径（优先传统路径，fallback rootless）
    static var activePlistPath: String {
        if FileManager.default.fileExists(atPath: daemonPlistPath) {
            return daemonPlistPath
        }
        if FileManager.default.fileExists(atPath: rootlessPlistPath) {
            return rootlessPlistPath
        }
        // 默认尝试传统路径
        return daemonPlistPath
    }
    
    // 日志路径
    static let stdoutLog = "/var/mobile/Library/Logs/trollserver.log"
    static let stderrLog = "/var/mobile/Library/Logs/trollserver_error.log"
    
    // MARK: - 安装
    
    /// 安装守护进程（首次启动时调用）
    /// 依次尝试传统路径和 rootless 路径
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
        
        // 4. 序列化 plist
        let plistData: Data
        do {
            plistData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        } catch {
            print("[Daemon] ERROR: Failed to serialize plist: \(error)")
            return false
        }
        
        // 5. 依次尝试写入到传统路径和 rootless 路径
        let pathsToTry = [daemonPlistPath, rootlessPlistPath]
        var writeSuccess = false
        
        for plistPath in pathsToTry {
            // 确保父目录存在
            let parentDir = (plistPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            
            do {
                try plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                print("[Daemon] Plist written to \(plistPath)")
                writeSuccess = true
                break
            } catch {
                print("[Daemon] Failed to write to \(plistPath): \(error)")
            }
        }
        
        if !writeSuccess {
            print("[Daemon] ERROR: Could not write plist to any path")
            return false
        }
        
        // 6. 加载守护进程（使用成功写入的路径）
        return loadDaemon()
    }
    
    // MARK: - 加载/卸载
    
    /// 使用 launchctl 加载守护进程
    static func loadDaemon() -> Bool {
        let plistPath = activePlistPath
        let result = launchTask(bin: "/bin/launchctl", args: ["load", plistPath])
        print("[Daemon] launchctl load \(plistPath) exit code: \(result.exitCode)")
        if result.exitCode != 0 {
            // 尝试 rootless 路径
            let altPath = (plistPath == daemonPlistPath) ? rootlessPlistPath : daemonPlistPath
            if FileManager.default.fileExists(atPath: altPath) {
                let result2 = launchTask(bin: "/bin/launchctl", args: ["load", altPath])
                print("[Daemon] launchctl load \(altPath) exit code: \(result2.exitCode)")
                return result2.exitCode == 0
            }
        }
        return result.exitCode == 0
    }
    
    /// 卸载守护进程
    static func unload() -> Bool {
        let plistPath = activePlistPath
        let result = launchTask(bin: "/bin/launchctl", args: ["unload", plistPath])
        print("[Daemon] launchctl unload exit code: \(result.exitCode)")
        
        // 删除所有可能的 plist 文件
        for path in [daemonPlistPath, rootlessPlistPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
        return true
    }
    
    // MARK: - 统一状态查询（核心修复）
    
    /// 守护进程完整状态
    struct DaemonStatus {
        let installed: Bool
        let running: Bool
        let pid: Int?
    }
    
    /// 单次 launchctl 调用获取完整状态
    /// launchctl list <label> 的输出格式（iOS 15+ 属性列表格式）：
    ///   - 未找到 : "Could not find specified service"
    ///   - 已安装但未运行 : { ... "Label" = "com.trollserver.fileserver"; ... }
    ///   - 正在运行      : { ... "PID" = 12345; ... }
    static func getStatus() -> DaemonStatus {
        let result = launchTask(bin: "/bin/launchctl", args: ["list", daemonLabel], capture: true)
        let output = result.output ?? ""
        
        // 检查是否未找到服务
        if output.contains("Could not find") {
            // launchctl 未找到，fallback 到文件检查
            let fileExists = FileManager.default.fileExists(atPath: daemonPlistPath)
                          || FileManager.default.fileExists(atPath: rootlessPlistPath)
            if fileExists {
                print("[Daemon] plist file exists but launchctl reports not found (may need load)")
            }
            return DaemonStatus(installed: fileExists, running: false, pid: nil)
        }
        
        // 解析属性列表格式输出，查找 "PID" = <number>;
        // 格式: \t"PID" = 12345;
        var pid: Int? = nil
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"PID\"") || trimmed.hasPrefix("PID") {
                // 解析 "PID" = 12345; 或 PID = 12345;
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let valueStr = parts[1]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
                    if let pidValue = Int(valueStr), pidValue > 0 {
                        pid = pidValue
                        break
                    }
                }
            }
        }
        
        let running = pid != nil
        print("[Daemon] status: installed=true, running=\(running), pid=\(pid?.description ?? "nil")")
        return DaemonStatus(installed: true, running: running, pid: pid)
    }
    
    // MARK: - 便捷查询方法（兼容旧接口）
    
    /// 检查守护进程是否已安装
    static func isInstalled() -> Bool {
        // 先检查文件是否存在（快速路径）
        if FileManager.default.fileExists(atPath: daemonPlistPath)
            || FileManager.default.fileExists(atPath: rootlessPlistPath) {
            return true
        }
        // 再通过 launchctl 确认
        return getStatus().installed
    }
    
    /// 检查守护进程是否正在运行
    static func isRunning() -> Bool {
        return getStatus().running
    }
    
    /// 获取守护进程 PID
    static func getPID() -> Int? {
        return getStatus().pid
    }
}

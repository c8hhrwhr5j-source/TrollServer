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
    var childAttrs: posix_spawnattr_t = posix_spawnattr_t()
    posix_spawnattr_init(&childAttrs)
    defer { posix_spawnattr_destroy(&childAttrs) }
    
    if capture {
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else {
            return (-1, nil)
        }
        
        var fileActions: posix_spawn_file_actions_t = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[1])
        
        let spawnResult = posix_spawn(&pid, bin, &fileActions, &childAttrs,
                                      argv, environ)
        close(pipeFD[1])
        
        if spawnResult != 0 {
            close(pipeFD[0])
            return (-1, nil)
        }
        
        var outData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(pipeFD[0], &buf, buf.count)
            if n <= 0 { break }
            outData.append(contentsOf: buf[0..<n])
        }
        close(pipeFD[0])
        
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
    
    /// 安装或更新守护进程，并确保其正在运行（含端口检测与自动重装）
    static func ensureRunning() -> Bool {
        _ = syncPlistIfNeeded()
        
        let status = getStatus()
        if status.running && LocalPortChecker.isOpen(51111) && LocalPortChecker.isOpen(8989) {
            return true
        }
        
        // 进程在但端口未监听 → 强制重载
        if status.running {
            print("[Daemon] Process alive but ports down, force reload...")
            _ = loadDaemon()
            Thread.sleep(forTimeInterval: 0.8)
            if getStatus().running && LocalPortChecker.isOpen(51111) {
                return true
            }
        }
        
        if isInstalled() {
            if loadDaemon() { return verifyPorts() }
            print("[Daemon] load failed, reinstalling plist...")
            if install() { return verifyPorts() }
        }
        
        if install() { return verifyPorts() }
        return false
    }
    
    /// 若 plist 中可执行路径与当前不一致则自动更新（应用重装/更新后）
    @discardableResult
    static func syncPlistIfNeeded() -> Bool {
        let currentExe = Bundle.main.executablePath ?? ""
        guard !currentExe.isEmpty else { return false }
        
        for path in [daemonPlistPath, rootlessPlistPath] {
            guard FileManager.default.fileExists(atPath: path),
                  let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let args = plist["ProgramArguments"] as? [String],
                  let existingExe = args.first else { continue }
            
            if existingExe != currentExe {
                print("[Daemon] Executable path changed, auto-updating plist")
                print("[Daemon]   old: \(existingExe)")
                print("[Daemon]   new: \(currentExe)")
                return install()
            }
        }
        return false
    }
    
    private static func verifyPorts() -> Bool {
        Thread.sleep(forTimeInterval: 0.5)
        return getStatus().running
            && LocalPortChecker.isOpen(51111)
            && LocalPortChecker.isOpen(8989)
    }
    
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
            "StartOnMount": true,
            "KeepAlive": [
                "SuccessfulExit": false
            ],
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
    
    /// 使用 launchctl 加载守护进程（兼容 iOS 15+ bootstrap 与传统 load）
    static func loadDaemon() -> Bool {
        let paths = [daemonPlistPath, rootlessPlistPath].filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else {
            print("[Daemon] No plist found to load")
            return false
        }
        
        for plistPath in paths {
            // iOS 15+ 推荐 bootstrap
            let bootstrap = launchTask(bin: "/bin/launchctl", args: ["bootstrap", "system", plistPath])
            print("[Daemon] launchctl bootstrap system \(plistPath) exit: \(bootstrap.exitCode)")
            if bootstrap.exitCode == 0 {
                Thread.sleep(forTimeInterval: 0.5)
                if getStatus().running { return true }
            }
            
            // enable + kickstart
            let enable = launchTask(bin: "/bin/launchctl", args: ["enable", "system/\(daemonLabel)"])
            print("[Daemon] launchctl enable system/\(daemonLabel) exit: \(enable.exitCode)")
            let kick = launchTask(bin: "/bin/launchctl", args: ["kickstart", "-k", "system/\(daemonLabel)"])
            print("[Daemon] launchctl kickstart exit: \(kick.exitCode)")
            if kick.exitCode == 0 {
                Thread.sleep(forTimeInterval: 0.5)
                if getStatus().running { return true }
            }
            
            // 传统 load（旧版 iOS / rootless）
            let load = launchTask(bin: "/bin/launchctl", args: ["load", "-w", plistPath])
            print("[Daemon] launchctl load -w \(plistPath) exit: \(load.exitCode)")
            if load.exitCode == 0 {
                Thread.sleep(forTimeInterval: 0.5)
                if getStatus().running { return true }
            }
        }
        
        return getStatus().running
    }
    
    /// 卸载守护进程
    static func unload() -> Bool {
        _ = launchTask(bin: "/bin/launchctl", args: ["bootout", "system", daemonLabel])
        _ = launchTask(bin: "/bin/launchctl", args: ["unload", activePlistPath])
        
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

import Foundation
import Darwin

// ============================================================
//  DaemonBootstrap - IPA 安装后自动注册为用户 LaunchAgent
//
//  改用用户 LaunchAgent（而非系统 LaunchDaemon），
//  所有路径在 /var/mobile/ 下，mobile 用户有完整读写权限，
//  无需 root！巨魔安装的 App 直接就能自动安装 daemon。
//
//  200 台手机部署流程：
//   1. 构建包含此模块的 IPA
//   2. 通过巨魔批量安装到所有手机
//   3. 巨魔安装后打开一次 App（自动安装 daemon）
//   4. 完成——此后永久在线
// ============================================================

enum DaemonBootstrap {

    static let daemonBinaryPath = "/var/mobile/.trollserverd"
    static let plistPath = "/var/mobile/Library/LaunchAgents/com.trollserver.daemon.plist"
    static let logDir = "/var/mobile/Library/Logs"

    private static let markerFile = "/var/mobile/Library/Logs/.trollserver_daemon_installed"

    /// 检查并安装 daemon。幂等，多次调用无副作用。
    /// - Returns: true 表示 daemon 已就绪
    static func installIfNeeded() -> Bool {
        // 快速路径：已安装标记文件存在
        if FileManager.default.fileExists(atPath: markerFile) {
            return true
        }

        // 已安装但标记丢了？修正
        if FileManager.default.fileExists(atPath: daemonBinaryPath),
           FileManager.default.fileExists(atPath: plistPath) {
            createMarker()
            return true
        }

        print("[DaemonBootstrap] 🔧 检测到首次运行，正在安装系统 daemon...")

        // 1. 获取自身路径
        guard let selfPath = Bundle.main.executablePath else {
            print("[DaemonBootstrap] ❌ 无法获取自身路径")
            return false
        }

        // 2. 创建必要目录
        let launchAgentsDir = "/var/mobile/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: launchAgentsDir,
                                                  withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logDir,
                                                  withIntermediateDirectories: true)

        // 3. 复制自身
        do {
            if FileManager.default.fileExists(atPath: daemonBinaryPath) {
                try FileManager.default.removeItem(atPath: daemonBinaryPath)
            }
            try FileManager.default.copyItem(atPath: selfPath, toPath: daemonBinaryPath)
            chmod(daemonBinaryPath, 0o755)
            print("[DaemonBootstrap] ✅ 二进制已安装: \(daemonBinaryPath)")
        } catch {
            print("[DaemonBootstrap] ❌ 复制二进制失败: \(error)")
            return false
        }

        // 4. 写入 LaunchAgent plist
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.trollserver.daemon</string>
            <key>Program</key>
            <string>\(daemonBinaryPath)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonBinaryPath)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(logDir)/trollserver.log</string>
            <key>StandardErrorPath</key>
            <string>\(logDir)/trollserver_err.log</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>/var/mobile</string>
            </dict>
        </dict>
        </plist>
        """

        do {
            try plistXML.write(toFile: plistPath, atomically: true, encoding: .utf8)
            chmod(plistPath, 0o644)
            print("[DaemonBootstrap] ✅ plist 已安装: \(plistPath)")
        } catch {
            print("[DaemonBootstrap] ❌ 写入 plist 失败: \(error)")
            return false
        }

        // 5. 加载 daemon（launchctl）
        let loadResult = shell("launchctl load \(plistPath)")
        if loadResult == 0 {
            print("[DaemonBootstrap] ✅ launchctl 加载成功")
        } else {
            // 可能已经加载过，不算失败
            print("[DaemonBootstrap] ℹ️ launchctl 返回 \(loadResult)，可能已加载")
        }

        createMarker()
        print("[DaemonBootstrap] 🎉 系统 daemon 安装完成！重启后自动运行")
        return true
    }

    /// 手动拉起 daemon（不阻塞，App 退出后 daemon 独占端口）
    static func loadDaemon() {
        guard FileManager.default.fileExists(atPath: daemonBinaryPath),
              FileManager.default.fileExists(atPath: plistPath) else {
            print("[DaemonBootstrap] ⚠️ daemon 未安装，无法加载")
            return
        }
        let result = shell("launchctl load \(plistPath) 2>/dev/null")
        print("[DaemonBootstrap] 🔄 手动拉起 daemon (launchctl 返回 \(result))")
    }

    /// 卸载 daemon（保留此能力以备将来使用）
    static func uninstall() {
        _ = shell("launchctl unload \(plistPath) 2>/dev/null")
        try? FileManager.default.removeItem(atPath: daemonBinaryPath)
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: markerFile)
        print("[DaemonBootstrap] 🗑️  daemon 已卸载")
    }

    // MARK: - Shell 执行（posix_spawn 替代 system()，兼容 iOS）
    @discardableResult
    private static func shell(_ command: String) -> Int32 {
        var pid: pid_t = 0
        let cArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"),
            strdup("-c"),
            strdup(command),
            nil
        ]
        defer { cArgs.forEach { $0.map { free($0) } } }

        let ret = posix_spawn(&pid, "/bin/sh", nil, nil, cArgs, nil)
        guard ret == 0 else {
            return ret
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // WEXITSTATUS 宏在 iOS 不可用，直接位运算提取
        return (status >> 8) & 0xFF
    }

    private static func createMarker() {
        try? "installed".write(toFile: markerFile, atomically: true, encoding: .utf8)
    }
}

import Foundation
import UIKit
import Network

// ============================================================
//  服务看门狗 - 自动检测并修复守护进程 / 端口服务
//  无需用户手动点击「重载守护进程」
// ============================================================

enum LocalPortChecker {
    
    /// 检测本机 TCP 端口是否在监听（超时 1 秒）
    static func isOpen(_ port: UInt16, host: String = "127.0.0.1") -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var open = false
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                open = true
                conn.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                conn.cancel()
                semaphore.signal()
            default:
                break
            }
        }
        
        conn.start(queue: .global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + 1.0)
        if open { conn.cancel() }
        return open
    }
}

class ServiceWatchdog {
    
    static let shared = ServiceWatchdog()
    
    private let queue = DispatchQueue(label: "com.trollserver.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isHealing = false
    private var lastHealTime: Date = .distantPast
    private let healCooldown: TimeInterval = 8
    private let checkInterval: TimeInterval = 12
    
    private weak var serverRunner: DaemonServerRunner?
    private var isDaemonMode = false
    
    private init() {}
    
    // MARK: - 启动（应用模式）
    
    func startAppMode(serverRunner: DaemonServerRunner) {
        isDaemonMode = false
        self.serverRunner = serverRunner
        startTimer()
        queue.async { [weak self] in self?.healIfNeeded(force: true) }
        print("[Watchdog] App mode started (interval \(Int(checkInterval))s)")
    }
    
    // MARK: - 启动（守护进程模式）
    
    func startDaemonMode(serverRunner: DaemonServerRunner) {
        isDaemonMode = true
        self.serverRunner = serverRunner
        startTimer()
        queue.async { [weak self] in self?.healDaemonServers(force: true) }
        print("[Watchdog] Daemon mode started (interval \(Int(checkInterval))s)")
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
    }
    
    /// 前台恢复 / 应用激活时立即检测
    func healNow() {
        queue.async { [weak self] in
            if self?.isDaemonMode == true {
                self?.healDaemonServers(force: true)
            } else {
                self?.healIfNeeded(force: true)
            }
        }
    }
    
    // MARK: - 定时器
    
    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        t.setEventHandler { [weak self] in
            if self?.isDaemonMode == true {
                self?.healDaemonServers(force: false)
            } else {
                self?.healIfNeeded(force: false)
            }
        }
        t.resume()
        timer = t
    }
    
    // MARK: - 应用模式：守护进程 + 前台 fallback
    
    private func healIfNeeded(force: Bool) {
        guard !isHealing else { return }
        if !force && Date().timeIntervalSince(lastHealTime) < healCooldown { return }
        
        isHealing = true
        defer { isHealing = false }
        
        let webdavUp = LocalPortChecker.isOpen(51111)
        let scriptUp = LocalPortChecker.isOpen(8989)
        let daemonStatus = DaemonInstaller.getStatus()
        
        // 端口正常且守护进程在跑 → 停掉应用内服务避免冲突
        if daemonStatus.running && webdavUp && scriptUp {
            stopInAppServersIfRunning()
            return
        }
        
        // 需要修复
        lastHealTime = Date()
        print("[Watchdog] Auto-heal: daemon=\(daemonStatus.running) webdav=\(webdavUp) script=\(scriptUp)")
        
        // 1. 同步 plist 可执行路径（应用更新后路径会变）
        _ = DaemonInstaller.syncPlistIfNeeded()
        
        // 2. 自动安装 / 加载守护进程
        if !daemonStatus.running || !webdavUp || !scriptUp {
            let ok = DaemonInstaller.ensureRunning()
            print("[Watchdog] ensureRunning -> \(ok)")
            
            Thread.sleep(forTimeInterval: 0.8)
            
            let after = DaemonInstaller.getStatus()
            let webdavAfter = LocalPortChecker.isOpen(51111)
            let scriptAfter = LocalPortChecker.isOpen(8989)
            
            if after.running && webdavAfter && scriptAfter {
                stopInAppServersIfRunning()
                print("[Watchdog] Daemon auto-healed successfully")
                notifyStatusChanged()
                return
            }
        }
        
        // 3. 守护进程仍不可用 → 应用在前台时启动 fallback
        let webdavNow = LocalPortChecker.isOpen(51111)
        let scriptNow = LocalPortChecker.isOpen(8989)
        if !webdavNow || !scriptNow {
            startInAppFallbackIfActive()
        }
        
        notifyStatusChanged()
    }
    
    private func stopInAppServersIfRunning() {
        DispatchQueue.main.async { [weak self] in
            guard let runner = self?.serverRunner else { return }
            let inAppRunning = runner.webdavServer?.getStats().running == true
                || runner.scriptServer?.getStatus().running == true
            if inAppRunning {
                print("[Watchdog] Stopping in-app servers (daemon is serving)")
                runner.stop()
            }
        }
    }
    
    private func startInAppFallbackIfActive() {
        DispatchQueue.main.async { [weak self] in
            guard let runner = self?.serverRunner else { return }
            let state = UIApplication.shared.applicationState
            guard state == .active || state == .inactive else {
                print("[Watchdog] App in background, relying on daemon")
                return
            }
            guard !LocalPortChecker.isOpen(51111) else { return }
            print("[Watchdog] Starting in-app fallback servers")
            runner.start()
        }
    }
    
    // MARK: - 守护进程模式：自愈 WebDAV / 脚本转发
    
    private func healDaemonServers(force: Bool) {
        guard !isHealing else { return }
        if !force && Date().timeIntervalSince(lastHealTime) < healCooldown { return }
        
        isHealing = true
        defer { isHealing = false }
        
        guard let runner = serverRunner else { return }
        
        let webdavUp = LocalPortChecker.isOpen(51111)
        let scriptUp = LocalPortChecker.isOpen(8989)
        
        if webdavUp && scriptUp {
            return
        }
        
        lastHealTime = Date()
        print("[Watchdog] Daemon self-heal: webdav=\(webdavUp) script=\(scriptUp)")
        
        if !webdavUp {
            runner.webdavServer?.stop()
            try? runner.webdavServer?.start()
            print("[Watchdog] Restarted WebDAV")
        }
        if !scriptUp {
            runner.scriptServer?.stop()
            try? runner.scriptServer?.start()
            print("[Watchdog] Restarted ScriptControl")
        }
    }
    
    private func notifyStatusChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .serviceWatchdogDidHeal, object: nil)
        }
    }
}

extension Notification.Name {
    static let serviceWatchdogDidHeal = Notification.Name("ServiceWatchdogDidHeal")
}

import Foundation

// ============================================================
//  守护进程运行器 - 管理双端口服务器的生命周期
//  由 main.swift 的 --daemon 模式或 AppDelegate 调用
// ============================================================

class DaemonServerRunner: NSObject {
    
    var webdavServer: WebDAVServer?
    var scriptServer: ScriptControlServer?
    
    /// 启动所有服务（应用模式使用）
    func start() {
        startWebDAVServer()
        startScriptControlServer()
        print("[TrollServer] All servers started")
    }
    
    /// 守护进程模式启动 — 每个服务独立 try/catch，启动失败不退出进程
    func startDaemon() {
        print("[TrollServer] Daemon runner starting (PID=\(getpid()))...")
        
        // WebDAV
        do {
            try startWebDAVDaemon()
        } catch {
            print("[TrollServer] ERROR: WebDAV daemon start failed: \(error)")
        }
        
        // ScriptControl
        do {
            try startScriptControlDaemon()
        } catch {
            print("[TrollServer] ERROR: ScriptControl daemon start failed: \(error)")
        }
        
        print("[TrollServer] Daemon runner init done (webdav=\(webdavServer?.getStats().running ?? false), script=\(scriptServer?.getStatus().running ?? false))")
    }
    
    /// 守护进程模式重启 WebDAV（给 Watchdog 调用）
    /// 使用同步停止确保旧 listener 完全释放后再启动新 listener
    func restartWebDAVDaemon() {
        isRestartingWebDAV = true
        webdavServer?.stopSync()
        // 短暂延迟确保端口完全释放
        Thread.sleep(forTimeInterval: 0.5)
        do {
            try startWebDAVDaemon()
            print("[TrollServer] WebDAV daemon restarted OK")
        } catch {
            print("[TrollServer] ERROR: WebDAV daemon restart failed: \(error)")
        }
        isRestartingWebDAV = false
    }
    
    /// 守护进程模式重启 ScriptControl（给 Watchdog 调用）
    func restartScriptDaemon() {
        isRestartingScript = true
        scriptServer?.stopSync()
        Thread.sleep(forTimeInterval: 0.5)
        do {
            try startScriptControlDaemon()
            print("[TrollServer] Script daemon restarted OK")
        } catch {
            print("[TrollServer] ERROR: Script daemon restart failed: \(error)")
        }
        isRestartingScript = false
    }
    
    private(set) var isRestartingWebDAV = false
    private(set) var isRestartingScript = false
    
    // MARK: - Daemon 模式启动（不重试，交给 Watchdog 周期修复）
    
    private func startWebDAVDaemon() throws {
        let baseDir = "/var/mobile/Downloads"
        webdavServer = WebDAVServer(port: 51111, baseDirectory: baseDir)
        try webdavServer?.start()
        print("[TrollServer] WebDAV daemon started on port 51111")
    }
    
    private func startScriptControlDaemon() throws {
        scriptServer = ScriptControlServer(port: 8989)
        try scriptServer?.start()
        print("[TrollServer] Script control daemon started on port 8989")
    }
    
    /// 停止所有服务
    func stop() {
        webdavServer?.stopSync()
        scriptServer?.stopSync()
        print("[TrollServer] All servers stopped")
    }
    
    // MARK: - Port 51111 WebDAV/File Server (避开 Filza 11111 端口冲突)
    
    private var webdavRetryCount = 0
    private let maxRetries = 5
    
    private func startWebDAVServer() {
        let baseDir = "/var/mobile/Downloads"
        webdavServer = WebDAVServer(port: 51111, baseDirectory: baseDir)
        
        do {
            try webdavServer?.start()
            webdavRetryCount = 0
            print("[TrollServer] WebDAV server started on port 51111 (base: \(baseDir))")
        } catch {
            print("[TrollServer] ERROR: Failed to start WebDAV on 51111: \(error)")
            
            webdavRetryCount += 1
            guard webdavRetryCount <= maxRetries else {
                print("[TrollServer] WebDAV: max retries (\(maxRetries)) reached, giving up")
                return
            }
            
            let delay = min(2.0 * Double(webdavRetryCount), 10.0)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                try? self?.webdavServer?.start()
                print("[TrollServer] WebDAV retry #\(self?.webdavRetryCount ?? 0) on 51111")
            }
        }
    }
    
    // MARK: - Port 8989 Script Control Server
    
    private var scriptRetryCount = 0
    
    private func startScriptControlServer() {
        scriptServer = ScriptControlServer(port: 8989)
        
        do {
            try scriptServer?.start()
            scriptRetryCount = 0
            print("[TrollServer] Script control server started on port 8989")
        } catch {
            print("[TrollServer] ERROR: Failed to start script control on 8989: \(error)")
            
            scriptRetryCount += 1
            guard scriptRetryCount <= maxRetries else {
                print("[TrollServer] Script control: max retries (\(maxRetries)) reached, giving up")
                return
            }
            
            let delay = min(2.0 * Double(scriptRetryCount), 10.0)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                try? self?.scriptServer?.start()
                print("[TrollServer] Script control retry #\(self?.scriptRetryCount ?? 0) on 8989")
            }
        }
    }
}

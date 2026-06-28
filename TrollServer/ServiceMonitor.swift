import Foundation
import Darwin
#if !DAEMON_MODE
import UIKit
#endif

// ============================================================
//  ServiceMonitor v3.1 - 强化看门狗（后台可靠 + 防误报 + 静音音频联动）
//
//  特点：
//  - 使用专用 Thread 替代 DispatchSource timer（后台可靠）
//  - 每次检查 beginBackgroundTask 通过主线程调用
//  - 至少 2 次连续失败才触发重启（防止后台临时超时误报）
//  - 端口检查超时缩短至 500ms（本地回环）
//  - 渐进式检查间隔：正常 5s → 异常时递增
//  - 联动静音音频：超 8 次失败则尝试重启音频保活
//  - 公开状态回调给 ViewController 更新 UI
// ============================================================

class ServiceMonitor {

    static let shared = ServiceMonitor()

    // ===================== 公开状态 =====================
    private(set) var statusDetail: String = "初始化中..."
    private(set) var restartCount: Int = 0
    private(set) var lastRestartTime: Date?
    private(set) var lastRestartReason: String = ""

    // 状态变更回调（供 UI 更新）
    var onStatusChanged: (() -> Void)?

    // ===================== 内部 =====================
    private weak var server: TrollHTTPServer?
    private var isRunning = false
    private let lock = NSLock()
    private var monitorThread: Thread?
    private var checkInterval: TimeInterval = 5.0
    private var consecutiveFailures = 0

    // ===================== 启动 / 停止 =====================

    func start(server: TrollHTTPServer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        self.server = server
        isRunning = true
        checkInterval = 5.0
        consecutiveFailures = 0
        statusDetail = "看门狗就绪"

        // 使用专用 Thread + while 循环（后台比 DispatchSource timer 更可靠）
        let thread = Thread { [weak self] in
            while let self = self, self.isRunning {
                autoreleasepool {
                    // v3.1: beginBackgroundTask 通过主线程调用
                    #if !DAEMON_MODE
                    let semaphore = DispatchSemaphore(value: 0)
                    var checkTask: UIBackgroundTaskIdentifier = .invalid
                    DispatchQueue.main.async {
                        checkTask = UIApplication.shared.beginBackgroundTask(withName: "MonitorCheck") {
                            if checkTask != .invalid {
                                UIApplication.shared.endBackgroundTask(checkTask)
                            }
                        }
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 2.0)
                    #endif

                    self.performCheck()

                    #if !DAEMON_MODE
                    if checkTask != .invalid {
                        DispatchQueue.main.async {
                            UIApplication.shared.endBackgroundTask(checkTask)
                        }
                    }
                    #endif
                }
                Thread.sleep(forTimeInterval: self.checkInterval)
            }
        }
        thread.name = "com.troll.monitor"
        thread.qualityOfService = .background
        thread.start()
        monitorThread = thread

        notifyStatus("👁️ 看门狗已启动（每 \(Int(checkInterval))s 自检）")
        print("[Monitor] 👁️ 看门狗 v3.0 已启动（Thread 模式，后台可靠）")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        monitorThread?.cancel()
        monitorThread = nil
        notifyStatus("🛑 看门狗已停止")
        print("[Monitor] 🛑 看门狗已停止")
    }

    func healNow() {
        DispatchQueue.global().async { [weak self] in
            self?.performCheck()
        }
    }

    // ===================== 状态通知 =====================

    private func notifyStatus(_ msg: String) {
        statusDetail = msg
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    // ===================== 检查逻辑 =====================

    private func performCheck() {
        guard isRunning else { return }

        let port: UInt16 = 51111
        let serverRunning = server?.isRunning == true

        // 先快速检查 server.isRunning（零开销）
        if serverRunning {
            // 再做端口确认
            let portAlive = checkPortFast(port)
            if portAlive {
                // 一切正常
                consecutiveFailures = 0
                checkInterval = 5.0
                notifyStatus("🟢 服务正常（端口 OK）")
                return
            }
            // 端口不通但 server.isRunning = true
            print("[Monitor] ⚠️ server.isRunning=true 但端口不通 (#\(consecutiveFailures+1))")
        } else {
            print("[Monitor] ⚠️ server.isRunning=false (#\(consecutiveFailures+1))")
        }

        consecutiveFailures += 1
        print("[Monitor] 🔴 检查失败 #\(consecutiveFailures) (server: \(serverRunning))")

        // v3.1: 至少 2 次连续失败才重启，避免后台临时超时误判
        let didRestart: Bool
        if consecutiveFailures >= 2 {
            restartServer(reason: "连续\(consecutiveFailures)次失败 server.run=\(serverRunning)")
            didRestart = true
        } else {
            notifyStatus("⚠️ 首次失败，等待下次确认 (\(consecutiveFailures)/2)")
            didRestart = false
        }

        // 渐进式延长间隔（如果 restartServer 已重置则沿用其值）
        if !didRestart || server?.isRunning != true {
            checkInterval = min(2.0 * Double(consecutiveFailures), 30.0)
        }

        // 超过 8 次连续失败：尝试重启静音音频
        if consecutiveFailures >= 8 {
            #if !DAEMON_MODE
            print("[Monitor] 🆘 连续 \(consecutiveFailures) 次失败，尝试重启静音音频...")
            SilentAudioPlayer.shared.stop()
            Thread.sleep(forTimeInterval: 1)
            SilentAudioPlayer.shared.start()
            #endif
        }
    }

    // ===================== 快速端口检查（BSD socket） =====================

    private func checkPortFast(_ port: UInt16) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        // 设置非阻塞
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            // 连接成功 → 端口活着，立即关闭
            return true
        }

        // 非阻塞 connect 返回 EINPROGRESS 是正常的
        if errno == EINPROGRESS {
            // poll 等待 500ms（本地回环，足够快）
            var fds = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&fds, 1, 500)
            if pollResult > 0 && (fds.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var errorLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &errorLen) == 0 && error == 0 {
                    return true
                }
            }
        }

        return false
    }

    // ===================== 自动重启 =====================

    private func restartServer(reason: String) {
        let startTime = Date()
        restartCount += 1
        lastRestartReason = reason
        lastRestartTime = Date()

        print("[Monitor] 🔄 自动重启 #\(restartCount): \(reason)")

        // 先用 restart()（优于 stop+start，有状态保护）
        server?.restart()

        let elapsed = Date().timeIntervalSince(startTime)
        let serverOK = server?.isRunning == true
        if serverOK {
            consecutiveFailures = 0
            checkInterval = 5.0
            notifyStatus("✅ 自动恢复 #\(restartCount)（耗时 \(String(format: "%.1f", elapsed))s）")
            print("[Monitor] ✅ 自动恢复成功 #\(restartCount)")
        } else {
            notifyStatus("❌ 重启失败 #\(restartCount)（\(String(format: "%.1f", elapsed))s）")
            print("[Monitor] ❌ 重启失败 #\(restartCount)，将继续尝试")
        }
    }
}

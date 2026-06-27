import Foundation
import Network

// ============================================================
//  ServiceMonitor - 10 秒自检 + 自动重启看门狗
//
//  每 10 秒执行三重检查：
//  1. 端口 51111 是否在监听？(TCP dial)
//  2. 服务对象是否还在运行？
//  3. /api/heartbeat 返回是否正常？
//
//  任意一项失败 → 立即重启服务（≤2 秒恢复）
// ============================================================

class ServiceMonitor {

    static let shared = ServiceMonitor()

    private let checkInterval: TimeInterval = 10.0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.troll.monitor", qos: .background)
    private weak var server: TrollHTTPServer?
    private var isRunning = false
    private let lock = NSLock()

    // 连续失败计数（防止误报）
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 2

    // ===================== 启动 / 停止 =====================

    func start(server: TrollHTTPServer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        self.server = server
        isRunning = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: checkInterval)
        t.setEventHandler { [weak self] in
            self?.performCheck()
        }
        t.resume()
        timer = t

        print("[Monitor] 👁️ 看门狗已启动（每 \(Int(checkInterval))s 自检）")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        print("[Monitor] 🛑 看门狗已停止")
    }

    // ===================== 立即自愈 =====================
    func healNow() {
        queue.async { [weak self] in
            self?.performCheck()
        }
    }

    // ===================== 检查逻辑 =====================

    private func performCheck() {
        guard isRunning else { return }

        let port: UInt16 = 51111

        // 检查 1: 服务器状态
        let serverAlive = server?.isRunning == true

        // 检查 2: 端口是否在监听
        let portAlive = checkPort(port)

        // 检查 3: 心跳接口
        let heartbeatOK = checkHeartbeat(port)

        let allOK = serverAlive && portAlive && heartbeatOK

        if allOK {
            consecutiveFailures = 0
            print("[Monitor] 🟢 所有检查通过 (port: \(portAlive), heartbeat: \(heartbeatOK))")
            return
        }

        consecutiveFailures += 1
        print("[Monitor] 🔴 检查失败 #\(consecutiveFailures) (server: \(serverAlive), port: \(portAlive), heartbeat: \(heartbeatOK))")

        // 连续失败 N 次才触发重启（防止误报）
        guard consecutiveFailures >= maxConsecutiveFailures else { return }

        print("[Monitor] 🔄 触发自动重启...")
        restartServer()
    }

    // ===================== 端口检查 =====================

    private func checkPort(_ port: UInt16) -> Bool {
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let sem = DispatchSemaphore(value: 0)
        var result = false

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result = true
                conn.cancel()
            case .failed, .cancelled:
                if !result { sem.signal() }
            default:
                break
            }
        }
        conn.start(queue: queue)
        _ = sem.wait(timeout: .now() + 2.0)

        if !result {
            conn.cancel()
        }
        return result
    }

    // ===================== 心跳检查 =====================

    private func checkHeartbeat(_ port: UInt16) -> Bool {
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let sem = DispatchSemaphore(value: 0)
        var result = false

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /api/heartbeat HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                conn.send(content: request.data(using: .utf8)!, completion: .contentProcessed { _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        if let d = data, let str = String(data: d, encoding: .utf8), str.contains("ok") {
                            result = true
                        }
                        conn.cancel()
                        sem.signal()
                    }
                })
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: queue)
        _ = sem.wait(timeout: .now() + 3.0)
        return result
    }

    // ===================== 自动重启 =====================

    private func restartServer() {
        let startTime = Date()

        // 1. 停止旧服务
        server?.stop()
        Thread.sleep(forTimeInterval: 0.5)

        // 2. 启动新服务
        guard let s = server else { return }
        let ok = s.start()
        consecutiveFailures = 0

        let elapsed = Date().timeIntervalSince(startTime)
        if ok {
            print("[Monitor] ✅ 服务重启成功（耗时 \(String(format: "%.1f", elapsed))s）")
        } else {
            print("[Monitor] ❌ 服务重启失败（耗时 \(String(format: "%.1f", elapsed))s）")
        }
    }
}

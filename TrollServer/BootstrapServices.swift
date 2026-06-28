import Foundation
import Darwin
import UIKit

// ============================================================
//  BootstrapServices v3.2 — Daemon/App 分离架构
//
//  Daemon 进程（由 launchd 托管）：
//    - 独占端口 51111（BSD socket）
//    - 悬浮球显示运行状态
//    - ServiceMonitor 自检看门狗
//    - UDP 广播发现
//    - 杀 App 不受影响 ← 核心改进
//
//  App 进程（GUI 客户端）：
//    - 检测 daemon 是否在线
//    - 在线 → 客户端模式（连接 localhost:51111）
//    - 离线 → 服务端模式 + 自动安装 daemon
// ============================================================

enum BootstrapServices {

    /// 全局服务器实例（daemon 专属，App 客户端模式下不使用）
    static let httpServer: TrollHTTPServer = {
        let s = TrollHTTPServer(port: 51111)
        return s
    }()

    /// 标记 App 是否运行在客户端模式（不绑定端口）
    private(set) static var isClientMode = false

    // ===================== Daemon 模式 =====================

    /// 守护进程模式：启动服务 + 看门狗 + 悬浮球 + UDP 广播
    /// 进程由 launchd 托管，端口和悬浮球永久在线
    static func startForDaemon() {
        print("[Bootstrap] 🚀 守护进程模式启动 (PID=\(getpid()))")

        // 1. 启动 HTTP/WebDAV 服务（独占 51111）
        let started = httpServer.start()
        print("[Bootstrap] \(started ? "✅" : "❌") HTTP 服务 (51111)")

        // 2. 启动自检看门狗
        ServiceMonitor.shared.start(server: httpServer)

        // 3. 启动 UDP 广播发现
        UDPBroadcaster.shared.start()

        // 4. 启动悬浮球（daemon 进程内渲染，杀 App 不受影响）
        #if DAEMON_MODE
        // 需要等 UIKit 初始化完成（RunLoop 启动后）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = UIApplication.shared  // 激活 UIKit
            FloatingBallOverlay.shared.show()
            FloatingBallOverlay.shared.startStatusRefresh()

            // 定期同步状态到悬浮球
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                let server = BootstrapServices.httpServer
                FloatingBallOverlay.shared.updateStatus(
                    running: server.isRunning,
                    requests: server.requestCount,
                    uptime: Int(-server.startTime.timeIntervalSinceNow)
                )
            }
        }
        #endif

        print("[Bootstrap] ✅ 守护进程初始化完成")
    }

    // ===================== App 模式 =====================

    /// App 模式：检测 daemon 状态，决定以客户端还是服务端模式运行
    static func startForApp() {
        print("[Bootstrap] 📱 App 模式启动")

        // 0. 确保 daemon 已安装（幂等操作）
        _ = DaemonBootstrap.installIfNeeded()

        // 1. 检测 daemon 是否已在运行（通过端口 51111）
        if checkPortAlive(port: 51111) {
            // Daemon 已在运行 → 客户端模式
            print("[Bootstrap] ℹ️ 检测到 daemon 已在运行，启用客户端模式")
            isClientMode = true
            startForAppClient()
            return
        }

        // 2. Daemon 未运行 → 服务端模式（App 自己启动服务）
        print("[Bootstrap] ⚠️ daemon 未运行，App 自行启动服务并尝试拉取 daemon")
        isClientMode = false
        startForAppServer()

        // 3. 尝试手动拉起 daemon（避免端口冲突：只 load，App 退出后 daemon 接管）
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            DaemonBootstrap.loadDaemon()
        }
    }

    /// 客户端模式：App 不绑定端口，通过 HTTP 连接 daemon
    private static func startForAppClient() {
        print("[Bootstrap] 👤 客户端模式：连接 daemon localhost:51111")

        // 不需要启动 HTTP 服务（daemon 已占用端口）
        // 不需要看门狗（daemon 自己维护）
        // 不需要 UDP 广播（daemon 自己发）

        // App 保活（让悬浮球稳定显示）
        KeepAliveManager.shared.start()

        print("[Bootstrap] ✅ 客户端模式初始化完成")
    }

    /// 服务端模式：App 自己启动所有服务（首次运行/daemon 未安装时）
    private static func startForAppServer() {
        print("[Bootstrap] 🖥️ 服务端模式：App 自行启动服务")

        // 1. 启动 HTTP/WebDAV 服务
        _ = httpServer.start()

        // 2. 启动保活（后台任务 + 禁止休眠）
        KeepAliveManager.shared.start()

        // 3. 启动自检看门狗
        ServiceMonitor.shared.start(server: httpServer)

        // 4. 启动 UDP 广播发现
        UDPBroadcaster.shared.start()

        print("[Bootstrap] ✅ 服务端模式初始化完成")
    }

    // ===================== 停止 =====================

    /// 停止所有服务
    static func stopAll() {
        if !isClientMode {
            UDPBroadcaster.shared.stop()
            ServiceMonitor.shared.stop()
            httpServer.stop()
        }
        KeepAliveManager.shared.stop()
        print("[Bootstrap] 🛑 所有服务已停止")
    }

    // ===================== 端口检测 =====================

    /// 快速检查本地端口是否存活
    private static func checkPortAlive(port: UInt16) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        // 非阻塞
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

        if result == 0 { return true }
        if errno == EINPROGRESS {
            var fds = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&fds, 1, 300)
            if pollResult > 0 && (fds.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var errorLen = socklen_t(MemoryLayout<Int32>.size)
                return getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &errorLen) == 0 && error == 0
            }
        }
        return false
    }
}

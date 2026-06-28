import Foundation
import Darwin

// ============================================================
//  UDPBroadcaster - iOS 端 UDP 广播发现
//
//  每 5 秒发送一次广播到 255.255.255.255:51111
//  消息格式: TROLL_DEVICE_ONLINE|ip:x.x.x.x|port:51111
//  中控端被动监听，收到广播后自动添加设备
//
//  v3.1: 使用专用 Thread 替代 Timer，
//  确保后台 runloop 挂起时广播继续发送
// ============================================================

final class UDPBroadcaster {
    static let shared = UDPBroadcaster()

    private var broadcastThread: Thread?
    private var isRunning = false
    private let port: UInt16 = 51111
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true

        print("[UDP广播] 🚀 启动，每 5 秒广播一次（Thread 模式）")

        // 立刻发送一次
        sendBroadcast()

        // 专用线程循环发送，后台不中断
        let thread = Thread { [weak self] in
            while let self = self, self.isRunning {
                autoreleasepool {
                    self.sendBroadcast()
                }
                Thread.sleep(forTimeInterval: 5.0)
            }
        }
        thread.name = "com.troll.broadcast"
        thread.qualityOfService = .background
        thread.start()
        broadcastThread = thread
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        broadcastThread?.cancel()
        broadcastThread = nil
        print("[UDP广播] 🛑 已停止")
    }

    // MARK: - Private

    private func sendBroadcast() {
        let localIP = Self.getWiFiIPAddress() ?? "0.0.0.0"
        let message = "TROLL_DEVICE_ONLINE|ip:\(localIP)|port:\(port)"

        guard let data = message.data(using: .utf8) else {
            print("[UDP广播] ⚠️ 消息编码失败")
            return
        }

        // 使用 POSIX socket 发送 UDP 广播
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            print("[UDP广播] ⚠️ 创建 socket 失败: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(sock) }

        // 启用广播模式
        var broadcast: Int32 = 1
        if setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            print("[UDP广播] ⚠️ 启用广播失败: \(String(cString: strerror(errno)))")
            return
        }

        // 设置目标地址: 255.255.255.255:51111
        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        destAddr.sin_addr.s_addr = INADDR_BROADCAST

        let sent = data.withUnsafeBytes { buf -> Int in
            let addrPtr = withUnsafePointer(to: &destAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
            }
            return sendto(sock, buf.baseAddress, data.count, 0,
                          addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        if sent > 0 {
            print("[UDP广播] 📡 已广播: \(message)")
        } else {
            print("[UDP广播] ⚠️ 发送失败: \(String(cString: strerror(errno)))")
        }
    }

    /// 获取当前 WiFi 接口的本地 IP 地址
    static func getWiFiIPAddress() -> String? {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else {
            return nil
        }
        defer { freeifaddrs(addrList) }

        var ip: String?
        var ptr = first
        while ptr.pointee.ifa_next != nil {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = ptr.pointee.ifa_flags

            // 只取 en0 (WiFi) 接口的 IPv4 地址
            if name == "en0", (Int32(flags) & IFF_UP) != 0, (Int32(flags) & IFF_LOOPBACK) == 0 {
                var addr = ptr.pointee.ifa_addr.pointee
                if addr.sa_family == sa_family_t(AF_INET) {
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sockAddrIn = sockaddr_in()
                    memcpy(&sockAddrIn, &addr, MemoryLayout<sockaddr_in>.size)
                    inet_ntop(AF_INET, &sockAddrIn.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    ip = String(cString: buffer)
                    break
                }
            }

            ptr = ptr.pointee.ifa_next
        }

        return ip
    }
}

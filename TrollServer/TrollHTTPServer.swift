import Foundation
#if !DAEMON_MODE
import UIKit
#endif
import Darwin

// ============================================================
//  TrollHTTPServer v3.1 - BSD 原生 socket 版
//
//  核心变更：用 BSD socket (socket/bind/listen/accept) 取代
//  Network.framework 的 NWListener，从而根除后台断连问题。
//
//  NWListener 为何在后台断开：
//    NWListener 是用户态 Network.framework 的高级抽象，
//    依赖 dispatch queue 工作。iOS 进入后台时会挂起这些
//    queue，导致端口立即不可达。
//
//  BSD socket 为何不会断开：
//    socket()→bind()→listen() 后，端口由内核 TCP 栈直接
//    管理。只要进程还活着（静音音频保活），内核就会响应
//    TCP SYN 完成三次握手并排队等待 accept()。这是所有
//    成熟 iOS WebDAV 应用（GCDWebServer 等）的方案。
//
//  v3.1 改进：
//  - beginBackgroundTask 统一通过主线程调用（后台可靠性）
//  - accept 线程 QoS 提升至 userInitiated
//  - 进入后台不再强制重启监听器
//
//  端口: 51111
//  端点:
//    GET  /api/heartbeat   → 心跳
//    GET  /api/device      → 设备信息
//    GET  /api/browse      → 浏览应用沙盒文件
//    GET  /{path}          → 下载文件
//    PUT  /{path}          → 上传文件
//    MKCOL /{path}         → 创建目录
//    DELETE /{path}        → 删除文件/目录
//    PROPFIND /{path}      → 列出目录
// ============================================================

class TrollHTTPServer {

    // MARK: - 类型定义

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var pathWithoutQuery: String {
            path.components(separatedBy: "?").first ?? path
        }
    }

    struct HTTPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        static func ok(_ body: Data = Data(), contentType: String = "text/plain") -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": contentType], body: body)
        }
        static func notFound() -> HTTPResponse {
            HTTPResponse(statusCode: 404, headers: [:], body: "Not Found".data(using: .utf8)!)
        }
        static func methodNotAllowed() -> HTTPResponse {
            HTTPResponse(statusCode: 405, headers: [:], body: "Method Not Allowed".data(using: .utf8)!)
        }
        static func internalError(_ msg: String = "Internal Server Error") -> HTTPResponse {
            HTTPResponse(statusCode: 500, headers: [:], body: msg.data(using: .utf8)!)
        }
        static func created() -> HTTPResponse {
            HTTPResponse(statusCode: 201, headers: [:], body: Data())
        }
        static func noContent() -> HTTPResponse {
            HTTPResponse(statusCode: 204, headers: [:], body: Data())
        }
    }

    // ===================== 常量 =====================
    static let version = "TrollServer-v3.1"

    // ===================== 状态 =====================
    private let port: UInt16
    private let docRoot: String
    private let handleQueue = DispatchQueue(label: "com.troll.http", qos: .userInitiated, attributes: .concurrent)

    private(set) var isRunning = false
    private let lock = NSLock()

    // BSD socket
    private var listenSock: Int32 = -1
    private var acceptThread: Thread?
    private var acceptShouldStop = false

    // 统计
    private(set) var requestCount: Int64 = 0
    private(set) var startTime: Date = Date()

    // ===================== 常量 =====================
    private static let listenBacklog: Int32 = 128
    private static let recvTimeoutSec: time_t = 30
    private static let sendTimeoutSec: time_t = 30
    // TrollServer 使用自己的沙盒目录
    static let defaultDocRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Game")

    // ===================== 初始化 =====================
    init(port: UInt16 = 51111, docRoot: String? = nil) {
        self.port = port
        self.docRoot = docRoot ?? Self.defaultDocRoot
    }

    // ===================== 启动 / 停止 / 重启 =====================

    /// 重启服务器（保持端口连续，用于后台过渡或异常恢复）
    func restart() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            _ = start()
            return
        }
        print("[HTTP:\(port)] 🔄 重启监听器...")
        // 标记停止 accept 线程，关闭 socket
        acceptShouldStop = true
        let sock = listenSock
        listenSock = -1
        if sock >= 0 { Darwin.shutdown(sock, SHUT_RDWR); Darwin.close(sock) }
        isRunning = false
        lock.unlock()

        // 等待旧线程退出
        Thread.sleep(forTimeInterval: 0.3)

        let ok = start()
        print("[HTTP:\(port)] \(ok ? "✅" : "❌") 监听器重启\(ok ? "成功" : "失败")")
    }

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return true }

        // 1. 创建 TCP socket
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[HTTP:\(port)] ❌ socket() 失败: \(lastError())")
            return false
        }

        // 2. SO_REUSEADDR — 允许快速重启（TIME_WAIT 后立即重用端口）
        var opt: Int32 = 1
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        // SO_NOSIGPIPE — 防止 SIGPIPE 信号杀死进程（macOS/iOS 特有）
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))

        // 3. 绑定地址 0.0.0.0:51111（所有接口：Wi-Fi、热点、USB）
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("[HTTP:\(port)] ❌ bind() 失败: \(lastError())")
            Darwin.close(sock)
            return false
        }

        // 4. 开始监听
        guard Darwin.listen(sock, Self.listenBacklog) == 0 else {
            print("[HTTP:\(port)] ❌ listen() 失败: \(lastError())")
            Darwin.close(sock)
            return false
        }

        listenSock = sock
        isRunning = true
        acceptShouldStop = false
        startTime = Date()

        print("[HTTP:\(port)] 🚀 BSD socket 服务器已启动 (fd=\(sock))")
        try? FileManager.default.createDirectory(atPath: docRoot, withIntermediateDirectories: true)

        // 5. 启动 accept 线程（阻塞 accept，由内核管理，后台不挂）
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "com.troll.accept"
        thread.qualityOfService = .userInitiated
        thread.start()
        acceptThread = thread

        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        acceptShouldStop = true
        isRunning = false

        // shutdown + close 会让阻塞中的 accept() 返回 -1，从而退出线程
        let sock = listenSock
        listenSock = -1
        if sock >= 0 {
            Darwin.shutdown(sock, SHUT_RDWR)
            Darwin.close(sock)
        }

        print("[HTTP:\(port)] 🛑 服务器已停止")
    }

    // ===================== Accept 循环（专用线程） =====================

    private func acceptLoop() {
        while !acceptShouldStop {
            let sock = listenSock
            guard sock >= 0 else { break }

            let clientFd = Darwin.accept(sock, nil, nil)
            if clientFd < 0 {
                if acceptShouldStop || listenSock < 0 { break }
                // EINTR: 被信号打断，重试；其他错误短暂休眠后重试
                if errno == EINTR { continue }
                let err = lastError()
                print("[HTTP:\(port)] ⚠️ accept() 错误: \(err)")
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            // 交给串行队列处理（避免阻塞 accept）
            handleClientFd(clientFd)
        }
        print("[HTTP:\(port)] accept 线程退出")
    }

    // ===================== 客户端处理 =====================

    private func handleClientFd(_ fd: Int32) {
        // 设置读写超时（防止僵尸连接长期占用 fd）
        var timeout = timeval(tv_sec: Self.recvTimeoutSec, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // v3.1: beginBackgroundTask 需要在主线程调用
        // 但 accept 工作在后台线程，所以通过 DispatchQueue.main 调度
        #if !DAEMON_MODE
        DispatchQueue.main.async {
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "TrollHTTP_\(fd)") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            // 持有 bgTask 引用以免提前释放
            // 在 handleQueue 操作完成后回到主线程结束任务
            self.handleQueue.async { [weak self] in
                defer {
                    Darwin.close(fd)
                    DispatchQueue.main.async {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                        }
                    }
                }

                guard let self = self else { return }

                // 读取 HTTP 请求
                guard let req = self.readHTTPRequest(from: fd) else {
                    self.sendRaw(statusCode: 400, bodyData: "Bad Request".data(using: .utf8)!, to: fd)
                    return
                }

                OSAtomicIncrement64(&self.requestCount)
                let resp = self.route(req)

                // 发送响应
                self.sendRaw(
                    statusCode: resp.statusCode,
                    headers: resp.headers,
                    bodyData: resp.body,
                    to: fd
                )
            }
        }
        #else
        handleQueue.async { [weak self] in
            defer { Darwin.close(fd) }

            guard let self = self else { return }

            // 读取 HTTP 请求
            guard let req = self.readHTTPRequest(from: fd) else {
                self.sendRaw(statusCode: 400, bodyData: "Bad Request".data(using: .utf8)!, to: fd)
                return
            }

            OSAtomicIncrement64(&self.requestCount)
            let resp = self.route(req)

            // 发送响应
            self.sendRaw(
                statusCode: resp.statusCode,
                headers: resp.headers,
                bodyData: resp.body,
                to: fd
            )
        }
        #endif
    }

    // ===================== BSD socket 读取 HTTP 请求 =====================

    private func readHTTPRequest(from fd: Int32) -> HTTPRequest? {
        var data = Data()
        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)

        // 阶段 1：读取 HTTP header（找 \r\n\r\n）
        var headerParsed = false
        var contentLength: Int = 0
        let maxHeader = 65536  // header 最大 64KB（防止恶意超大 header）

        while data.count < maxHeader {
            let n = Darwin.recv(fd, &buf, bufSize, 0)
            if n > 0 {
                data.append(contentsOf: buf[0..<Int(n)])
                if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                    // header 收齐了，先解析获取 Content-Length
                    let headerEnd = range.lowerBound
                    let headerData = data.subdata(in: 0..<headerEnd)
                    if let headerStr = String(data: headerData, encoding: .utf8) {
                        for line in headerStr.components(separatedBy: "\r\n").dropFirst() {
                            guard let colon = line.firstIndex(of: ":") else { continue }
                            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                            if key == "content-length", let len = Int(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)) {
                                contentLength = len
                                break
                            }
                        }
                        headerParsed = true
                        break
                    }
                }
            } else if n == 0 {
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
        }

        // 阶段 2：按 Content-Length 读取 body（上限 800MB，防止恶意超大文件）
        if headerParsed && contentLength > 0 {
            let maxBody = 800 * 1024 * 1024  // 800MB
            let safeLen = min(contentLength, maxBody)
            let bodyStart = data.range(of: Data("\r\n\r\n".utf8))!.upperBound
            let targetCount = bodyStart + safeLen

            while data.count < targetCount {
                let n = Darwin.recv(fd, &buf, bufSize, 0)
                if n > 0 {
                    data.append(contentsOf: buf[0..<Int(n)])
                } else if n == 0 {
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if let req = Self.parseHTTP(data) { return req }
                    }
                    break
                }
            }
        }

        return Self.parseHTTP(data)
    }

    // ===================== BSD socket 发送响应 =====================

    private func sendRaw(statusCode: Int, headers: [String: String] = [:], bodyData: Data, to fd: Int32) {
        let statusText: String = {
            switch statusCode {
            case 200: return "OK"
            case 201: return "Created"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 413: return "Payload Too Large"
            case 500: return "Internal Server Error"
            default: return "Unknown"
            }
        }()

        var headerStr = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        headerStr += "Server: \(Self.version)\r\n"
        headerStr += "Connection: close\r\n"
        for (k, v) in headers {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "Content-Length: \(bodyData.count)\r\n"
        headerStr += "\r\n"

        guard let headerData = headerStr.data(using: .utf8) else { return }

        // 发送 header
        _ = headerData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            Darwin.send(fd, ptr.baseAddress, headerData.count, Int32(MSG_NOSIGNAL))
        }
        // 发送 body（如果非空）
        if !bodyData.isEmpty {
            _ = bodyData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                Darwin.send(fd, ptr.baseAddress, bodyData.count, Int32(MSG_NOSIGNAL))
            }
        }
    }



    // ===================== 路由分发 =====================
    private func route(_ req: HTTPRequest) -> HTTPResponse {
        let p = req.pathWithoutQuery

        // 自定义 API
        if p == "/api/heartbeat" {
            return .ok("ok".data(using: .utf8)!)
        }
        if p == "/api/device" {
            return deviceInfo()
        }
        if p == "/api/browse" || p.hasPrefix("/api/browse?") {
            return handleBrowse(req)
        }
        // WebDAV / 文件操作
        let filePath = (docRoot as NSString).appendingPathComponent(p)

        // 安全检查：防止目录穿越
        guard filePath.hasPrefix(docRoot) else {
            return HTTPResponse(statusCode: 403, headers: [:], body: "Forbidden".data(using: .utf8)!)
        }

        switch req.method {
        case "GET", "HEAD":
            return handleGET(filePath)
        case "PUT":
            return handlePUT(filePath, body: req.body)
        case "MKCOL":
            return handleMKCOL(filePath)
        case "DELETE":
            return handleDELETE(filePath)
        case "PROPFIND":
            return handlePROPFIND(filePath)
        case "OPTIONS":
            return HTTPResponse(statusCode: 200, headers: [
                "Allow": "GET, PUT, MKCOL, DELETE, PROPFIND, OPTIONS",
                "DAV": "1,2"
            ], body: Data())
        default:
            return .methodNotAllowed()
        }
    }

    // MARK: - API 处理器

    private func deviceInfo() -> HTTPResponse {
        #if !DAEMON_MODE
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battLevel = UIDevice.current.batteryLevel
        let batt: Int = battLevel >= 0 ? Int(battLevel * 100) : -1
        let deviceName = UIDevice.current.name
        let deviceModel = UIDevice.current.model
        let systemVer  = UIDevice.current.systemVersion
        #else
        let batt: Int = -1
        let deviceName = ProcessInfo.processInfo.hostName
        let deviceModel = "iPhone"
        let systemVer  = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        // 获取设备 UUID（首次生成后持久化，重启不变）
        let uuidPath = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/.device_uuid")
        let fm = FileManager.default
        var deviceUUID: String
        if fm.fileExists(atPath: uuidPath),
           let stored = try? String(contentsOfFile: uuidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            deviceUUID = stored
        } else {
            deviceUUID = UUID().uuidString
            try? deviceUUID.write(toFile: uuidPath, atomically: true, encoding: .utf8)
        }

        let info: [String: Any] = [
            "uuid": deviceUUID,
            "name": deviceName,
            "model": deviceModel,
            "systemVersion": systemVer,
            "version": Self.version,
            "port": port,
            "status": "running",
            "serverUptime": Int(-startTime.timeIntervalSinceNow),
            "battery": batt,
            "connectionsHandled": requestCount,
            "basePath": docRoot,
            "wifiIP": UDPBroadcaster.getWiFiIPAddress() ?? "0.0.0.0"
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) else {
            return .internalError()
        }
        return .ok(json, contentType: "application/json")
    }

    // MARK: - 文件操作

    private func handleGET(_ path: String) -> HTTPResponse {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .notFound()
        }
        if isDir.boolValue {
            // 目录 → 返回 HTML 列表
            return listDirectory(path)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .internalError()
        }
        let mime = mimeType(for: path)
        return .ok(data, contentType: mime)
    }

    private func handlePUT(_ path: String, body: Data) -> HTTPResponse {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            print("[HTTP] ❌ 创建目录失败 \(dir): \(error)")
        }
        do {
            try body.write(to: URL(fileURLWithPath: path))
            print("[HTTP] 📤 PUT \(path) (\(body.count) bytes)")
            return .created()
        } catch {
            print("[HTTP] ❌ 写入失败 \(path): \(error)")
            return .internalError()
        }
    }

    private func handleMKCOL(_ path: String) -> HTTPResponse {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .created()
        } catch {
            return .internalError()
        }
    }

    private func handleDELETE(_ path: String) -> HTTPResponse {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .notFound() }
        do {
            try fm.removeItem(atPath: path)
            return .noContent()
        } catch {
            return .internalError()
        }
    }

    private func handlePROPFIND(_ path: String) -> HTTPResponse {
        // 简单实现：返回目录下的文件列表
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return listDirectory("")
        }
        return listDirectory(path)
    }

    // MARK: - 沙盒浏览（不影响现有 docRoot 安全策略）

    /// GET /api/browse  → 浏览应用沙盒文件列表
    /// GET /api/browse?path=Documents/foo → 浏览指定子目录
    private func handleBrowse(_ req: HTTPRequest) -> HTTPResponse {
        // 解析 ?path=xxx 参数
        let queryPath: String
        if let queryRange = req.path.range(of: "?path=") {
            let rawParam = String(req.path[queryRange.upperBound...])
            let raw = rawParam.removingPercentEncoding ?? rawParam
            queryPath = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        } else {
            queryPath = ""
        }

        // 根目录为应用沙盒根
        let sandboxRoot = NSHomeDirectory()
        let browsePath: String
        if queryPath.isEmpty {
            // 默认显示 Documents 目录
            browsePath = (sandboxRoot as NSString).appendingPathComponent("Documents")
        } else {
            browsePath = (sandboxRoot as NSString).appendingPathComponent(queryPath)
        }

        // 安全检查：不允许穿越到沙盒外
        guard browsePath.hasPrefix(sandboxRoot) else {
            return HTTPResponse(statusCode: 403, headers: [:], body: "Forbidden".data(using: .utf8)!)
        }

        // 相对路径（用于 HTML 显示和链接）
        let displayPath = browsePath.replacingOccurrences(of: sandboxRoot, with: "")

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: browsePath, isDirectory: &isDir) else {
            return .notFound()
        }
        guard isDir.boolValue else {
            // 如果是文件，直接返回文件内容
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: browsePath)) else {
                return .internalError()
            }
            let mime = mimeType(for: browsePath)
            return .ok(data, contentType: mime)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: browsePath) else {
            return .internalError()
        }

        // 构建 HTML
        var html = "<!DOCTYPE html><html><head>"
        html += "<meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
        html += "<title>📂 沙盒浏览: \(displayPath.isEmpty ? "/" : displayPath)</title>"
        html += "<style>"
        html += "body{font-family:-apple-system,sans-serif;margin:16px;background:#111;color:#eee}"
        html += "h2{font-size:18px;word-break:break-all}"
        html += "a{color:#6af;text-decoration:none}"
        html += "ul{list-style:none;padding:0}"
        html += "li{padding:8px 12px;margin:2px 0;background:#1a1a1a;border-radius:6px;font-size:15px}"
        html += "li:hover{background:#222}"
        html += ".size{float:right;color:#888;font-size:13px}"
        html += ".up{border:1px dashed #444;margin-bottom:8px}"
        html += "</style></head><body>"

        html += "<h2>📂 沙盒: \(displayPath.isEmpty ? "/" : displayPath)</h2>"

        // 上级目录链接
        if browsePath != sandboxRoot, browsePath != (sandboxRoot as NSString).deletingLastPathComponent {
            let parentRel = displayPath.isEmpty ? "" : (displayPath as NSString).deletingLastPathComponent
            html += "<a href='/api/browse?path=\(parentRel)'><li class='up'>📂 ..</li></a>"
        } else if browsePath != sandboxRoot {
            html += "<a href='/api/browse'><li class='up'>📂 ..</li></a>"
        }

        // 目录在前，文件在后
        let sorted = files.sorted {
            let p0 = (browsePath as NSString).appendingPathComponent($0)
            let p1 = (browsePath as NSString).appendingPathComponent($1)
            var d0: ObjCBool = false, d1: ObjCBool = false
            fm.fileExists(atPath: p0, isDirectory: &d0)
            fm.fileExists(atPath: p1, isDirectory: &d1)
            if d0.boolValue != d1.boolValue { return d0.boolValue }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        for f in sorted {
            let full = (browsePath as NSString).appendingPathComponent(f)
            var isDirF: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDirF)
            let icon = isDirF.boolValue ? "📁" : "📄"
            let relPath = displayPath.isEmpty ? f : "\(displayPath)/\(f)"

            // 文件大小
            var sizeStr = ""
            if !isDirF.boolValue {
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? Int64 {
                    sizeStr = formatBytes(size)
                }
            }

            if isDirF.boolValue {
                html += "<li>\(icon) <a href='/api/browse?path=\(relPath)'>\(f)/</a></li>"
            } else {
                html += "<li>\(icon) <a href='/api/browse?path=\(relPath)'>\(f)</a> <span class='size'>\(sizeStr)</span></li>"
            }
        }

        html += "</ul></body></html>"
        guard let data = html.data(using: .utf8) else { return .internalError() }
        return .ok(data, contentType: "text/html; charset=utf-8")
    }

    /// 格式化字节大小
    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unitIdx = 0
        while size >= 1024 && unitIdx < units.count - 1 {
            size /= 1024
            unitIdx += 1
        }
        return String(format: "%.1f %@", size, units[unitIdx])
    }

    // MARK: - 辅助

    /// 获取最后一次系统调用错误描述
    private func lastError() -> String {
        String(cString: strerror(errno))
    }

    private func listDirectory(_ path: String) -> HTTPResponse {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: path) else {
            return .internalError()
        }
        var html = "<html><head><meta charset='utf-8'><title>\(path)</title></head><body>"
        html += "<h2>📁 \(path)</h2><ul>"
        if path != "" && path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            html += "<li><a href='\(parent.isEmpty ? "/" : parent)'>📂 ..</a></li>"
        }
        for f in files.sorted() {
            let full = (path as NSString).appendingPathComponent(f)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            let icon = isDir.boolValue ? "📁" : "📄"
            let url = path == "/" ? "/\(f)" : "\(path)/\(f)"
            html += "<li>\(icon) <a href='\(url)'>\(f)</a></li>"
        }
        html += "</ul></body></html>"
        guard let data = html.data(using: .utf8) else { return .internalError() }
        return .ok(data, contentType: "text/html; charset=utf-8")
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain"
        case "xml": return "application/xml"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "lua": return "text/plain"
        case "py": return "text/plain"
        case "sh": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    // MARK: - HTTP 解析（零依赖，纯 Swift）

    static func parseHTTP(_ data: Data) -> HTTPRequest? {
        // 找 header 结束标记
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil // header 还未收全
        }

        let headerEnd = range.lowerBound
        let headerData = data.subdata(in: 0..<headerEnd)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0].uppercased()
        let path = parts[1]

        // 解析 headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        // 检查 body 是否收齐
        var contentLength = 0
        if let cl = headers["content-length"], let len = Int(cl) {
            contentLength = len
        }

        let bodyStart = range.upperBound
        let bodyLen = data.count - bodyStart

        // 无 body 的方法直接返回
        if method == "GET" || method == "HEAD" || method == "DELETE" || method == "MKCOL" || method == "OPTIONS" || method == "PROPFIND" {
            return HTTPRequest(method: method, path: path, headers: headers, body: Data())
        }

        // 有 Content-Length：检查 body 是否收齐
        if bodyLen >= contentLength {
            let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
            return HTTPRequest(method: method, path: path, headers: headers, body: body)
        }

        // body 未收齐
        return nil
    }
}

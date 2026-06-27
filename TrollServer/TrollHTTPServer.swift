import Foundation
#if !DAEMON_MODE
import UIKit
#endif
import Network

// ============================================================
//  TrollHTTPServer - 轻量 HTTP/WebDAV 服务器（纯 Swift，零依赖）
//
//  端口: 51111
//  端点:
//    GET  /api/heartbeat   → 心跳
//    GET  /api/device      → 设备信息
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
    static let version = "TrollServer-v2.0"
    static let readTimeout: TimeInterval = 30.0

    // ===================== 状态 =====================
    private var listener: NWListener?
    private let port: UInt16
    private let docRoot: String
    private let queue = DispatchQueue(label: "com.troll.http", qos: .userInitiated)

    private(set) var isRunning = false
    private let lock = NSLock()

    // 统计
    private(set) var requestCount: Int64 = 0
    private(set) var startTime: Date = Date()

    // ===================== 初始化 =====================
    init(port: UInt16 = 51111, docRoot: String? = nil) {
        self.port = port
        self.docRoot = docRoot ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
    }

    // ===================== 启动 / 停止 =====================
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return true }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 不限制接口类型：iOS 设备可能通过 Wi-Fi、热点、USB 等方式连接

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[HTTP:\(self?.port ?? 0)] ✅ 服务启动成功")
                case .failed(let error):
                    print("[HTTP:\(self?.port ?? 0)] ❌ 启动失败: \(error)")
                    self?.lock.lock()
                    self?.isRunning = false
                    self?.lock.unlock()
                case .cancelled:
                    print("[HTTP:\(self?.port ?? 0)] 已停止")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }

            listener?.start(queue: queue)
            isRunning = true
            startTime = Date()
            print("[HTTP:\(port)] 🚀 服务器已启动，文档根目录: \(docRoot)")
            try? FileManager.default.createDirectory(atPath: docRoot, withIntermediateDirectories: true)
            return true
        } catch {
            print("[HTTP:\(port)] ❌ 无法启动: \(error)")
            return false
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        listener?.cancel()
        listener = nil
        isRunning = false
        print("[HTTP:\(port)] 🛑 服务器已停止")
    }

    // ===================== 连接处理 =====================
    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.readRequest(from: conn)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - 请求读取（带超时控制）

    private func readRequest(from connection: NWConnection) {
        var data = Data()
        var timedOut = false
        let timeoutLock = NSLock()
        var timer: DispatchSourceTimer?

        func startTimer() {
            timeoutLock.lock(); defer { timeoutLock.unlock() }
            timer?.cancel()
            guard !timedOut else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.readTimeout)
            t.setEventHandler { [weak connection] in
                timeoutLock.lock(); defer { timeoutLock.unlock() }
                guard !timedOut else { return }
                timedOut = true
                connection?.cancel()
            }
            t.resume()
            timer = t
        }

        func cancelTimer() {
            timeoutLock.lock(); defer { timeoutLock.unlock() }
            timer?.cancel(); timer = nil
        }

        func recv() {
            autoreleasepool {
                timeoutLock.lock()
                let done = timedOut
                timeoutLock.unlock()
                guard !done else { cancelTimer(); return }

                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] chunk, _, isComplete, error in
                    guard let self = self, let conn = connection else { cancelTimer(); return }

                    if error != nil || (chunk == nil && isComplete) {
                        cancelTimer()
                        conn.cancel()
                        return
                    }
                    if let d = chunk { data.append(d) }

                    // 解析请求
                    if let req = Self.parseHTTP(data) {
                        cancelTimer()
                        OSAtomicIncrement64(&self.requestCount)
                        let resp = self.route(req)
                        self.send(response: resp, on: conn)
                    } else if data.count > 65536 * 4 {
                        // 请求过大，直接拒绝
                        cancelTimer()
                        let resp = HTTPResponse(statusCode: 413, headers: [:], body: "Payload Too Large".data(using: .utf8)!)
                        self.send(response: resp, on: conn)
                    } else {
                        startTimer()
                        recv()
                    }
                }
            }
        }

        startTimer()
        recv()
    }

    // ===================== 响应发送 =====================
    private func send(response: HTTPResponse, on connection: NWConnection) {
        let statusText: String = {
            switch response.statusCode {
            case 200: return "OK"
            case 201: return "Created"
            case 204: return "No Content"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 413: return "Payload Too Large"
            case 500: return "Internal Server Error"
            default: return "Unknown"
            }
        }()

        var headerStr = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        headerStr += "Server: \(Self.version)\r\n"
        headerStr += "Connection: close\r\n"
        for (k, v) in response.headers {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "Content-Length: \(response.body.count)\r\n"
        headerStr += "\r\n"

        guard let headerData = headerStr.data(using: .utf8) else {
            connection.cancel()
            return
        }

        var fullResponse = headerData
        fullResponse.append(response.body)

        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        var batt: Float = -1
        UIDevice.current.isBatteryMonitoringEnabled = true
        batt = UIDevice.current.batteryLevel
        let deviceName = UIDevice.current.name
        let deviceModel = UIDevice.current.model
        let systemVer  = UIDevice.current.systemVersion
        #else
        let batt: Float = -1
        let deviceName = ProcessInfo.processInfo.hostName
        let deviceModel = "iPhone"
        let systemVer  = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        let info: [String: Any] = [
            "name": deviceName,
            "model": deviceModel,
            "system": systemVer,
            "version": Self.version,
            "port": port,
            "status": "running",
            "uptime": Int(-startTime.timeIntervalSinceNow),
            "battery": batt,
            "requests": requestCount,
            "docRoot": docRoot
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
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try body.write(to: URL(fileURLWithPath: path))
            print("[HTTP] 📤 PUT \(path) (\(body.count) bytes)")
            return .created()
        } catch {
            print("[HTTP] ❌ PUT 失败: \(error)")
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

    // MARK: - 辅助

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

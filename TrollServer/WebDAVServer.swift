import Foundation
import UIKit
import Network

// ============================================================
//  WebDAV/HTTP 文件服务器 - 端口 51111
//  替代 Filza WebDAV（11111），避免端口冲突
//  完整支持：GET/PUT/MKCOL/PROPFIND/DELETE
//  + Bonjour 服务发现（mDNS 广播）
//  + HTTP keep-alive 长连接
//  + /api/device 设备信息 JSON API
//  + /api/heartbeat 心跳检测端点
//  + 增强后台持久化（multipath + background service class）
// ============================================================

class WebDAVServer {
    
    private var listener: NWListener?
    private let port: UInt16
    let fileOps: FileOperations
    
    // 统计
    private(set) var isRunning = false
    private(set) var connectionsHandled: Int = 0
    private let statsLock = NSLock()
    private let serverStartTime: Date
    
    // Bonjour 服务名
    private let bonjourServiceName: String
    
    // 设备标识（启动时生成，同一进程内不变）
    private let deviceUUID: String
    private var lastBatteryLevel: Float = -1
    
    init(port: UInt16 = 51111, baseDirectory: String = "/var/mobile/Downloads") {
        self.port = port
        self.fileOps = FileOperations(basePath: baseDirectory)
        self.bonjourServiceName = UIDevice.current.name
        self.serverStartTime = Date()
        
        // 使用设备唯一标识符，不可用时 fallback 到名称哈希值
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            self.deviceUUID = vendorID
        } else {
            self.deviceUUID = "TS-" + String(abs(bonjourServiceName.hashValue))
        }
        
        // 初始化电池监控（仅在应用模式下有意义）
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.lastBatteryLevel = UIDevice.current.batteryLevel
    }
    
    // MARK: - 启动/停止
    
    // 用于同步 start/stop 操作的串行队列（防止竞态条件）
    private let lifecycleQueue = DispatchQueue(label: "com.trollserver.webdav.lifecycle")
    private var isStopping = false
    
    func start() throws {
        try lifecycleQueue.sync {
            // 防止在停止过程中启动
            guard !isStopping else {
                print("[WebDAV:\(port)] Cannot start: server is stopping")
                return
            }
            guard !isRunning else { return }
            
            // 确保旧 listener 已完全释放
            guard listener == nil else {
                print("[WebDAV:\(port)] Listener already exists, not starting")
                return
            }
            
            let parameters: NWParameters
            
            if isDaemonMode {
                // 守护进程模式：使用保守的 TCP 配置
                parameters = .tcp
                parameters.allowLocalEndpointReuse = true
                parameters.acceptLocalOnly = false
                parameters.includePeerToPeer = true
            } else {
                // 应用模式：启用后台增强
                parameters = .tcp
                parameters.allowLocalEndpointReuse = true
                parameters.acceptLocalOnly = false
                parameters.includePeerToPeer = true
                if #available(iOS 14.0, *) {
                    parameters.multipathServiceType = .interactive
                }
                if #available(iOS 14.0, *) {
                    parameters.serviceClass = .background
                }
            }
            
            try _doStart(parameters: parameters)
        }
    }
    
    /// 在 lifecycleQueue 内执行的实际启动
    private func _doStart(parameters: NWParameters) throws {
        
        // ===== 安全化 Bonjour 服务名 =====
        // iOS 设备名可能含中文/表情/特殊字符，需清理为合法 DNS 名
        // 仅保留 ASCII 字母数字和连字符，替换空格为连字符
        var safeName = bonjourServiceName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        if safeName.isEmpty {
            safeName = "TrollServer"
        }
        if safeName.count > 63 {
            safeName = String(safeName.prefix(63))
        }
        
        // Bonjour TXT 记录：携带设备 UUID 和版本信息，方便客户端识别
        let txtDict: [String: String] = [
            "uuid": deviceUUID,
            "v": "1.0",
            "type": "TrollServer",
            "port": "\(port)"
        ]
        let txtRecord = NWTXTRecord(txtDict)
        let service = NWListener.Service(
            name: safeName,
            type: "_http._tcp.",
            domain: "local.",
            txtRecord: txtRecord
        )
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener?.service = service
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WebDAV:\(self?.port ?? 0)] Server ready (Bonjour: \(self?.bonjourServiceName ?? ""), UUID: \(self?.deviceUUID ?? "?"))")
                self?.isRunning = true
                // 启动电池轮询（仅应用模式，守护进程模式不需要）
                self?.startBatteryPollingIfNeeded()
            case .failed(let error):
                print("[WebDAV:\(self?.port ?? 0)] Failed: \(error)")
                self?.isRunning = false
            case .cancelled:
                print("[WebDAV:\(self?.port ?? 0)] Cancelled")
                self?.isRunning = false
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: .global(qos: .userInitiated))
    }
    
    func stop() {
        lifecycleQueue.async { [weak self] in
            guard let self = self, !self.isStopping else { return }
            self.isStopping = true
            
            if let l = self.listener {
                let sem = DispatchSemaphore(value: 0)
                var cancelDone = false
                l.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        cancelDone = true
                        sem.signal()
                    }
                }
                l.cancel()
                // 等待 cancel 完成，最多等 3 秒
                let timeout: DispatchTime = .now() + 3.0
                lifecycleQueue.asyncAfter(deadline: timeout) {
                    if !cancelDone { sem.signal() }
                }
                sem.wait()
                self.listener = nil
                print("[WebDAV:\(self.port)] Server fully stopped")
            }
            
            self.isRunning = false
            self.isStopping = false
        }
    }
    
    /// 同步停止（调用方会等待 stop 完成，最多 3 秒）
    func stopSync() {
        let sem = DispatchSemaphore(value: 0)
        stopWithCompletion { sem.signal() }
        _ = sem.wait(timeout: .now() + 5.0)
    }
    
    /// 带完成回调的停止
    func stopWithCompletion(_ completion: @escaping () -> Void) {
        lifecycleQueue.async { [weak self] in
            defer { completion() }
            guard let self = self, !self.isStopping else { return }
            self.isStopping = true
            
            if let l = self.listener {
                let sem = DispatchSemaphore(value: 0)
                var cancelDone = false
                l.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        cancelDone = true
                        sem.signal()
                    }
                }
                l.cancel()
                _ = sem.wait(timeout: .now() + 3.0)
                if !cancelDone {
                    print("[WebDAV:\(self.port)] ⚠️ Stop timeout, forcing nil")
                }
                self.listener = nil
                print("[WebDAV:\(self.port)] Server fully stopped")
            }
            
            self.isRunning = false
            self.isStopping = false
        }
    }
    
    // MARK: - 电池轮询（仅应用模式，守护进程模式跳过）
    
    private let isDaemonMode: Bool = CommandLine.arguments.contains("--daemon")
    
    private func startBatteryPollingIfNeeded() {
        // ⚠️ 守护进程模式没有 UIApplication，不能调用 UIApplication.shared（会 crash）
        guard !isDaemonMode else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        _ = refreshBatteryLevel()
    }
    
    private func refreshBatteryLevel() -> Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            lastBatteryLevel = level
        }
        return lastBatteryLevel
    }
    
    // MARK: - 获取服务器运行时长
    
    var uptime: TimeInterval {
        return Date().timeIntervalSince(serverStartTime)
    }
    
    // MARK: - 连接处理
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // 直接进入接收循环（全局异常保护由 main.swift 的 NSSetUncaughtExceptionHandler 提供）
                self?.receiveData(connection)
            case .failed(let error):
                print("[WebDAV] Connection failed: \(error)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    /// 数据接收循环（修复版）
    /// 核心修复：PUT/PROPFIND 等有 body 的请求不再依赖不可靠的 isComplete 标志，
    /// 而是严格基于 Content-Length 判断 body 是否接收完整。
    /// 同时支持 HTTP keep-alive：响应发送后不立即关闭连接，允许复用。
    private func receiveData(_ connection: NWConnection, isKeepAlive: Bool = true) {
        var accumulatedData = Data()
        var expectedContentLength: Int? = nil
        var requestMethod: String = ""
        var wantsKeepAlive: Bool = true
        let readTimeout: TimeInterval = 45.0 // 单次连接读取超时
        var timedOut = false
        
        // 启动超时检测
        let timeoutWorkItem = DispatchWorkItem { [weak connection] in
            print("[WebDAV] Read timeout after \(readTimeout)s, closing connection")
            timedOut = true
            connection?.cancel()
        }
        
        func resetReadTimeout() {
            timeoutWorkItem.cancel()
            // 使用 asyncAfter 做超时控制
            DispatchQueue.global().asyncAfter(deadline: .now() + readTimeout, execute: DispatchWorkItem(block: {
                if !timedOut {
                    print("[WebDAV] Connection idle timeout")
                    timedOut = true
                    connection.cancel()
                }
            }))
        }
        
        func readNext() {
            guard !timedOut else { return }
            
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { connection.cancel(); return }
                guard !timedOut else { return }
                
                if let error = error {
                    // NWError 的 posix 码 54/ECONNRESET 是正常的连接重置（客户端主动断开）
                    let nsErr = error as NSError
                    if nsErr.domain == "NWErrorDomain" && (nsErr.code == 54 || nsErr.code == 61) {
                        // ECONNRESET (54) / ECONNREFUSED (61) → 静默关闭
                        print("[WebDAV] Connection reset by client (normal close)")
                    } else {
                        print("[WebDAV] Receive error: \(error) (domain=\(nsErr.domain) code=\(nsErr.code))")
                    }
                    connection.cancel()
                    return
                }
                
                if let data = data {
                    accumulatedData.append(data)
                }
                
                let headerEndRange = accumulatedData.range(of: Data("\r\n\r\n".utf8))
                let headerSize = headerEndRange?.upperBound ?? 0
                let headerComplete = headerSize > 0
                
                // 首次读取到完整头部时解析元数据
                if expectedContentLength == nil, headerComplete {
                    let headerData = accumulatedData.subdata(in: 0..<headerEndRange!.lowerBound)
                    if let headerStr = String(data: headerData, encoding: .utf8) {
                        // 解析请求方法
                        if let firstLine = headerStr.components(separatedBy: "\r\n").first {
                            requestMethod = firstLine.components(separatedBy: " ").first ?? ""
                        }
                        
                        // 解析 Content-Length 和 Connection 头
                        for line in headerStr.components(separatedBy: "\r\n") {
                            let lower = line.lowercased()
                            if lower.hasPrefix("content-length:") {
                                let val = line.components(separatedBy: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)
                                expectedContentLength = Int(val)
                            }
                            if lower.hasPrefix("connection:") {
                                let val = line.components(separatedBy: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces).lowercased()
                                wantsKeepAlive = (val == "keep-alive")
                            }
                        }
                        
                        // 无 body 方法：header 结束即请求完成
                        let noBodyMethods = Set(["GET", "HEAD", "OPTIONS", "DELETE", "MKCOL"])
                        if noBodyMethods.contains(requestMethod) {
                            expectedContentLength = 0
                        }
                    }
                }
                
                // ===== 核心修复：请求完成判定逻辑 =====
                // 以前依赖 isComplete（NWConnection 的 TCP FIN 标志），这在以下场景不可靠：
                // 1. keep-alive 连接：客户端发送完请求后不关闭 TCP 连接
                // 2. iOS NWConnection bug：isComplete 可能在不该为 true 时为 true
                //
                // 修复：严格基于 Content-Length 判断
                //  - 有 Content-Length → body 收齐即完成（不依赖 isComplete）
                //  - 无 Content-Length 且无 body 方法 → header 完整即完成
                //  - PUT 无 Content-Length（理论上不应出现）→ 依赖 isComplete fallback
                
                let expectedBody = expectedContentLength ?? 0
                let receivedBody = accumulatedData.count - headerSize
                
                // 主判定：根据 Content-Length 判断 body 是否收齐
                let bodyComplete = (expectedContentLength != nil && receivedBody >= expectedBody)
                
                // 仅当 Content-Length 未知时才 fallback 到 isComplete
                // 这是关键修复：不让 isComplete 抢占判定
                let fallbackComplete = (expectedContentLength == nil && headerComplete && isComplete && accumulatedData.count > headerSize)
                
                let requestComplete = headerComplete && (bodyComplete || fallbackComplete)
                
                if requestComplete {
                    // 完整接收，解析并处理请求
                    guard let request = HTTPRequest.parse(from: accumulatedData) else {
                        let resp = HTTPResponse.internalServerError("Bad Request")
                        self.sendResponse(resp, on: connection, keepAlive: false)
                        return
                    }
                    
                    self.statsLock.lock()
                    self.connectionsHandled += 1
                    self.statsLock.unlock()
                    
                    print("[WebDAV] \(request.method) \(request.pathWithoutQuery) (\(accumulatedData.count) bytes, keep-alive: \(wantsKeepAlive))")
                    
                    let response = self.route(request)
                    
                    // 只有客户端也想要 keep-alive 时才复用连接
                    let doKeepAlive = wantsKeepAlive
                    self.sendResponse(response, on: connection, keepAlive: doKeepAlive) {
                        if doKeepAlive {
                            // keep-alive：继续在此连接上读取下一个请求
                            self.receiveData(connection, isKeepAlive: true)
                        }
                    }
                } else if headerComplete && !isComplete && expectedContentLength != nil && receivedBody < expectedBody {
                    // 还有 body 未接收完 → 继续等待（即使 isComplete=false）
                    // 这是修复的关键：不因 isComplete 为 false 而恐慌，继续读取
                    resetReadTimeout()
                    readNext()
                } else if isComplete && !bodyComplete && expectedContentLength == nil {
                    // 没有 Content-Length 但有数据，isComplete=true → 完成
                    guard let request = HTTPRequest.parse(from: accumulatedData) else {
                        connection.cancel()
                        return
                    }
                    
                    self.statsLock.lock()
                    self.connectionsHandled += 1
                    self.statsLock.unlock()
                    
                    let response = self.route(request)
                    self.sendResponse(response, on: connection, keepAlive: false)
                } else {
                    // 继续接收数据
                    resetReadTimeout()
                    readNext()
                }
            }
        }
        
        // 启动首次读取
        resetReadTimeout()
        readNext()
    }
    
    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool, onSent: (() -> Void)? = nil) {
        var responseData = response.serialize()
        
        // 如果是 keep-alive，在响应头部添加 Connection: keep-alive
        if keepAlive {
            if let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) {
                let headersPart = responseData.subdata(in: 0..<headerEnd.lowerBound)
                let bodyPart = responseData.subdata(in: headerEnd.upperBound..<responseData.count)
                
                if let headersStr = String(data: headersPart, encoding: .utf8) {
                    var newHeaders = headersStr
                    // 确保最后一行结束前插入 Connection 头
                    if !newHeaders.lowercased().contains("connection:") {
                        newHeaders = newHeaders.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                        + "\r\nConnection: keep-alive\r\nKeep-Alive: timeout=30, max=50\r\n"
                    }
                    if let newHeaderData = newHeaders.data(using: .utf8) {
                        responseData = newHeaderData + Data("\r\n".utf8) + bodyPart
                    }
                }
            }
        }
        
        connection.send(content: responseData, completion: .contentProcessed({ error in
            if let error = error {
                print("[WebDAV] Send error: \(error)")
                connection.cancel()
            } else if keepAlive {
                onSent?()
            } else {
                connection.cancel()
            }
        }))
    }
    
    // MARK: - 路由
    
    private func route(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case "GET":
            return handleGET(request)
        case "PUT":
            return handlePUT(request)
        case "MKCOL":
            return handleMKCOL(request)
        case "PROPFIND":
            return handlePROPFIND(request)
        case "DELETE":
            return handleDELETE(request)
        case "HEAD":
            return handleHEAD(request)
        case "OPTIONS":
            return handleOPTIONS(request)
        default:
            return HTTPResponse.methodNotAllowed()
        }
    }
    
    // MARK: - GET - 读取文件 / 列目录 / API端点
    
    private func handleGET(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        // ─────────── API 端点 ───────────
        
        // /api/device - JSON 设备信息（供中控获取详细设备数据）
        if path == "/api/device" {
            return handleAPIDevice()
        }
        
        // /api/heartbeat - 心跳检测（供中控定期探测设备在线状态）
        if path == "/api/heartbeat" {
            return handleAPIHeartbeat()
        }
        
        // /api/status - 服务器状态摘要
        if path == "/api/status" {
            return handleAPIStatus()
        }
        
        // ─────────── 文件服务 ───────────
        
        // 根路径 - 设备存活检测（与中控 verifyDevice 兼容）
        if path == "/" {
            let info = deviceInfo()
            let html = """
            <html><body>
            <h1>TrollServer WebDAV</h1>
            <p>Device: \(info["name"] ?? "iOS")</p>
            <p>Version: \(info["version"] ?? "?")</p>
            <p>Base: \(fileOps.basePath)</p>
            <p>Port: \(port)</p>
            <p>UUID: \(deviceUUID)</p>
            </body></html>
            """
            return HTTPResponse.ok(body: html.data(using: .utf8)!, contentType: "text/html; charset=utf-8")
        }
        
        // 查询参数 ?list=true 列出目录
        if request.queryParameters["list"] == "true" || request.queryParameters["ls"] != nil {
            do {
                let items = try fileOps.listDirectoryDetailed(path)
                let jsonData = try JSONSerialization.data(withJSONObject: items, options: .prettyPrinted)
                return HTTPResponse.ok(body: jsonData, contentType: "application/json; charset=utf-8")
            } catch {
                return HTTPResponse.notFound("Directory not found: \(path)")
            }
        }
        
        // 判断是否为目录
        if fileOps.isDirectory(path) {
            do {
                let names = try fileOps.listDirectory(path)
                let html = names.map { "<li><a href=\"\(path)/\($0)\">\($0)</a></li>" }.joined()
                return HTTPResponse.ok(body: """
                <html><body><h2>\(path)</h2><ul>\(html)</ul></body></html>
                """.data(using: .utf8)!, contentType: "text/html; charset=utf-8")
            } catch {
                return HTTPResponse.notFound("Read error: \(error.localizedDescription)")
            }
        }
        
        // 读取文件内容
        do {
            let fileData = try fileOps.readFile(at: path)
            
            // 推断 Content-Type
            let ext = (path as NSString).pathExtension.lowercased()
            let mime = mimeType(for: ext)
            
            return HTTPResponse.ok(body: fileData, contentType: mime)
        } catch {
            return HTTPResponse.notFound("File not found: \(path)")
        }
    }
    
    // MARK: - PUT - 上传/写入文件
    
    private func handlePUT(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        guard !path.isEmpty, path != "/" else {
            return HTTPResponse.internalServerError("Invalid path for PUT")
        }
        
        do {
            try fileOps.writeFile(request.body, to: path)
            print("[WebDAV] PUT success: \(path) (\(request.body.count) bytes)")
            return HTTPResponse.created()
        } catch FileError.pathTraversal {
            print("[WebDAV] PUT blocked: path traversal attempt on \(path)")
            return HTTPResponse(statusCode: 403, statusMessage: "Forbidden", headers: [:], body: "Path traversal denied".data(using: .utf8)!)
        } catch {
            let nsErr = error as NSError
            // 区分无权限/磁盘满 和 一般错误
            if nsErr.domain == NSCocoaErrorDomain {
                switch nsErr.code {
                case 513: // NSFileWriteNoPermissionError
                    print("[WebDAV] PUT permission denied: \(path)")
                    return HTTPResponse(statusCode: 403, statusMessage: "Forbidden",
                        headers: [:], body: "Permission denied: \(error.localizedDescription)".data(using: .utf8)!)
                case 640: // NSFileWriteOutOfSpaceError
                    print("[WebDAV] PUT out of space: \(path)")
                    return HTTPResponse(statusCode: 507, statusMessage: "Insufficient Storage",
                        headers: [:], body: "Disk full".data(using: .utf8)!)
                default:
                    break
                }
            }
            print("[WebDAV] PUT error: \(path) -> \(error)")
            return HTTPResponse.internalServerError("Write failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - MKCOL - 创建目录
    
    private func handleMKCOL(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        guard !path.isEmpty, path != "/" else {
            return HTTPResponse.internalServerError("Invalid path for MKCOL")
        }
        
        // 目录已存在 → 201 Created（WebDAV 标准）
        if fileOps.isDirectory(path) {
            return HTTPResponse.created()
        }
        
        // 检查父目录是否存在（给客户端更精确的错误信息）
        let parentPath = (path as NSString).deletingLastPathComponent
        if !parentPath.isEmpty && parentPath != "/" {
            let parentExists = fileOps.exists(parentPath)
            if !parentExists {
                // 父目录不存在，尝试创建父目录
                print("[WebDAV] MKCOL parent missing, creating: \(parentPath)")
                do {
                    try fileOps.createDirectory(parentPath)
                } catch {
                    print("[WebDAV] MKCOL cannot create parent \(parentPath): \(error)")
                    // 继续尝试创建目标目录（createDirectory 本身就是递归的）
                }
            }
        }
        
        do {
            try fileOps.createDirectory(path)
            print("[WebDAV] MKCOL success: \(path)")
            return HTTPResponse.created()
        } catch FileError.notADirectory {
            return HTTPResponse.internalServerError("Path exists but is not a directory")
        } catch FileError.pathTraversal {
            return HTTPResponse(statusCode: 403, statusMessage: "Forbidden", headers: [:], body: "Path traversal denied".data(using: .utf8)!)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 513 {
                print("[WebDAV] MKCOL permission denied: \(path)")
                return HTTPResponse(statusCode: 403, statusMessage: "Forbidden",
                    headers: [:], body: "Permission denied".data(using: .utf8)!)
            }
            print("[WebDAV] MKCOL error: \(path) -> \(error)")
            return HTTPResponse.internalServerError("Mkdir failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - PROPFIND - WebDAV 属性查询（用于检测目录是否存在）
    
    private func handlePROPFIND(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        _ = request.headers["depth"] ?? "0"
        
        let exists = fileOps.exists(path)
        let isDir = fileOps.isDirectory(path)
        let size = fileOps.fileSize(path)
        let now = ISO8601DateFormatter().string(from: Date())
        
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response>
        <D:href>\(path)</D:href>
        <D:propstat>
        <D:prop>
        <D:resourcetype>\(isDir ? "<D:collection/>" : "")</D:resourcetype>
        <D:getcontentlength>\(size)</D:getcontentlength>
        <D:getlastmodified>\(now)</D:getlastmodified>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>
        </D:multistatus>
        """
        
        if exists {
            return HTTPResponse.multiStatus(xml)
        } else {
            return HTTPResponse.notFound("Resource not found")
        }
    }
    
    // MARK: - DELETE - 删除文件
    
    private func handleDELETE(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        guard !path.isEmpty, path != "/" else {
            return HTTPResponse.internalServerError("Cannot delete root")
        }
        
        do {
            try fileOps.deleteItem(path)
            print("[WebDAV] DELETE success: \(path)")
            return HTTPResponse(statusCode: 204, statusMessage: "No Content", headers: [:], body: Data())
        } catch {
            return HTTPResponse.internalServerError("Delete failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - HEAD - 文件头信息
    
    private func handleHEAD(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        if !fileOps.exists(path) {
            return HTTPResponse.notFound()
        }
        
        let size = fileOps.fileSize(path)
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = mimeType(for: ext)
        
        return HTTPResponse(
            statusCode: 200, statusMessage: "OK",
            headers: ["Content-Type": mime, "Content-Length": "\(size)"],
            body: Data()
        )
    }
    
    // MARK: - OPTIONS - CORS 预检
    
    private func handleOPTIONS(_ request: HTTPRequest) -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200, statusMessage: "OK",
            headers: [
                "Allow": "GET, PUT, MKCOL, PROPFIND, DELETE, HEAD, OPTIONS",
                "DAV": "1",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, PUT, MKCOL, PROPFIND, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Depth, Content-Type, Authorization"
            ],
            body: Data()
        )
    }
    
    // MARK: - API 端点实现
    
    /// GET /api/device - 返回设备详细信息的 JSON
    private func handleAPIDevice() -> HTTPResponse {
        _ = refreshBatteryLevel()
        let info = deviceInfo()
        let batteryPercent: Int
        if lastBatteryLevel < 0 {
            batteryPercent = -1 // 未知
        } else {
            batteryPercent = Int(lastBatteryLevel * 100)
        }
        
        let deviceDict: [String: Any] = [
            "uuid": deviceUUID,
            "name": info["name"] ?? UIDevice.current.name,
            "model": info["model"] ?? UIDevice.current.model,
            "systemVersion": info["version"] ?? UIDevice.current.systemVersion,
            "wifiIP": info["wifiIP"] ?? "",
            "battery": batteryPercent,
            "serverUptime": Int(uptime),
            "basePath": fileOps.basePath,
            "port": port,
            "connectionsHandled": connectionsHandled,
            "version": "1.0"
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: deviceDict, options: .prettyPrinted),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return HTTPResponse.internalServerError("JSON serialization failed")
        }
        
        return HTTPResponse.okJson(jsonStr)
    }
    
    /// GET /api/heartbeat - 轻量心跳响应
    private func handleAPIHeartbeat() -> HTTPResponse {
        let heartbeatDict: [String: Any] = [
            "status": "alive",
            "timestamp": Int(Date().timeIntervalSince1970),
            "uptime": Int(uptime)
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: heartbeatDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return HTTPResponse.okText("OK")
        }
        
        return HTTPResponse.okJson(jsonStr)
    }
    
    /// GET /api/status - 服务器运行状态摘要
    private func handleAPIStatus() -> HTTPResponse {
        statsLock.lock()
        let conn = connectionsHandled
        statsLock.unlock()
        
        let statusDict: [String: Any] = [
            "running": isRunning,
            "connectionsHandled": conn,
            "uptime": Int(uptime),
            "basePath": fileOps.basePath,
            "port": port,
            "version": "1.0"
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: statusDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return HTTPResponse.internalServerError("JSON serialization failed")
        }
        
        return HTTPResponse.okJson(jsonStr)
    }
    
    // MARK: - 工具函数
    
    private func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "txt", "log":  return "text/plain; charset=utf-8"
        case "xml", "plist": return "application/xml; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "pdf":         return "application/pdf"
        case "zip":         return "application/zip"
        case "ipa":         return "application/octet-stream"
        case "deb":         return "application/x-debian-package"
        case "dylib":       return "application/octet-stream"
        default:            return "application/octet-stream"
        }
    }
    
    private func deviceInfo() -> [String: String] {
        let device = UIDevice.current
        var info: [String: String] = [
            "name": device.name,
            "model": device.model,
            "version": device.systemVersion,
            "identifier": "TrollServer/1.0"
        ]
        
        // 获取 WiFi IP
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let flags = Int32(ptr!.pointee.ifa_flags)
                let addr = ptr!.pointee.ifa_addr
                if addr?.pointee.sa_family == UInt8(AF_INET),
                   (flags & IFF_UP) != 0 {
                    let name = String(cString: ptr!.pointee.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(addr, socklen_t(addr!.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, 0, NI_NUMERICHOST)
                        info["wifiIP"] = String(cString: hostname)
                    }
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        
        return info
    }
    
    func getStats() -> (connections: Int, port: UInt16, basePath: String, running: Bool, uptime: TimeInterval, uuid: String) {
        statsLock.lock()
        let conn = connectionsHandled
        statsLock.unlock()
        return (conn, port, fileOps.basePath, isRunning, uptime, deviceUUID)
    }
}

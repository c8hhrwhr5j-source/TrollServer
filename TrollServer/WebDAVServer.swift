import Foundation
import UIKit
import Network

// ============================================================
//  WebDAV/HTTP 文件服务器 - 端口 51111
//  替代 Filza WebDAV（11111），避免端口冲突
//  完整支持：GET/PUT/MKCOL/PROPFIND/DELETE
// ============================================================

class WebDAVServer {
    
    private var listener: NWListener?
    private let port: UInt16
    let fileOps: FileOperations
    
    // 统计
    private(set) var isRunning = false
    private(set) var connectionsHandled: Int = 0
    private let statsLock = NSLock()
    
    init(port: UInt16 = 51111, baseDirectory: String = "/var/mobile/Downloads") {
        self.port = port
        self.fileOps = FileOperations(basePath: baseDirectory)
    }
    
    // MARK: - 启动/停止
    
    func start() throws {
        guard !isRunning else { return }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 快速回收端口
        parameters.acceptLocalOnly = false
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WebDAV:\(self?.port ?? 0)] Server ready")
                self?.isRunning = true
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
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    // MARK: - 连接处理
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveData(connection)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    private func receiveData(_ connection: NWConnection) {
        var accumulatedData = Data()
        var expectedContentLength: Int? = nil
        
        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { connection.cancel(); return }
                
                if let error = error {
                    print("[WebDAV] Receive error: \(error)")
                    connection.cancel()
                    return
                }
                
                if let data = data {
                    accumulatedData.append(data)
                }
                
                // 首次读取时解析 Content-Length
                if expectedContentLength == nil,
                   let headerEnd = accumulatedData.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = accumulatedData.subdata(in: 0..<headerEnd.lowerBound)
                    if let headerStr = String(data: headerData, encoding: .utf8) {
                        for line in headerStr.components(separatedBy: "\r\n") {
                            let lower = line.lowercased()
                            if lower.hasPrefix("content-length:") {
                                let val = line.components(separatedBy: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)
                                expectedContentLength = Int(val)
                            }
                        }
                    }
                }
                
                // 判断是否接收完毕
                let headerSize = accumulatedData.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? 0
                let expectedBody = expectedContentLength ?? 0
                let receivedBody = accumulatedData.count - headerSize
                
                if isComplete || (expectedContentLength != nil && receivedBody >= expectedBody) {
                    // 完整接收，解析并处理请求
                    guard let request = HTTPRequest.parse(from: accumulatedData) else {
                        let resp = HTTPResponse.internalServerError("Bad Request")
                        self.sendResponse(resp, on: connection)
                        return
                    }
                    
                    self.statsLock.lock()
                    self.connectionsHandled += 1
                    self.statsLock.unlock()
                    
                    print("[WebDAV] \(request.method) \(request.pathWithoutQuery) (\(accumulatedData.count) bytes)")
                    
                    let response = self.route(request)
                    self.sendResponse(response, on: connection)
                } else {
                    // 继续接收
                    readNext()
                }
            }
        }
        
        readNext()
    }
    
    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
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
    
    // MARK: - GET - 读取文件 / 列目录
    
    private func handleGET(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
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
        } catch {
            print("[WebDAV] PUT error: \(error)")
            return HTTPResponse.internalServerError("Write failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - MKCOL - 创建目录
    
    private func handleMKCOL(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        
        guard !path.isEmpty, path != "/" else {
            return HTTPResponse.internalServerError("Invalid path for MKCOL")
        }
        
        do {
            try fileOps.createDirectory(path)
            print("[WebDAV] MKCOL success: \(path)")
            return HTTPResponse.created()
        } catch {
            print("[WebDAV] MKCOL error: \(error)")
            return HTTPResponse.internalServerError("Mkdir failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - PROPFIND - WebDAV 属性查询（用于检测目录是否存在）
    
    private func handlePROPFIND(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.pathWithoutQuery
        let depth = request.headers["depth"] ?? "0"
        
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
    
    func getStats() -> (connections: Int, port: UInt16, basePath: String, running: Bool) {
        statsLock.lock()
        let conn = connectionsHandled
        statsLock.unlock()
        return (conn, port, fileOps.basePath, isRunning)
    }
}

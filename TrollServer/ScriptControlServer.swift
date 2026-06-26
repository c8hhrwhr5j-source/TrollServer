import Foundation
import Network

// ============================================================
//  脚本控制服务器 - 端口 8989
//  此端口供外部独立脚本 APP 使用，本模块仅预留通信接口
//  实际脚本执行由另一 APP 通过 localhost:8899 桥接
// ============================================================

class ScriptControlServer {
    
    private var listener: NWListener?
    private let port: UInt16
    private let forwardPort: UInt16
    private let forwardHost = "127.0.0.1"
    
    private(set) var isRunning = false
    
    init(port: UInt16 = 8989, forwardPort: UInt16 = 8899) {
        self.port = port
        self.forwardPort = forwardPort
    }
    
    // MARK: - 启动
    
    private let lifecycleQueue = DispatchQueue(label: "com.trollserver.script.lifecycle")
    private var isStopping = false
    
    func start() throws {
        try lifecycleQueue.sync {
            guard !isStopping else {
                print("[ScriptCtrl:\(port)] Cannot start: server is stopping")
                return
            }
            guard !isRunning else { return }
            guard listener == nil else {
                print("[ScriptCtrl:\(port)] Listener already exists, not starting")
                return
            }
            
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[ScriptCtrl:\(self?.port ?? 0)] Server ready (forwarding to :\(self?.forwardPort ?? 0))")
                    self?.isRunning = true
                case .failed(let error):
                    print("[ScriptCtrl:\(self?.port ?? 0)] Failed: \(error)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
        }
    }
    
    func stop() {
        lifecycleQueue.async { [weak self] in
            guard let self = self, !self.isStopping else { return }
            self.isStopping = true
            
            if let l = self.listener {
                let sem = DispatchSemaphore(value: 0)
                l.stateUpdateHandler = { state in
                    if case .cancelled = state { sem.signal() }
                }
                l.cancel()
                _ = sem.wait(timeout: .now() + 3.0)
                self.listener = nil
                print("[ScriptCtrl:\(self.port)] Server fully stopped")
            }
            
            self.isRunning = false
            self.isStopping = false
        }
    }
    
    /// 同步停止（调用方等待，最多 3 秒）
    func stopSync() {
        let sem = DispatchSemaphore(value: 0)
        lifecycleQueue.async { [weak self] in
            defer { sem.signal() }
            guard let self = self, !self.isStopping else { return }
            self.isStopping = true
            
            if let l = self.listener {
                let canceledSem = DispatchSemaphore(value: 0)
                l.stateUpdateHandler = { state in
                    if case .cancelled = state { canceledSem.signal() }
                }
                l.cancel()
                _ = canceledSem.wait(timeout: .now() + 3.0)
                self.listener = nil
                print("[ScriptCtrl:\(self.port)] Server fully stopped (sync)")
            }
            
            self.isRunning = false
            self.isStopping = false
        }
        _ = sem.wait(timeout: .now() + 5.0)
    }
    
    // MARK: - 连接处理：转发到本地脚本 APP
    
    private func handleConnection(_ clientConn: NWConnection) {
        clientConn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.forwardToScriptApp(clientConn)
            case .failed, .cancelled:
                clientConn.cancel()
            default:
                break
            }
        }
        clientConn.start(queue: .global(qos: .userInitiated))
    }
    
    /// 从客户端接收完整 HTTP 请求，原样转发到 localhost:8899 的脚本 APP
    /// 循环接收直到请求完整，避免 POST body 或分片 header 被截断
    private func forwardToScriptApp(_ clientConn: NWConnection) {
        var accumulatedData = Data()
        var expectedContentLength: Int? = nil
        
        func readNext() {
            clientConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { clientConn.cancel(); return }
                
                if error != nil {
                    clientConn.cancel()
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
                        // 无 body 请求方法直接视为 body 长度为 0
                        if let firstLine = headerStr.components(separatedBy: "\r\n").first {
                            let method = firstLine.components(separatedBy: " ").first ?? ""
                            if method == "GET" || method == "HEAD" || method == "OPTIONS" || method == "DELETE" {
                                expectedContentLength = 0
                            }
                        }
                    }
                }
                
                // 判断请求是否接收完整
                let headerEnd = accumulatedData.range(of: Data("\r\n\r\n".utf8))
                let headerSize = headerEnd?.upperBound ?? 0
                let headerComplete = headerSize > 0
                let expectedBody = expectedContentLength ?? 0
                let receivedBody = accumulatedData.count - headerSize
                let bodyComplete = (expectedContentLength != nil && receivedBody >= expectedBody)
                let requestComplete = headerComplete && (isComplete || bodyComplete)
                
                if requestComplete {
                    self.doForward(clientConn, data: accumulatedData)
                } else {
                    readNext()
                }
            }
        }
        
        readNext()
    }
    
    /// 将完整请求数据转发到本地脚本 APP
    private func doForward(_ clientConn: NWConnection, data: Data) {
        // 建立到本地脚本 APP 的连接
        let scriptHost = NWEndpoint.Host(self.forwardHost)
        let scriptPort = NWEndpoint.Port(integerLiteral: self.forwardPort)
        
        let scriptConn = NWConnection(
            host: scriptHost,
            port: scriptPort,
            using: .tcp
        )
        
        scriptConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // 转发完整请求到脚本 APP
                scriptConn.send(content: data, completion: .contentProcessed({ _ in
                    // 接收脚本 APP 的响应并转发回客户端
                    scriptConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { respData, _, _, _ in
                        if let resp = respData {
                            clientConn.send(content: resp, completion: .contentProcessed({ _ in
                                clientConn.cancel()
                            }))
                        } else {
                            clientConn.cancel()
                        }
                        scriptConn.cancel()
                    }
                }))
            case .failed:
                // 脚本 APP 未运行，返回 503
                let errorResp = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 28\r\n\r\nScript app not running on :8899"
                clientConn.send(content: errorResp.data(using: .utf8)!, completion: .contentProcessed({ _ in
                    clientConn.cancel()
                }))
                scriptConn.cancel()
            case .cancelled:
                clientConn.cancel()
            default:
                break
            }
        }
        
        scriptConn.start(queue: .global())
    }
    
    func getStatus() -> (port: UInt16, forwardTo: String, running: Bool) {
        return (port, "\(forwardHost):\(forwardPort)", isRunning)
    }
}

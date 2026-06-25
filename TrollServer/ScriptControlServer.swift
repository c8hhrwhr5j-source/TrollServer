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
    
    func start() throws {
        guard !isRunning else { return }
        
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
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
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
    
    /// 从客户端接收 HTTP 请求，原样转发到 localhost:8899 的脚本 APP
    private func forwardToScriptApp(_ clientConn: NWConnection) {
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, !data.isEmpty, error == nil else {
                clientConn.cancel()
                return
            }
            
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
                    // 转发请求到脚本 APP
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
    }
    
    func getStatus() -> (port: UInt16, forwardTo: String, running: Bool) {
        return (port, "\(forwardHost):\(forwardPort)", isRunning)
    }
}

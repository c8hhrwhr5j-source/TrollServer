import Foundation
import Network

// ============================================================
//  IPA 安装 API 服务器 - 端口 8081
//  接收 POST /install {"url": "https://..."} ，下载并安装 IPA
// ============================================================

class InstallAPI {

    private var listener: NWListener?
    private let port: UInt16
    private(set) var isRunning = false

    /// 找到的可用 helper 路径（委托给 SilentInstall）
    private var availableHelper: String? {
        return SilentInstall.findTrollStoreHelper()
    }

    init(port: UInt16 = 8081) {
        self.port = port
    }

    // MARK: - 启动 / 停止

    func start() throws {
        guard !isRunning else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[InstallAPI:\(self?.port ?? 0)] Ready")
                self?.isRunning = true
            case .failed(let error):
                print("[InstallAPI:\(self?.port ?? 0)] Failed: \(error)")
                self?.isRunning = false
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 连接处理

    private func handleConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
                    guard let self = self, let data = data, error == nil else {
                        conn.cancel()
                        return
                    }
                    self.processRequest(data, on: conn)
                }
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - 请求处理

    private func processRequest(_ raw: Data, on conn: NWConnection) {
        guard let request = String(data: raw, encoding: .utf8) else {
            sendResponse(conn, status: 400, body: jsonError("Invalid UTF-8"))
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(conn, status: 400, body: jsonError("Empty request"))
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(conn, status: 400, body: jsonError("Bad request line"))
            return
        }

        let method = parts[0].uppercased()
        let path = parts[1]

        // 找空行分隔头部和正文
        var body = ""
        var inBody = false
        for line in lines {
            if inBody {
                body += line
            }
            if line.isEmpty && !inBody {
                inBody = true
            }
        }

        if method == "POST" && path == "/install" {
            handleInstall(body: body, on: conn)
        } else {
            sendResponse(conn, status: 404, body: jsonError("Not found, use POST /install"))
        }
    }

    // MARK: - 安装处理

    private func handleInstall(body: String, on conn: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = json["url"] as? String,
              let url = URL(string: urlStr) else {
            sendResponse(conn, status: 400, body: jsonError("Missing or invalid 'url' in JSON body"))
            return
        }

        print("[InstallAPI] Downloading: \(urlStr)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] localURL, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[InstallAPI] Download failed: \(error)")
                self.sendResponse(conn, status: 500, body: jsonError("Download failed: \(error.localizedDescription)"))
                return
            }

            guard let localURL = localURL else {
                self.sendResponse(conn, status: 500, body: jsonError("No file downloaded"))
                return
            }

            // 把下载的文件移到稳定位置
            let fileName = url.lastPathComponent
            let destDir = "/var/mobile/Documents"
            let destPath = "\(destDir)/\(fileName)"

            // 确保目标目录存在
            try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

            // 如果已存在则先删除（覆盖安装）
            if FileManager.default.fileExists(atPath: destPath) {
                try? FileManager.default.removeItem(atPath: destPath)
            }

            do {
                try FileManager.default.moveItem(atPath: localURL.path, toPath: destPath)
                print("[InstallAPI] Downloaded to: \(destPath)")
            } catch {
                print("[InstallAPI] Move failed: \(error)")
                self.sendResponse(conn, status: 500, body: jsonError("Move failed: \(error.localizedDescription)"))
                return
            }

            // 执行静默安装
            SilentInstall.install(ipaPath: destPath, progress: nil) { result in
                switch result {
                case .success(let message, _):
                    self.sendResponse(conn, status: 200, body: self.jsonOK(message))
                case .failure(let message):
                    self.sendResponse(conn, status: 500, body: self.jsonError(message))
                case .progress:
                    break
                }
            }
        }

        task.resume()
    }

    // MARK: - 公开安装方法（供 ViewController 直接调用）

    /// 安装本地 IPA 文件，带进度回调
    func installFromLocalPath(
        _ path: String,
        progress: ((String, String, Int) -> Void)? = nil,
        completion: @escaping (Bool, String) -> Void
    ) {
        // 先做环境检查
        let env = SilentInstall.fullEnvironmentCheck()
        if !env.ok {
            print("[InstallAPI] 环境检查失败:\n\(env.messages.joined(separator: "\n"))")
        }

        SilentInstall.install(
            ipaPath: path,
            progress: { result in
                if case .progress(let phase, let detail, let percent) = result {
                    DispatchQueue.main.async { progress?(phase, detail, percent) }
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let message, _):
                        completion(true, message)
                    case .failure(let message):
                        completion(false, message)
                    case .progress:
                        break
                    }
                }
            }
        )
    }

    /// 简化版：安装本地 IPA（兼容旧接口）
    func installFromLocalPath(_ path: String, completion: @escaping (Bool, String) -> Void) {
        installFromLocalPath(path, progress: nil, completion: completion)
    }

    // MARK: - posix_spawn 辅助（保留用于 handleInstall 中的下载）

    private func spawnAndWait(_ path: String, arguments: [String]) -> Int32 {
        let cargs = arguments.map { strdup($0) }
        defer { cargs.forEach { free($0) } }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, nil, nil, ptr.baseAddress, nil)
        }

        guard ret == 0 else {
            print("[InstallAPI] posix_spawn failed: \(ret)")
            return -1
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0x000000ff
    }

    // MARK: - HTTP 响应构建

    private func sendResponse(_ conn: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default:  statusText = "Unknown"
        }

        let resp = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        if let data = resp.data(using: .utf8) {
            conn.send(content: data, completion: .contentProcessed({ _ in
                conn.cancel()
            }))
        } else {
            conn.cancel()
        }
    }

    private func jsonOK(_ message: String) -> String {
        return #"{"success":true,"message":"\#(message)"}"#
    }

    private func jsonError(_ message: String) -> String {
        return #"{"success":false,"message":"\#(message)"}"#
    }

    func getStatus() -> (port: UInt16, helper: String, running: Bool) {
        return (port, availableHelper ?? "none", isRunning)
    }
}

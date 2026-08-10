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

    /// 辅助二进制文件可能的路径列表
    private let helperPaths = [
        "/var/jb/usr/bin/trollstorehelper",
        "/usr/bin/trollstorehelper",
        "/Applications/TrollStore.app/trollstorehelper",
    ]

    /// 找到的可用 helper 路径
    private var availableHelper: String? {
        for path in helperPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
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
            if state == .ready {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
                    guard let self = self, let data = data, error == nil else {
                        conn.cancel()
                        return
                    }
                    self.processRequest(data, on: conn)
                }
            } else if state == .failed || state == .cancelled {
                conn.cancel()
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

            // 执行安装
            let result = self.installIPA(at: destPath)

            if result.success {
                self.sendResponse(conn, status: 200, body: jsonOK(result.message))
            } else {
                self.sendResponse(conn, status: 500, body: jsonError(result.message))
            }
        }

        task.resume()
    }

    // MARK: - IPA 安装

    private func installIPA(at path: String) -> (success: Bool, message: String) {
        // 策略1: trollstorehelper
        if let helper = availableHelper {
            print("[InstallAPI] Using helper: \(helper)")
            let result = spawnAndWait(helper, arguments: ["install", path])
            if result == 0 {
                return (true, "Installed via trollstorehelper")
            } else {
                print("[InstallAPI] trollstorehelper exit code: \(result)")
                // 不直接失败，继续尝试其他方式
            }
        } else {
            print("[InstallAPI] trollstorehelper not found, trying fallback...")
        }

        // 策略2: 复制到 TrollStore 临时目录（TrollStore 会自动检测并安装）
        let trollStorePaths = [
            "/var/mobile/.TrollStore/tmp/",
            "/var/mobile/Library/Caches/TrollStore/",
        ]
        for tsPath in trollStorePaths {
            let dest = "\(tsPath)\(URL(fileURLWithPath: path).lastPathComponent)"
            do {
                try? FileManager.default.createDirectory(atPath: tsPath, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: path, toPath: dest)
                print("[InstallAPI] Copied to: \(dest)")
                return (true, "Copied to TrollStore directory, check device for install prompt")
            } catch {
                print("[InstallAPI] Copy to \(tsPath) failed: \(error)")
            }
        }

        return (false, "No installation method available. Check trollstorehelper.")
    }

    // MARK: - posix_spawn 辅助

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
        return WEXITSTATUS(status)
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

        conn.send(content: resp.data(using: .utf8)!, completion: .contentProcessed({ _ in
            conn.cancel()
        }))
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

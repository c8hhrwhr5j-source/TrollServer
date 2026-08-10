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

    // MARK: - 公开安装方法（供 ViewController 直接调用）

    /// 安装本地 IPA 文件，回调在主线程
    func installFromLocalPath(_ path: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false, "Internal error") }
                return
            }
            let result = self.installIPA(at: path)
            DispatchQueue.main.async { completion(result.success, result.message) }
        }
    }

    // MARK: - IPA 安装（强制覆盖）

    private func installIPA(at path: String) -> (success: Bool, message: String) {
        // 步骤0: 强制关闭目标应用
        forceKillApp(ipaPath: path)

        // 步骤1: 先尝试卸载旧版本（确保数据清理）
        if let helper = availableHelper {
            if let execName = getExecutableName(fromIPA: path) {
                print("[InstallAPI] 先尝试卸载旧版本: \(execName)")
                let uninstallRet = spawnAndWait(helper, arguments: ["uninstall", execName])
                print("[InstallAPI] 卸载结果 exit code: \(uninstallRet)")
                usleep(500000) // 等 0.5s
            }
        }

        // 步骤2: trollstorehelper install
        if let helper = availableHelper {
            print("[InstallAPI] 使用 helper 安装: \(helper)")
            let result = spawnAndWait(helper, arguments: ["install", path])
            print("[InstallAPI] trollstorehelper install exit code: \(result)")
            if result == 0 {
                // 安装成功后等 1 秒让系统注册
                usleep(1000000)
                return (true, "已通过 trollstorehelper 覆盖安装")
            } else {
                print("[InstallAPI] trollstorehelper install 返回非 0，尝试备用方式...")
            }
        } else {
            print("[InstallAPI] trollstorehelper 未找到，尝试备用方式...")
        }

        // 步骤3: 复制到 TrollStore 检测目录
        let tsCopyTargets = [
            "/var/mobile/.TrollStore/tmp/",
            "/var/mobile/Library/Caches/TrollStore/",
        ]
        for tsPath in tsCopyTargets {
            let dest = "\(tsPath)\(URL(fileURLWithPath: path).lastPathComponent)"
            do {
                try? FileManager.default.createDirectory(atPath: tsPath, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: path, toPath: dest)
                print("[InstallAPI] 已复制到: \(dest)")
                return (true, "已复制到 TrollStore 目录，请切换到 TrollStore 完成安装")
            } catch {
                print("[InstallAPI] 复制到 \(tsPath) 失败: \(error)")
            }
        }

        return (false, "所有安装方式均失败，请检查 TrollStore 是否正常运行")
    }

    /// 多路径查找并执行 killall 强制关闭目标应用
    private func forceKillApp(ipaPath: String) {
        // 尝试从 IPA 中提取可执行文件名
        var targets: [String] = []
        if let execName = getExecutableName(fromIPA: ipaPath) {
            targets.append(execName)
        }

        guard !targets.isEmpty else {
            print("[InstallAPI] 无法获取可执行文件名，跳过 killall")
            return
        }

        // killall 可能的路径列表
        let killallPaths = [
            "/usr/bin/killall",
            "/bin/killall",
            "/usr/sbin/killall",
            "/var/jb/usr/bin/killall",
        ]

        for target in targets {
            // 先尝试直接路径
            var killed = false
            for kp in killallPaths {
                if FileManager.default.fileExists(atPath: kp) {
                    print("[InstallAPI] killall: \(kp) -9 \(target)")
                    let ret = spawnAndWait(kp, arguments: ["-9", target])
                    if ret == 0 {
                        print("[InstallAPI] 成功关闭: \(target)")
                        killed = true
                        break
                    }
                }
            }

            // fallback: 通过 shell 执行
            if !killed {
                print("[InstallAPI] shell killall: \(target)")
                _ = spawnAndWait("/bin/sh", arguments: ["-c", "killall -9 \(target) 2>/dev/null; true"])
                killed = true
            }
        }

        if !targets.isEmpty {
            usleep(500000) // 等 0.5s 确保进程完全退出
        }
    }

    // MARK: - 从 IPA 提取可执行文件名

    /// 从 IPA 中读取 Info.plist 获取 CFBundleExecutable
    private func getExecutableName(fromIPA ipaPath: String) -> String? {
        // 用 unzip -p 输出 Payload/*/Info.plist 的内容（shell 通配符自动展开）
        guard let plistData = spawnAndCapture("/bin/sh", arguments: ["-c", "unzip -p '\(ipaPath)' 'Payload/*/Info.plist' 2>/dev/null"]) else {
            print("[InstallAPI] 无法解压 IPA 获取 Info.plist")
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let execName = plist["CFBundleExecutable"] as? String else {
            print("[InstallAPI] 无法解析 Info.plist")
            return nil
        }

        print("[InstallAPI] 可执行文件名: \(execName)")
        return execName
    }

    /// posix_spawn 并捕获 stdout
    private func spawnAndCapture(_ path: String, arguments: [String]) -> Data? {
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else { return nil }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])

        let cargs = arguments.map { strdup($0) }
        defer {
            cargs.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fileActions)
        }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, &fileActions, nil, ptr.baseAddress, nil)
        }
        close(pipeFD[1])

        guard ret == 0 else { close(pipeFD[0]); return nil }

        var data = Data()
        var status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(pipeFD[0], &buffer, buffer.count)
            if n > 0 {
                data.append(buffer, count: n)
            } else {
                break
            }
        }
        close(pipeFD[0])

        waitpid(pid, &status, 0)
        return data.isEmpty ? nil : data
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

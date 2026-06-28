import Foundation

// ============================================================
//  TrollServerClient - App 模式下与 daemon 通信的客户端
//
//  当 App 检测到 daemon 已在运行后，通过此客户端连接
//  localhost:51111 获取状态和控制脚本。
//
//  这样 App 就不需要自己 bind 端口了。
// ============================================================

final class TrollServerClient {

    static let shared = TrollServerClient()

    private let baseURL = "http://127.0.0.1:51111"
    private let timeout: TimeInterval = 5.0

    private init() {}

    // ===================== 状态模型 =====================

    struct ServerStatus {
        let isRunning: Bool
        let requestCount: Int64
        let uptimeSeconds: Int
        let wifiIP: String
        let deviceName: String
        let battery: Int
        let version: String
        let rawJSON: [String: Any]
    }

    // ===================== 公开接口 =====================

    /// 检查 daemon 是否在线（快速心跳）
    func checkDaemonAlive(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/heartbeat") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                completion(httpResponse.statusCode == 200)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    /// 获取服务器完整状态
    func fetchStatus(completion: @escaping (ServerStatus?) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/device") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }

            let status = ServerStatus(
                isRunning: (json["status"] as? String) == "running",
                requestCount: json["connectionsHandled"] as? Int64 ?? 0,
                uptimeSeconds: json["serverUptime"] as? Int ?? 0,
                wifiIP: json["wifiIP"] as? String ?? "0.0.0.0",
                deviceName: json["name"] as? String ?? "Unknown",
                battery: json["battery"] as? Int ?? -1,
                version: json["version"] as? String ?? "?",
                rawJSON: json
            )

            completion(status)
        }
        task.resume()
    }

    /// 发送脚本控制命令（转发给 daemon 处理）
    func sendScriptCommand(_ cmd: String, completion: @escaping (Bool, String) -> Void) {
        let urlString = "http://127.0.0.1:8989/task?cmd=\(cmd)"
        guard let url = URL(string: urlString) else {
            completion(false, "URL 无效")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let success = (200...299).contains(statusCode)
            completion(success, "[\(statusCode)] \(body.prefix(200))")
        }
        task.resume()
    }
}

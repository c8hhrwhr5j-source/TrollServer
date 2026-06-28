import Foundation

// ============================================================
//  ShellScriptManager - 本地脚本引擎控制器
//
//  通过 HTTP 调用本机 127.0.0.1:8989 端口（TrollServer 转发到
//  本地脚本引擎 8899），实现脚本的启动/停止/暂停/恢复。
//
//  接口（与中控端一致）：
//    GET /task?cmd=start    → 启动脚本
//    GET /task?cmd=stop     → 停止脚本
//    GET /task?cmd=pause    → 暂停脚本
//    GET /task?cmd=resume   → 恢复脚本
// ============================================================

final class ShellScriptManager {
    static let shared = ShellScriptManager()

    private let baseURL = "http://127.0.0.1:8989"
    private let timeout: TimeInterval = 5.0

    private init() {}

    // ===================== 公开接口 =====================

    enum Command: String, CaseIterable {
        case start  = "start"
        case stop   = "stop"
        case pause  = "pause"
        case resume = "resume"

        var displayName: String {
            switch self {
            case .start:  return "启动"
            case .stop:   return "停止"
            case .pause:  return "暂停"
            case .resume: return "恢复"
            }
        }

        var icon: String {
            switch self {
            case .start:  return "▶"
            case .stop:   return "⏹"
            case .pause:  return "⏸"
            case .resume: return "▶"
            }
        }
    }

    struct Result {
        let success: Bool
        let message: String
        let rawResponse: String
    }

    /// 发送脚本控制命令（异步，回调在主线程）
    func send(_ cmd: Command, completion: @escaping (Result) -> Void) {
        let urlString = "\(baseURL)/task?cmd=\(cmd.rawValue)"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                completion(Result(success: false, message: "URL 无效: \(urlString)", rawResponse: ""))
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        print("[ShellScript] 📤 发送命令: \(cmd.displayName) → \(urlString)")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                let msg = "\(cmd.displayName) 失败: \(error.localizedDescription)"
                print("[ShellScript] ❌ \(msg)")
                DispatchQueue.main.async {
                    completion(Result(success: false, message: msg, rawResponse: ""))
                }
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            let success = (200...299).contains(statusCode)
            let sym = success ? "✅" : "⚠️"
            let msg = "\(sym) \(cmd.displayName) - HTTP \(statusCode): \(body.prefix(200))"
            print("[ShellScript] \(msg)")

            DispatchQueue.main.async {
                completion(Result(success: success, message: msg, rawResponse: body))
            }
        }
        task.resume()
    }
}

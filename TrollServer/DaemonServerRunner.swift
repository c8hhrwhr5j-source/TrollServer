import Foundation

// ============================================================
//  服务器运行器 - 管理脚本控制 + 安装API 服务器生命周期
// ============================================================

class DaemonServerRunner: NSObject {

    var installAPI: InstallAPI?

    func start() {
        // 脚本控制: 不再启动本地代理服务器
        // AutoGo 本身已运行在 8989 端口，ViewController 直连 AutoGo 即可
        // 之前的 ScriptControlServer 代理 (8989→8899) 与 AutoGo 端口冲突，已移除
        print("[无忧辅助控制] 脚本控制: 直连 AutoGo (127.0.0.1:8989)")

        // IPA 安装 API 服务器
        installAPI = InstallAPI(port: 8081)
        do {
            try installAPI?.start()
            print("[无忧辅助控制] IPA 安装服务已启动")
        } catch {
            print("[无忧辅助控制] IPA 安装服务启动失败: \(error)")
        }
    }

    func stop() {
        installAPI?.stop()
        print("[无忧辅助控制] Servers stopped")
    }
}

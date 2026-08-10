import Foundation

// ============================================================
//  服务器运行器 - 管理脚本控制 + 安装API 服务器生命周期
// ============================================================

class DaemonServerRunner: NSObject {

    var scriptServer: ScriptControlServer?
    var installAPI: InstallAPI?

    func start() {
        // 脚本控制服务器
        scriptServer = ScriptControlServer(port: 8989)
        do {
            try scriptServer?.start()
            print("[无忧辅助控制] 脚本控制服务已启动")
        } catch {
            print("[无忧辅助控制] 脚本控制服务启动失败: \(error)")
        }

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
        scriptServer?.stop()
        installAPI?.stop()
        print("[无忧辅助控制] Servers stopped")
    }
}

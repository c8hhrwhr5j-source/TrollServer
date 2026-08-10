import Foundation

// ============================================================
//  服务器运行器 - 管理脚本控制 + 安装API 服务器生命周期
// ============================================================

class DaemonServerRunner: NSObject {

    var scriptServer: ScriptControlServer?
    var installAPI: InstallAPI?

    func start() {
        // 脚本控制服务器（端口 8989）
        scriptServer = ScriptControlServer(port: 8989)
        do {
            try scriptServer?.start()
            print("[TrollServer] Script control server started on port 8989")
        } catch {
            print("[TrollServer] ERROR: Failed to start script control on 8989: \(error)")
        }

        // IPA 安装 API 服务器（端口 8081）
        installAPI = InstallAPI(port: 8081)
        do {
            try installAPI?.start()
            print("[TrollServer] Install API server started on port 8081")
        } catch {
            print("[TrollServer] ERROR: Failed to start install API on 8081: \(error)")
        }
    }

    func stop() {
        scriptServer?.stop()
        installAPI?.stop()
        print("[TrollServer] Servers stopped")
    }
}

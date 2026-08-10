import Foundation

// ============================================================
//  服务器运行器 - 管理脚本控制服务器生命周期
// ============================================================

class DaemonServerRunner: NSObject {

    var scriptServer: ScriptControlServer?

    func start() {
        scriptServer = ScriptControlServer(port: 8989)

        do {
            try scriptServer?.start()
            print("[TrollServer] Script control server started on port 8989")
        } catch {
            print("[TrollServer] ERROR: Failed to start script control on 8989: \(error)")
        }
    }

    func stop() {
        scriptServer?.stop()
        print("[TrollServer] Server stopped")
    }
}

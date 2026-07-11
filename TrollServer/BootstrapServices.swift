import Foundation

// ============================================================
//  BootstrapServices - 安装后自动启动服务
//
//  巨魔 IPA 安装完成后，通过 +load 机制自动启动服务，
//  不需要用户手动打开 App。
//
//  实现方式：利用 Swift 的全局静态初始化器，
//  在二进制被加载到内存时立即执行。
// ============================================================

enum BootstrapServices {

    /// 全局服务器实例（单例，daemon 和 app 模式共用）
    static let httpServer: TrollHTTPServer = {
        let s = TrollHTTPServer(port: 51111)
        return s
    }()

    // ===================== 自动启动入口 =====================

    /// 守护进程模式专用：启动服务 + 看门狗 + 保活
    /// 在 main.swift 的 --daemon 分支中调用
    static func startForDaemon() {
        print("[Bootstrap] 🚀 守护进程模式启动")

        // 1. 启动 HTTP/WebDAV 服务
        _ = httpServer.start()

        // 2. 启动自检看门狗
        ServiceMonitor.shared.start(server: httpServer)

        // 3. 启动 UDP 广播发现
        UDPBroadcaster.shared.start()

        print("[Bootstrap] ✅ 守护进程初始化完成")
    }

    /// App 模式专用：启动服务 + 保活 + 看门狗
    /// 在 AppDelegate didFinishLaunching 中调用
    static func startForApp() {
        print("[Bootstrap] 📱 App 模式启动")

        // 0. 自动安装系统 daemon（首次运行时把自己注册为 LaunchDaemon）
        //    之后设备重启会自动运行，无需再次打开 App
        _ = DaemonBootstrap.installIfNeeded()

        // 1. 启动 HTTP/WebDAV 服务
        _ = httpServer.start()

        // 2. 启动保活（后台任务 + 禁止休眠）
        KeepAliveManager.shared.start()

        // 3. 启动自检看门狗
        ServiceMonitor.shared.start(server: httpServer)

        // 4. 启动 UDP 广播发现
        UDPBroadcaster.shared.start()

        print("[Bootstrap] ✅ App 模式初始化完成")
    }

    /// 停止所有服务
    static func stopAll() {
        UDPBroadcaster.shared.stop()
        ServiceMonitor.shared.stop()
        KeepAliveManager.shared.stop()
        httpServer.stop()
        print("[Bootstrap] 🛑 所有服务已停止")
    }
}

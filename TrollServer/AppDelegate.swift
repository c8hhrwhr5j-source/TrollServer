import UIKit

// ============================================================
//  AppDelegate v3.2 — Daemon/App 分离架构
//
//  客户端模式（daemon 已运行时）：
//    - App 不绑定端口，通过 localhost:51111 获取状态
//    - daemon 进程拥有端口 + 悬浮球
//    - 杀 App 不影响端口和悬浮球
//
//  服务端模式（daemon 未运行时）：
//    - App 自己启动所有服务（首次运行/过渡模式）
// ============================================================

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var didBootstrap = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 1. 启动（自动检测 daemon 状态，决定客户端/服务端模式）
        BootstrapServices.startForApp()
        didBootstrap = true

        // 2. 设置 UI
        window = UIWindow(frame: UIScreen.main.bounds)
        let vc = ViewController()
        vc.clientMode = BootstrapServices.isClientMode
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        print("[AppDelegate] ✅ App 启动完成 (模式: \(BootstrapServices.isClientMode ? "客户端" : "服务端"))")
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 服务端模式下做自检，客户端模式下拉取远程状态
        if !BootstrapServices.isClientMode {
            ServiceMonitor.shared.healNow()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("[AppDelegate] 📴 进入后台")
        if !BootstrapServices.isClientMode {
            ServiceMonitor.shared.healNow()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        print("[AppDelegate] 📱 回到前台")
        if !BootstrapServices.isClientMode {
            ServiceMonitor.shared.healNow()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        BootstrapServices.stopAll()
        print("[AppDelegate] 🛑 App 即将终止 (端口由 daemon 继续维护)")
    }
}

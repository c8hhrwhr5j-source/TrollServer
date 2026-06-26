import UIKit

// ============================================================
//  AppDelegate - v2.0 应用入口
//
//  启动流程：
//  1. BootstrapServices.startForApp() → HTTP 服务 + 保活 + 看门狗
//  2. 设置 UI 状态页面
//  3. 进入后台时维持保活
// ============================================================

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var didBootstrap = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 1. 自启动：HTTP 服务 + 双保活 + 看门狗
        BootstrapServices.startForApp()
        didBootstrap = true

        // 2. 设置 UI
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()

        print("[AppDelegate] ✅ App 启动完成")
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 从后台返回时立即自检一次
        ServiceMonitor.shared.healNow()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("[AppDelegate] 📴 进入后台")
        // 保活已在 BootstrapServices 中启动，此处不需额外操作
        // 自检一次确保服务正常
        ServiceMonitor.shared.healNow()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        print("[AppDelegate] 📱 回到前台")
        ServiceMonitor.shared.healNow()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        BootstrapServices.stopAll()
        print("[AppDelegate] 🛑 App 即将终止")
    }
}

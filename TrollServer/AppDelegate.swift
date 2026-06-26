import UIKit

// ============================================================
//  AppDelegate - 应用入口
//  自动安装/监控守护进程，无需手动重载
// ============================================================

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    var serverRunner = DaemonServerRunner()
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        
        // 1. 首次启动立即修复 + 启动看门狗（自动重载守护进程）
        ServiceWatchdog.shared.startAppMode(serverRunner: serverRunner)
        
        // 2. 设置 UI
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController(serverRunner: serverRunner)
        window?.makeKeyAndVisible()
        
        return true
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        ServiceWatchdog.shared.healNow()
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进入后台前再尝试一次确保守护进程接管
        ServiceWatchdog.shared.healNow()
        
        // 申请后台执行时间，让 Watchdog 完成自愈 + NWListener (includePeerToPeer) 启动
        // 正常情况守护进程接管，无需应用内服务器；若守护进程不可用，应用内 fallback 启动
        print("[AppDelegate] Entering background, requesting background task...")
        backgroundTask = application.beginBackgroundTask(withName: "TrollServerBG") { [weak self] in
            print("[AppDelegate] Background task expiring (server should be alive via includePeerToPeer)")
            application.endBackgroundTask(self?.backgroundTask ?? .invalid)
            self?.backgroundTask = .invalid
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("[AppDelegate] Entering foreground")
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        // 前台恢复时立即自愈，确保 NWListener 重新激活
        ServiceWatchdog.shared.healNow()
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        ServiceWatchdog.shared.stop()
        serverRunner.stop()
    }
}

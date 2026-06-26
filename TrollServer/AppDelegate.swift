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
        backgroundTask = application.beginBackgroundTask(withName: "TrollServerBG") { [weak self] in
            application.endBackgroundTask(self?.backgroundTask ?? .invalid)
            self?.backgroundTask = .invalid
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        ServiceWatchdog.shared.healNow()
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        ServiceWatchdog.shared.stop()
        serverRunner.stop()
    }
}

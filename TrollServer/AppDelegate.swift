import UIKit

// ============================================================
//  AppDelegate - 应用入口
//  首次启动自动安装守护进程，支持后台任务
// ============================================================

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    var serverRunner = DaemonServerRunner()
    
    // 后台任务标识
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        
        // 1. 首次启动：安装守护进程
        if !DaemonInstaller.isInstalled() {
            print("[App] First launch - installing daemon...")
            let installed = DaemonInstaller.install()
            print("[App] Daemon install result: \(installed)")
        } else {
            print("[App] Daemon already installed")
        }
        
        // 2. 启动双端口服务器（作为当前进程）
        serverRunner.start()
        
        // 3. 设置 UI
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController(serverRunner: serverRunner)
        window?.makeKeyAndVisible()
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // 申请后台任务保持服务器存活（守护进程负责真正持久化）
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
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        serverRunner.stop()
    }
}

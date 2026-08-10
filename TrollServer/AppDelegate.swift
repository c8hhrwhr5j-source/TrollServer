import UIKit

// ============================================================
//  AppDelegate - 应用入口，启动脚本控制服务器
// ============================================================

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let serverRunner = DaemonServerRunner()

    /// 后台任务，防止 iOS 休眠后网络服务被中断
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        serverRunner.start()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController(serverRunner: serverRunner)
        window?.makeKeyAndVisible()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        backgroundTask = application.beginBackgroundTask(withName: "TrollServer.keepalive") { [weak self] in
            guard let self = self else { return }
            if self.backgroundTask != .invalid {
                application.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        if backgroundTask != .invalid {
            let app = UIApplication.shared
            app.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        serverRunner.stop()
    }
}

import UIKit

// ============================================================
//  AppDelegate - 应用入口，启动脚本控制服务器
// ============================================================

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let serverRunner = DaemonServerRunner()

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

    func applicationWillTerminate(_ application: UIApplication) {
        serverRunner.stop()
    }
}

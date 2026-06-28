import UIKit
import AVFoundation

// ============================================================
//  KeepAliveManager - 三重保活策略
//
//  策略 1: 静音音频无限循环（audio 后台模式，iOS 永久后台）
//  策略 2: 后台任务无限续期（每 25s 续一次，备用）
//  策略 3: 禁用屏幕休眠
// ============================================================

class KeepAliveManager {

    static let shared = KeepAliveManager()

    private var isRunning = false
    private let lock = NSLock()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // ===================== 启动保活 =====================

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        print("[KeepAlive] 🔋 启动三重保活")

        // 策略 1: 静音音频（最可靠，iOS 永不停杀）
        SilentAudioPlayer.shared.start()

        // 策略 2: 后台任务无限续期（备用兜底）
        startInfiniteBackgroundTask()

        // 策略 3: 禁止休眠
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        print("[KeepAlive] ✅ 三重保活已激活（静音音频 + 后台任务 + 禁止休眠）")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        // 停止静音音频
        SilentAudioPlayer.shared.stop()

        // 停止后台任务
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        print("[KeepAlive] 🛑 保活已停止")
    }

    // ===================== 后台任务无限续期 =====================

    private func startInfiniteBackgroundTask() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            while self?.isRunning == true {
                autoreleasepool {
                    var task: UIBackgroundTaskIdentifier = .invalid
                    task = UIApplication.shared.beginBackgroundTask(withName: "TrollKeepAlive") {
                        if task != .invalid {
                            UIApplication.shared.endBackgroundTask(task)
                        }
                    }
                    // 每 25s 续期（低于系统给的 30s 窗口）
                    Thread.sleep(forTimeInterval: 25)
                    if task != .invalid {
                        UIApplication.shared.endBackgroundTask(task)
                    }
                }
            }
        }
    }
}

import UIKit

// ============================================================
//  KeepAliveManager - 零音频 · 零耗电 · 零冲突 保活
//
//  策略 1: 后台任务无限续期（每 25s 续一次，卡系统 30s 窗口）
//  策略 2: 禁用屏幕休眠
//  策略 3: 轻量循环保持进程不退出
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

        print("[KeepAlive] 🔋 启动零音频保活")

        // 1. 后台任务无限续期
        startInfiniteBackgroundTask()

        // 2. 禁止休眠
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        print("[KeepAlive] ✅ 保活已激活（后台任务 + 禁止休眠）")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

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
            // 无限轻量循环，几乎不占 CPU
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

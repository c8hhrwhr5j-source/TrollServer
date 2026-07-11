import UIKit
import AVFoundation

// ============================================================
//  KeepAliveManager v3.1 - 强化保活 + 主线程安全
//
//  策略 1: 静音音频无限循环（audio 后台模式，iOS 永久后台）
//  策略 2: 后台任务无限续期（每 15s 续一次，主线程调用）
//  策略 3: 禁用屏幕休眠
//  策略 4: 音频健康检查（每 30s 检查播放状态并自动恢复）
//
//  v3.1: beginBackgroundTask 统一通过主线程调度
// ============================================================

class KeepAliveManager {

    static let shared = KeepAliveManager()

    private var isRunning = false
    private let lock = NSLock()
    private var bgTaskThread: Thread?
    private var audioHealthThread: Thread?

    // 音频保活健康状态
    private(set) var audioHealthy = false

    // ===================== 启动保活 =====================

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        print("[KeepAlive] 🔋 启动四重保活 v2.0")

        // 策略 1: 静音音频（最可靠，iOS 永不停杀）
        SilentAudioPlayer.shared.start()
        audioHealthy = true

        // 策略 2: 后台任务无限续期（缩短到 15s，更积极地续期）
        startInfiniteBackgroundTask()

        // 策略 3: 禁止休眠
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        // 策略 4: 音频健康检查线程（每 30s 检查 + 自动恢复）
        startAudioHealthMonitor()

        // 注册通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        print("[KeepAlive] ✅ 四重保活已激活（静音音频 + 后台任务+15s + 禁止休眠 + 健康监控）")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        // 移除通知
        NotificationCenter.default.removeObserver(self)

        // 停止音频健康线程
        audioHealthThread?.cancel()
        audioHealthThread = nil

        // 停止后台任务线程
        bgTaskThread?.cancel()
        bgTaskThread = nil

        // 停止静音音频
        SilentAudioPlayer.shared.stop()
        audioHealthy = false

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        print("[KeepAlive] 🛑 保活已停止")
    }

    // ===================== 后台任务无限续期 =====================

    private func startInfiniteBackgroundTask() {
        let thread = Thread { [weak self] in
            while self?.isRunning == true {
                autoreleasepool {
                    let semaphore = DispatchSemaphore(value: 0)
                    var task: UIBackgroundTaskIdentifier = .invalid

                    // v3.1: beginBackgroundTask 在主线程调用更可靠
                    DispatchQueue.main.async {
                        task = UIApplication.shared.beginBackgroundTask(withName: "TrollKeepAlive") {
                            if task != .invalid {
                                UIApplication.shared.endBackgroundTask(task)
                                task = .invalid
                            }
                        }
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 3.0)

                    if task == .invalid {
                        print("[KeepAlive] ⚠️ beginBackgroundTask 返回 invalid，音频可能停止")
                        SilentAudioPlayer.shared.start()
                    }

                    // 每 15s 续期
                    Thread.sleep(forTimeInterval: 15)

                    if task != .invalid {
                        DispatchQueue.main.async {
                            UIApplication.shared.endBackgroundTask(task)
                        }
                    }
                }
            }
        }
        thread.name = "com.troll.keepalive"
        thread.qualityOfService = .background
        thread.start()
        bgTaskThread = thread
    }

    // ===================== 音频健康监控 =====================

    private func startAudioHealthMonitor() {
        let thread = Thread { [weak self] in
            // 首次延迟 30s
            Thread.sleep(forTimeInterval: 30)
            while self?.isRunning == true {
                autoreleasepool {
                    self?.checkAudioHealth()
                }
                Thread.sleep(forTimeInterval: 30)
            }
        }
        thread.name = "com.troll.audioHealth"
        thread.qualityOfService = .background
        thread.start()
        audioHealthThread = thread
    }

    private func checkAudioHealth() {
        guard isRunning else { return }

        let isPlaying = SilentAudioPlayer.shared.isPlaying

        if !isPlaying {
            print("[KeepAlive] ⚠️ 静音音频已停止播放，尝试恢复...")
            audioHealthy = false
            // 重新配置音频会话并重启
            SilentAudioPlayer.shared.stop()
            Thread.sleep(forTimeInterval: 1)
            SilentAudioPlayer.shared.start()
            audioHealthy = SilentAudioPlayer.shared.isPlaying
            if audioHealthy {
                print("[KeepAlive] ✅ 静音音频恢复成功")
            } else {
                print("[KeepAlive] ❌ 静音音频恢复失败")
            }
        } else {
            audioHealthy = true
        }
    }

    // ===================== 中断处理 =====================

    @objc private func audioInterruption(_ notification: Notification) {
        guard let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            print("[KeepAlive] ⚠️ 音频中断开始")
            audioHealthy = false
        case .ended:
            print("[KeepAlive] ✅ 音频中断结束，恢复播放")
            SilentAudioPlayer.shared.start()
            audioHealthy = true
            // 中断结束后通知 ServiceMonitor 重启服务器
            ServiceMonitor.shared.healNow()
        @unknown default:
            break
        }
    }

    @objc private func audioRouteChange(_ notification: Notification) {
        guard let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        print("[KeepAlive] 🔀 音频路由变更 (\(reasonRaw)), 确保播放继续")
        if !SilentAudioPlayer.shared.isPlaying {
            SilentAudioPlayer.shared.start()
            audioHealthy = true
        }
    }
}

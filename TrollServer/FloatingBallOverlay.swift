import Foundation
#if DAEMON_MODE
import UIKit
#endif

// ============================================================
//  FloatingBallOverlay - 悬浮球（Daemon 进程内渲染）
//
//  和 AutoGo Android 的 FloatingBallService 对应，
//  在 daemon 进程里创建一个全局悬浮球窗口。
//  因为 daemon 由 launchd 托管，杀 App 不影响悬浮球。
//
//  依赖：TrollStore 环境 (no-sandbox)，可以在任意进程创建 UIWindow
// ============================================================

#if DAEMON_MODE

final class FloatingBallOverlay: NSObject {

    static let shared = FloatingBallOverlay()

    private var overlayWindow: UIWindow?
    private var ballView: UIView?
    private var statusLabel: UILabel?
    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var ballCenter: CGPoint = .zero
    private var isExpanded = false
    private var expandedView: UIView?
    private var statusUpdateTimer: Timer?
    private var serverStatus: String = "● 运行中"
    private var requestCount: Int64 = 0
    private var uptimeSeconds: Int = 0

    private override init() {
        super.init()
    }

    // ===================== 公开接口 =====================

    func show() {
        DispatchQueue.main.async { [weak self] in
            self?.setupOverlay()
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.overlayWindow?.isHidden = true
            self?.overlayWindow = nil
            self?.ballView = nil
        }
    }

    func updateStatus(running: Bool, requests: Int64, uptime: Int) {
        serverStatus = running ? "● 运行中" : "○ 已停止"
        requestCount = requests
        uptimeSeconds = uptime
        DispatchQueue.main.async { [weak self] in
            self?.refreshStatusDisplay()
        }
    }

    // ===================== 悬浮球 UI =====================

    private func setupOverlay() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            // 若无 scene（daemon 进程），直接用 UIScreen 创建 window
            setupOverlayLegacy()
            return
        }
        setupOverlayModern(scene: scene)
    }

    private func setupOverlayModern(scene: UIWindowScene) {
        let ballSize: CGFloat = 52
        let margin: CGFloat = 12
        let screenW = UIScreen.main.bounds.width
        let screenH = UIScreen.main.bounds.height

        // 全局悬浮窗口（最高层级）
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.makeKeyAndVisible()

        // 悬浮球视图
        let ball = UIView(frame: CGRect(x: screenW - ballSize - margin,
                                         y: screenH * 0.35,
                                         width: ballSize,
                                         height: ballSize))
        ball.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        ball.layer.cornerRadius = ballSize / 2
        ball.layer.shadowColor = UIColor.black.cgColor
        ball.layer.shadowOffset = CGSize(width: 0, height: 2)
        ball.layer.shadowOpacity = 0.5
        ball.layer.shadowRadius = 4
        ball.layer.borderWidth = 2
        ball.layer.borderColor = UIColor.systemGreen.cgColor
        ball.clipsToBounds = false

        // 状态指示灯
        let indicator = UIView(frame: CGRect(x: ballSize - 14, y: 4, width: 10, height: 10))
        indicator.backgroundColor = .systemGreen
        indicator.layer.cornerRadius = 5
        indicator.tag = 999
        ball.addSubview(indicator)

        // 标题标签
        let label = UILabel(frame: CGRect(x: 4, y: 14, width: ballSize - 16, height: 20))
        label.text = "TS"
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 12)
        label.textAlignment = .center
        label.tag = 998
        ball.addSubview(label)

        // 状态文字
        let statusLbl = UILabel(frame: CGRect(x: 2, y: 30, width: ballSize - 4, height: 16))
        statusLbl.text = "51111"
        statusLbl.textColor = UIColor(white: 0.7, alpha: 1)
        statusLbl.font = UIFont.systemFont(ofSize: 9)
        statusLbl.textAlignment = .center
        statusLbl.tag = 997
        ball.addSubview(statusLbl)
        self.statusLabel = statusLbl

        // 手势
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        ball.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        ball.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        ball.addGestureRecognizer(longPress)

        window.rootViewController?.view.addSubview(ball)

        self.overlayWindow = window
        self.ballView = ball
        ballCenter = ball.center

        print("[FloatingBall] ✅ 悬浮球已显示")
    }

    private func setupOverlayLegacy() {
        // 旧版 iOS（无 UIScene）的创建方式
        let ballSize: CGFloat = 52
        let margin: CGFloat = 12
        let screenW = UIScreen.main.bounds.width
        let screenH = UIScreen.main.bounds.height

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = false

        let ball = UIView(frame: CGRect(x: screenW - ballSize - margin,
                                         y: screenH * 0.35,
                                         width: ballSize,
                                         height: ballSize))
        ball.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        ball.layer.cornerRadius = ballSize / 2
        ball.layer.shadowColor = UIColor.black.cgColor
        ball.layer.shadowOffset = CGSize(width: 0, height: 2)
        ball.layer.shadowOpacity = 0.5
        ball.layer.shadowRadius = 4
        ball.layer.borderWidth = 2
        ball.layer.borderColor = UIColor.systemGreen.cgColor
        ball.clipsToBounds = false

        let indicator = UIView(frame: CGRect(x: ballSize - 14, y: 4, width: 10, height: 10))
        indicator.backgroundColor = .systemGreen
        indicator.layer.cornerRadius = 5
        indicator.tag = 999
        ball.addSubview(indicator)

        let label = UILabel(frame: CGRect(x: 4, y: 14, width: ballSize - 16, height: 20))
        label.text = "TS"
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 12)
        label.textAlignment = .center
        label.tag = 998
        ball.addSubview(label)

        let statusLbl = UILabel(frame: CGRect(x: 2, y: 30, width: ballSize - 4, height: 16))
        statusLbl.text = "51111"
        statusLbl.textColor = UIColor(white: 0.7, alpha: 1)
        statusLbl.font = UIFont.systemFont(ofSize: 9)
        statusLbl.textAlignment = .center
        statusLbl.tag = 997
        ball.addSubview(statusLbl)
        self.statusLabel = statusLbl

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        ball.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        ball.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        ball.addGestureRecognizer(longPress)

        window.rootViewController?.view.addSubview(ball)

        self.overlayWindow = window
        self.ballView = ball
        ballCenter = ball.center

        print("[FloatingBall] ✅ 悬浮球已显示 (legacy)")
    }

    // ===================== 手势处理 =====================

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let ball = ballView else { return }

        switch gesture.state {
        case .began:
            isDragging = true
            dismissExpanded()
            dragStartPoint = ball.center
            UIView.animate(withDuration: 0.15) {
                ball.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
                ball.alpha = 0.9
            }
        case .changed:
            let translation = gesture.translation(in: overlayWindow)
            var newCenter = CGPoint(x: dragStartPoint.x + translation.x,
                                     y: dragStartPoint.y + translation.y)

            // 边界限制
            let halfW = ball.bounds.width / 2
            let screenW = UIScreen.main.bounds.width
            let screenH = UIScreen.main.bounds.height
            let topMargin: CGFloat = 44  // 状态栏
            let bottomMargin: CGFloat = 34 // 底部安全区

            newCenter.x = max(halfW + 4, min(screenW - halfW - 4, newCenter.x))
            newCenter.y = max(halfW + topMargin, min(screenH - halfW - bottomMargin, newCenter.y))

            ball.center = newCenter

        case .ended, .cancelled:
            isDragging = false
            ballCenter = ball.center

            // 吸附到屏幕边缘
            let screenW = UIScreen.main.bounds.width
            let halfW = ball.bounds.width / 2
            let targetX: CGFloat
            if ball.center.x > screenW / 2 {
                targetX = screenW - halfW - 8
            } else {
                targetX = halfW + 8
            }

            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                ball.center.x = targetX
                ball.transform = .identity
                ball.alpha = 1.0
            }
            ballCenter = CGPoint(x: targetX, y: ball.center.y)

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if isDragging { return }
        toggleExpanded()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            // 长按：切换服务器重启
            restartServerViaDaemon()
        }
    }

    // ===================== 展开/收起面板 =====================

    private func toggleExpanded() {
        if isExpanded {
            dismissExpanded()
        } else {
            showExpanded()
        }
    }

    private func showExpanded() {
        guard let ball = ballView, let window = overlayWindow else { return }
        guard !isExpanded else { return }
        isExpanded = true

        let panelW: CGFloat = 200
        let panelH: CGFloat = 120
        let ballCenterInWindow = ball.convert(ball.bounds.center, to: window)

        // 确定面板位置（在球的上方或下方）
        let panelY: CGFloat
        if ballCenterInWindow.y > UIScreen.main.bounds.height / 2 {
            panelY = ballCenterInWindow.y - ball.bounds.height / 2 - panelH - 8
        } else {
            panelY = ballCenterInWindow.y + ball.bounds.height / 2 + 8
        }

        let panelX: CGFloat
        if ballCenterInWindow.x > UIScreen.main.bounds.width / 2 {
            panelX = ballCenterInWindow.x - panelW + ball.bounds.width / 2
        } else {
            panelX = ballCenterInWindow.x - ball.bounds.width / 2
        }

        let panel = UIView(frame: CGRect(x: panelX, y: panelY, width: panelW, height: panelH))
        panel.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        panel.layer.cornerRadius = 14
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOffset = CGSize(width: 0, height: 4)
        panel.layer.shadowOpacity = 0.6
        panel.layer.shadowRadius = 8
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

        // 内容
        let titleLabel = createLabel(text: "TrollServer v3.1", font: .boldSystemFont(ofSize: 14), color: .white)
        titleLabel.frame = CGRect(x: 14, y: 14, width: panelW - 28, height: 20)

        let statusLine = createLabel(text: serverStatus, font: .systemFont(ofSize: 13), color: .systemGreen)
        statusLine.frame = CGRect(x: 14, y: 38, width: panelW - 28, height: 18)

        let statLine = createLabel(text: "📊 请求: \(requestCount)  |  运行: \(formatUptime(uptimeSeconds))",
                                    font: .systemFont(ofSize: 11), color: UIColor(white: 0.7, alpha: 1))
        statLine.frame = CGRect(x: 14, y: 58, width: panelW - 28, height: 16)

        let ipLine = createLabel(text: "📶 端口: 51111", font: .systemFont(ofSize: 11), color: UIColor(white: 0.6, alpha: 1))
        ipLine.frame = CGRect(x: 14, y: 78, width: panelW - 28, height: 16)

        let hintLine = createLabel(text: "轻触切换  |  长按重启服务", font: .systemFont(ofSize: 10), color: UIColor(white: 0.5, alpha: 1))
        hintLine.frame = CGRect(x: 14, y: 98, width: panelW - 28, height: 14)

        panel.addSubview(titleLabel)
        panel.addSubview(statusLine)
        panel.addSubview(statLine)
        panel.addSubview(ipLine)
        panel.addSubview(hintLine)

        window.rootViewController?.view.addSubview(panel)
        self.expandedView = panel

        // 动画
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3) {
            panel.alpha = 1
            panel.transform = .identity
        }

        // 3 秒后自动收起
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.dismissExpanded()
        }
    }

    private func dismissExpanded() {
        guard let panel = expandedView, isExpanded else { return }
        isExpanded = false

        UIView.animate(withDuration: 0.15, animations: {
            panel.alpha = 0
            panel.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }) { _ in
            panel.removeFromSuperview()
        }
        expandedView = nil
    }

    // ===================== 状态刷新 =====================

    func startStatusRefresh() {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatusDisplay()
        }
        refreshStatusDisplay()
    }

    func stopStatusRefresh() {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
    }

    private func refreshStatusDisplay() {
        guard let ball = ballView else { return }

        // 更新指示灯颜色
        if let indicator = ball.viewWithTag(999) {
            indicator.backgroundColor = serverStatus.contains("运行中") ? UIColor.systemGreen : UIColor.systemRed
        }
        // 更新边框颜色
        ball.layer.borderColor = serverStatus.contains("运行中") ? UIColor.systemGreen.cgColor : UIColor.systemRed.cgColor

        // 更新文字
        if let label = ball.viewWithTag(997) as? UILabel {
            label.text = serverStatus.contains("运行中") ? "51111 ✓" : "51111 ✗"
        }

        // 如果有展开面板，同步更新
        if let panel = expandedView, isExpanded {
            for sub in panel.subviews {
                if let lbl = sub as? UILabel {
                    if lbl.text?.contains("●") == true || lbl.text?.contains("○") == true {
                        lbl.text = serverStatus
                        lbl.textColor = serverStatus.contains("运行中") ? UIColor.systemGreen : UIColor.systemRed
                    }
                    if lbl.text?.contains("📊") == true {
                        lbl.text = "📊 请求: \(requestCount)  |  运行: \(formatUptime(uptimeSeconds))"
                    }
                }
            }
        }
    }

    // ===================== 辅助方法 =====================

    private func createLabel(text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        return label
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h\(m)m"
    }

    private func restartServerViaDaemon() {
        // 通过本地 HTTP API 触发重启
        guard let url = URL(string: "http://127.0.0.1:51111/api/heartbeat") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req).resume()

        // 显示反馈
        if let ball = ballView {
            UIView.animate(withDuration: 0.1, animations: {
                ball.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            }) { _ in
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) {
                    ball.transform = .identity
                }
            }
        }
    }
}

// MARK: - CGRect 扩展
extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

#else

// App 模式下空壳（App 有自己的 UI 不需要这个悬浮球）
final class FloatingBallOverlay {
    static let shared = FloatingBallOverlay()
    private init() {}
    func show() {}
    func hide() {}
    func updateStatus(running: Bool, requests: Int64, uptime: Int) {}
    func startStatusRefresh() {}
    func stopStatusRefresh() {}
}

#endif

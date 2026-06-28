import UIKit

// ============================================================
//  ViewController v2.0 - 服务状态页面
// ============================================================

class ViewController: UIViewController {

    // 状态标签
    private let serviceStatusLabel = UILabel()
    private let keepaliveLabel = UILabel()
    private let monitorLabel = UILabel()
    private let statsLabel = UILabel()
    private let ipAddressLabel = UILabel()
    private let docRootLabel = UILabel()

    // 按钮
    private let restartBtn = UIButton(type: .system)
    private let healBtn = UIButton(type: .system)

    // 脚本控制按钮
    private let startBtn = UIButton(type: .system)
    private let stopBtn = UIButton(type: .system)
    private let pauseBtn = UIButton(type: .system)
    private let resumeBtn = UIButton(type: .system)
    private let scriptStatusLabel = UILabel()

    // 定时刷新
    private var refreshTimer: Timer?

    // ===================== 生命周期 =====================

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startRefreshTimer()
        updateStatus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
    }

    // ===================== UI 布局 =====================

    private func setupUI() {
        view.backgroundColor = UIColor.systemGroupedBackground

        // 标题
        let titleLabel = UILabel()
        titleLabel.text = "TrollServer v3.1"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = UILabel()
        subtitleLabel.text = "HTTP/WebDAV · BSD Socket · 静音保活 · 智能自检"
        subtitleLabel.font = UIFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // 状态卡片
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        serviceStatusLabel.font = UIFont.systemFont(ofSize: 15)
        serviceStatusLabel.numberOfLines = 0

        keepaliveLabel.font = UIFont.systemFont(ofSize: 13)
        keepaliveLabel.textColor = .secondaryLabel
        keepaliveLabel.numberOfLines = 0

        monitorLabel.font = UIFont.systemFont(ofSize: 12)
        monitorLabel.textColor = .secondaryLabel
        monitorLabel.numberOfLines = 0

        statsLabel.font = UIFont.systemFont(ofSize: 13)
        statsLabel.textColor = .secondaryLabel

        ipAddressLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        ipAddressLabel.textColor = .systemBlue

        docRootLabel.font = UIFont.systemFont(ofSize: 11)
        docRootLabel.textColor = .tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [
            serviceStatusLabel, keepaliveLabel, monitorLabel, statsLabel,
            ipAddressLabel, docRootLabel
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        // 按钮
        restartBtn.setTitle("重启服务", for: .normal)
        restartBtn.addTarget(self, action: #selector(restartService), for: .touchUpInside)
        restartBtn.backgroundColor = .systemBlue
        restartBtn.setTitleColor(.white, for: .normal)
        restartBtn.layer.cornerRadius = 8
        restartBtn.translatesAutoresizingMaskIntoConstraints = false
        restartBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        healBtn.setTitle("立即自检", for: .normal)
        healBtn.addTarget(self, action: #selector(healNow), for: .touchUpInside)
        healBtn.backgroundColor = .systemGray4
        healBtn.layer.cornerRadius = 8
        healBtn.translatesAutoresizingMaskIntoConstraints = false
        healBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        let btnStack = UIStackView(arrangedSubviews: [restartBtn, healBtn])
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.distribution = .fillEqually
        btnStack.translatesAutoresizingMaskIntoConstraints = false

        // ---- 脚本控制区域 ----
        let scriptSectionTitle = UILabel()
        scriptSectionTitle.text = "📋 脚本控制"
        scriptSectionTitle.font = UIFont.boldSystemFont(ofSize: 16)
        scriptSectionTitle.textColor = .label
        scriptSectionTitle.translatesAutoresizingMaskIntoConstraints = false

        // 2×2 网格：启动/停止 + 暂停/恢复
        let row1 = UIStackView(arrangedSubviews: [startBtn, stopBtn])
        row1.axis = .horizontal
        row1.spacing = 12
        row1.distribution = .fillEqually
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = UIStackView(arrangedSubviews: [pauseBtn, resumeBtn])
        row2.axis = .horizontal
        row2.spacing = 12
        row2.distribution = .fillEqually
        row2.translatesAutoresizingMaskIntoConstraints = false

        // 结果反馈标签
        scriptStatusLabel.text = ""
        scriptStatusLabel.font = UIFont.systemFont(ofSize: 12)
        scriptStatusLabel.textColor = .secondaryLabel
        scriptStatusLabel.textAlignment = .center
        scriptStatusLabel.numberOfLines = 2
        scriptStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let scriptCard = UIView()
        scriptCard.backgroundColor = .secondarySystemGroupedBackground
        scriptCard.layer.cornerRadius = 12
        scriptCard.translatesAutoresizingMaskIntoConstraints = false

        let scriptStack = UIStackView(arrangedSubviews: [row1, row2, scriptStatusLabel])
        scriptStack.axis = .vertical
        scriptStack.spacing = 10
        scriptStack.translatesAutoresizingMaskIntoConstraints = false
        scriptCard.addSubview(scriptStack)

        // 配置四个按钮
        _ = {
            let configs: [(UIButton, String, UIColor, Selector)] = [
                (startBtn,  "▶ 启动",  UIColor.systemGreen,  #selector(scriptStart)),
                (stopBtn,   "⏹ 停止",  UIColor.systemRed,    #selector(scriptStop)),
                (pauseBtn,  "⏸ 暂停",  UIColor.systemOrange, #selector(scriptPause)),
                (resumeBtn, "▶ 恢复",  UIColor.systemBlue,   #selector(scriptResume)),
            ]
            for (btn, title, color, action) in configs {
                btn.setTitle(title, for: .normal)
                btn.setTitleColor(.white, for: .normal)
                btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
                btn.backgroundColor = color
                btn.layer.cornerRadius = 10
                btn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
                btn.addTarget(self, action: action, for: .touchUpInside)
                btn.isEnabled = true
            }
        }()

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(card)
        view.addSubview(btnStack)
        view.addSubview(scriptSectionTitle)
        view.addSubview(scriptCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 30),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            btnStack.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 24),
            btnStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            btnStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // 脚本控制区域
            scriptSectionTitle.topAnchor.constraint(equalTo: btnStack.bottomAnchor, constant: 28),
            scriptSectionTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            scriptCard.topAnchor.constraint(equalTo: scriptSectionTitle.bottomAnchor, constant: 10),
            scriptCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scriptCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scriptStack.topAnchor.constraint(equalTo: scriptCard.topAnchor, constant: 16),
            scriptStack.leadingAnchor.constraint(equalTo: scriptCard.leadingAnchor, constant: 16),
            scriptStack.trailingAnchor.constraint(equalTo: scriptCard.trailingAnchor, constant: -16),
            scriptStack.bottomAnchor.constraint(equalTo: scriptCard.bottomAnchor, constant: -16),
        ])
    }

    // ===================== 定时刷新 =====================

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    // ===================== 状态更新 =====================

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 注册看门狗状态回调
        ServiceMonitor.shared.onStatusChanged = { [weak self] in
            self?.updateStatus()
        }
    }

    @objc private func updateStatus() {
        let server = BootstrapServices.httpServer
        let running = server.isRunning
        let monitor = ServiceMonitor.shared
        let keepAlive = KeepAliveManager.shared

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 服务状态
            let icon = running ? "●" : "○"
            let color = running ? "运行中" : "已停止"
            self.serviceStatusLabel.attributedText = self.buildLine(
                icon: icon, title: "HTTP/WebDAV (51111)", detail: color, ok: running
            )

            // 保活状态（显示音频健康）
            let audioOK = keepAlive.audioHealthy && SilentAudioPlayer.shared.isPlaying
            let audioStatus = audioOK ? "✅音频" : "⚠️音频"
            self.keepaliveLabel.text = "🔋 保活: 后台任务(15s) + \(audioStatus) + 禁止休眠"

            // 看门狗状态
            self.monitorLabel.text = "🩺 \(monitor.statusDetail) · 重启×\(monitor.restartCount)"

            // 统计
            let uptime = Int(-server.startTime.timeIntervalSinceNow)
            self.statsLabel.text = "📊 请求: \(server.requestCount) · 运行: \(uptime)s"

            // IP
            if let ip = self.getWiFiIP() {
                self.ipAddressLabel.text = "📶 \(ip):51111"
            } else {
                self.ipAddressLabel.text = "⚠️ 未连接 WiFi"
            }

            // 文档根目录
            let doc = TrollHTTPServer.defaultDocRoot
            self.docRootLabel.text = "📂 \(doc)"
        }
    }

    private func buildLine(icon: String, title: String, detail: String, ok: Bool) -> NSAttributedString {
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(
            string: "\(icon) \(title)  ",
            attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.label]
        ))
        attr.append(NSAttributedString(
            string: detail,
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: ok ? UIColor.systemGreen : UIColor.systemRed]
        ))
        return attr
    }

    // ===================== 操作 =====================

    @objc private func restartService() {
        let server = BootstrapServices.httpServer
        server.stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            _ = server.start()
            DispatchQueue.main.async { [weak self] in self?.updateStatus() }
        }
    }

    @objc private func healNow() {
        ServiceMonitor.shared.healNow()
        updateStatus()
    }

    // ===================== 脚本控制操作 =====================

    private enum ScriptCommand: String {
        case start  = "start"
        case stop   = "stop"
        case pause  = "pause"
        case resume = "resume"

        var displayName: String {
            switch self {
            case .start:  return "启动"
            case .stop:   return "停止"
            case .pause:  return "暂停"
            case .resume: return "恢复"
            }
        }
    }

    @objc private func scriptStart() {
        sendScriptCommand(.start)
    }

    @objc private func scriptStop() {
        sendScriptCommand(.stop)
    }

    @objc private func scriptPause() {
        sendScriptCommand(.pause)
    }

    @objc private func scriptResume() {
        sendScriptCommand(.resume)
    }

    private func sendScriptCommand(_ cmd: ScriptCommand) {
        // 禁用所有按钮，防止重复点击
        setScriptButtonsEnabled(false)
        scriptStatusLabel.text = "⏳ 正在发送 \(cmd.displayName) 命令..."
        scriptStatusLabel.textColor = .secondaryLabel

        let urlString = "http://127.0.0.1:8989/task?cmd=\(cmd.rawValue)"
        guard let url = URL(string: urlString) else {
            self.scriptStatusLabel.text = "URL 无效: \(urlString)"
            self.scriptStatusLabel.textColor = .systemRed
            self.setScriptButtonsEnabled(true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        print("[Script] 📤 发送命令: \(cmd.displayName) → \(urlString)")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                let msg = "\(cmd.displayName) 失败: \(error.localizedDescription)"
                print("[Script] ❌ \(msg)")
                DispatchQueue.main.async {
                    self.setScriptButtonsEnabled(true)
                    self.scriptStatusLabel.text = msg
                    self.scriptStatusLabel.textColor = .systemRed
                }
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let success = (200...299).contains(statusCode)
            let msg = "\(success ? "✅" : "⚠️") \(cmd.displayName) - HTTP \(statusCode): \(body.prefix(200))"
            print("[Script] \(msg)")

            DispatchQueue.main.async {
                self.setScriptButtonsEnabled(true)
                self.scriptStatusLabel.text = msg
                self.scriptStatusLabel.textColor = success ? .systemGreen : .systemRed
            }
        }
        task.resume()
    }

    private func setScriptButtonsEnabled(_ enabled: Bool) {
        startBtn.isEnabled = enabled
        stopBtn.isEnabled = enabled
        pauseBtn.isEnabled = enabled
        resumeBtn.isEnabled = enabled
    }

    // ===================== 工具 =====================

    private func getWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            let flags = Int32(ptr!.pointee.ifa_flags)
            let addr = ptr!.pointee.ifa_addr
            if addr?.pointee.sa_family == UInt8(AF_INET), (flags & IFF_UP) != 0 {
                let name = String(cString: ptr!.pointee.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr!.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    return String(cString: hostname)
                }
            }
            ptr = ptr!.pointee.ifa_next
        }
        return nil
    }
}

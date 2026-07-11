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

    // 设备伪装按钮
    private let toiPadBtn = UIButton(type: .system)
    private let toiPhoneBtn = UIButton(type: .system)
    private let spoofSettingsBtn = UIButton(type: .system)
    private let gestaltStatusLabel = UILabel()

    // dylib 注入区域
    private let injectSectionTitle = UILabel()
    private var injectCards: [UIView] = []
    private var injectButtons: [UIButton] = []
    private var injectStatusLabels: [UILabel] = []
    private var injectRestoreButtons: [UIButton] = []
    private var injectIPAURLs: [URL?] = []

    // 定时刷新
    private var refreshTimer: Timer?

    // 客户端模式（由 AppDelegate 启动时设置）
    var clientMode: Bool = false

    // ===================== 生命周期 =====================

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateSpoofStatus()
        startRefreshTimer()
        updateStatus()

        // 后台扫描微信/QQ 安装状态
        DispatchQueue.global().async { [weak self] in
            self?.scanAndUpdateInjectUI()
        }
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
        subtitleLabel.text = "开发者：子平 QQ：173179642"
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

        // ---- 设备伪装区域 ----
        let gestaltSectionTitle = UILabel()
        gestaltSectionTitle.text = "🔄 设备伪装 (需重启生效)"
        gestaltSectionTitle.font = UIFont.boldSystemFont(ofSize: 16)
        gestaltSectionTitle.textColor = .label
        gestaltSectionTitle.translatesAutoresizingMaskIntoConstraints = false

        // 两个按钮：改为 iPad / 改为 iPhone
        let gestaltRow = UIStackView(arrangedSubviews: [toiPadBtn, toiPhoneBtn, spoofSettingsBtn])
        gestaltRow.axis = .horizontal
        gestaltRow.spacing = 12
        gestaltRow.distribution = .fillEqually
        gestaltRow.translatesAutoresizingMaskIntoConstraints = false

        gestaltStatusLabel.text = ""
        gestaltStatusLabel.font = UIFont.systemFont(ofSize: 12)
        gestaltStatusLabel.textColor = .secondaryLabel
        gestaltStatusLabel.textAlignment = .center
        gestaltStatusLabel.numberOfLines = 0
        gestaltStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let gestaltCard = UIView()
        gestaltCard.backgroundColor = .secondarySystemGroupedBackground
        gestaltCard.layer.cornerRadius = 12
        gestaltCard.translatesAutoresizingMaskIntoConstraints = false

        let gestaltStack = UIStackView(arrangedSubviews: [gestaltRow, gestaltStatusLabel])
        gestaltStack.axis = .vertical
        gestaltStack.spacing = 10
        gestaltStack.translatesAutoresizingMaskIntoConstraints = false
        gestaltCard.addSubview(gestaltStack)

        // 配置伪装按钮
        _ = {
            let configs: [(UIButton, String, UIColor, Selector)] = [
                (toiPadBtn,         "📱 改为 iPad", UIColor.systemIndigo, #selector(setToiPad)),
                (toiPhoneBtn,       "📱 改为 iPhone", UIColor.systemTeal, #selector(setToiPhone)),
                (spoofSettingsBtn,  "⚙️ 设置",      UIColor.systemGray,    #selector(openSpoofSettings)),
            ]
            for (btn, title, color, action) in configs {
                btn.setTitle(title, for: .normal)
                btn.setTitleColor(.white, for: .normal)
                btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
                btn.backgroundColor = color
                btn.layer.cornerRadius = 10
                btn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
                btn.addTarget(self, action: action, for: .touchUpInside)
            }
        }()

        // ---- dylib 注入区域 ----
        injectSectionTitle.text = "📦 dylib 注入工具"
        injectSectionTitle.font = UIFont.boldSystemFont(ofSize: 16)
        injectSectionTitle.textColor = .label
        injectSectionTitle.translatesAutoresizingMaskIntoConstraints = false

        // 使用 UIScrollView 包裹所有内容, 支持垂直滚动,
        // 保证小屏设备上最底部的设备伪装按钮也能完整可见
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(card)
        contentView.addSubview(btnStack)
        contentView.addSubview(scriptSectionTitle)
        contentView.addSubview(scriptCard)
        contentView.addSubview(gestaltSectionTitle)
        contentView.addSubview(gestaltCard)
        contentView.addSubview(injectSectionTitle)

        // 动态创建注入卡片
        buildInjectCards()
        for card in injectCards {
            contentView.addSubview(card)
        }

        NSLayoutConstraint.activate([
            // 滚动容器铺满整个视图
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 内容视图与滚动视图内容区对齐, 并锁定宽度以避免横向滚动
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 36),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 30),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            btnStack.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 24),
            btnStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            btnStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 脚本控制区域
            scriptSectionTitle.topAnchor.constraint(equalTo: btnStack.bottomAnchor, constant: 28),
            scriptSectionTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            scriptCard.topAnchor.constraint(equalTo: scriptSectionTitle.bottomAnchor, constant: 10),
            scriptCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scriptCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scriptStack.topAnchor.constraint(equalTo: scriptCard.topAnchor, constant: 16),
            scriptStack.leadingAnchor.constraint(equalTo: scriptCard.leadingAnchor, constant: 16),
            scriptStack.trailingAnchor.constraint(equalTo: scriptCard.trailingAnchor, constant: -16),
            scriptStack.bottomAnchor.constraint(equalTo: scriptCard.bottomAnchor, constant: -16),

            // 设备伪装区域
            gestaltSectionTitle.topAnchor.constraint(equalTo: scriptCard.bottomAnchor, constant: 28),
            gestaltSectionTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            gestaltCard.topAnchor.constraint(equalTo: gestaltSectionTitle.bottomAnchor, constant: 10),
            gestaltCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            gestaltCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            gestaltStack.topAnchor.constraint(equalTo: gestaltCard.topAnchor, constant: 16),
            gestaltStack.leadingAnchor.constraint(equalTo: gestaltCard.leadingAnchor, constant: 16),
            gestaltStack.trailingAnchor.constraint(equalTo: gestaltCard.trailingAnchor, constant: -16),
            gestaltStack.bottomAnchor.constraint(equalTo: gestaltCard.bottomAnchor, constant: -16),

            // dylib 注入区域
            injectSectionTitle.topAnchor.constraint(equalTo: gestaltCard.bottomAnchor, constant: 28),
            injectSectionTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            // 关键: 内容底部锚定, 否则最后一块(注入按钮)会被挤出屏幕且无法滚动
            (injectCards.last ?? gestaltCard).bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])

        // 动态注入卡片约束
        for (i, card) in injectCards.enumerated() {
            let topAnchor = (i == 0)
                ? card.topAnchor.constraint(equalTo: injectSectionTitle.bottomAnchor, constant: 10)
                : card.topAnchor.constraint(equalTo: injectCards[i-1].bottomAnchor, constant: 12)
            NSLayoutConstraint.activate([
                topAnchor,
                card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            ])
        }
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

    // ===================== 设备伪装操作 =====================

    @objc private func setToiPad() {
        toiPadBtn.isEnabled = false
        toiPhoneBtn.isEnabled = false
        gestaltStatusLabel.text = "⏳ 正在修改 MobileGestalt..."
        gestaltStatusLabel.textColor = .secondaryLabel

        let model = SpoofConfig.productType
        let marketingName = MobileGestalt.marketingName(for: model)

        // 1. 写入 dylib 共享配置（给注入 QQ/微信 的 dylib 用）
        SpoofConfig.isEnabled = true

        // 2. 直接修改 MobileGestalt.plist（系统级, 影响所有 App）
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = MobileGestalt.enableIPadMode(productType: model, marketingName: marketingName)

            DispatchQueue.main.async {
                self.toiPadBtn.isEnabled = true
                self.toiPhoneBtn.isEnabled = true
                self.updateSpoofStatus()

                switch result {
                case .success(let msg):
                    self.showGestaltResult("\(msg)\n⚠️ 建议重启手机使变更完全生效", .systemGreen)
                case .failure(let err):
                    let detail = err.localizedDescription
                    self.showGestaltResult("❌ MobileGestalt 修改失败\n查看日志: /var/mobile/Library/Logs/trollserver.log", .red)
                    self.showAlert(title: "MobileGestalt 修改失败", message: detail, showLogButton: true)
                }
            }
        }
    }

    @objc private func setToiPhone() {
        toiPadBtn.isEnabled = false
        toiPhoneBtn.isEnabled = false
        gestaltStatusLabel.text = "⏳ 正在恢复 MobileGestalt..."
        gestaltStatusLabel.textColor = .secondaryLabel

        // 1. 关闭 dylib 共享配置
        SpoofConfig.isEnabled = false

        // 2. 清除 MobileGestalt.plist 中的 iPad 字段
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = MobileGestalt.disableIPadMode()

            DispatchQueue.main.async {
                self.toiPadBtn.isEnabled = true
                self.toiPhoneBtn.isEnabled = true
                self.updateSpoofStatus()

                switch result {
                case .success(let msg):
                    self.showGestaltResult("\(msg)\n⚠️ 建议重启手机使变更完全生效", .systemGreen)
                case .failure(let err):
                    let detail = err.localizedDescription
                    self.showGestaltResult("❌ 恢复失败\n查看日志: /var/mobile/Library/Logs/trollserver.log", .red)
                    self.showAlert(title: "MobileGestalt 恢复失败", message: detail, showLogButton: true)
                }
            }
        }
    }

    @objc private func openSpoofSettings() {
        let vc = SpoofSettingsViewController()
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // ===================== dylib 注入 =====================

    private func buildInjectCards() {
        injectCards.removeAll(); injectButtons.removeAll()
        injectStatusLabels.removeAll(); injectRestoreButtons.removeAll()
        injectIPAURLs.removeAll()

        for target in InjectTarget.all {
            let card = UIView()
            card.backgroundColor = .secondarySystemGroupedBackground
            card.layer.cornerRadius = 12
            card.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = UILabel()
            titleLabel.text = "\(target.icon) \(target.name)"
            titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
            titleLabel.textColor = .label

            let statusLabel = UILabel()
            statusLabel.text = "未扫描"
            statusLabel.font = UIFont.systemFont(ofSize: 12)
            statusLabel.textColor = .secondaryLabel
            statusLabel.numberOfLines = 0
            injectStatusLabels.append(statusLabel)

            let injectBtn = UIButton(type: .system)
            injectBtn.setTitle("💉 注入", for: .normal)
            injectBtn.setTitleColor(.white, for: .normal)
            injectBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            injectBtn.backgroundColor = .systemGreen
            injectBtn.layer.cornerRadius = 8
            injectBtn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            injectBtn.tag = injectButtons.count
            injectBtn.addTarget(self, action: #selector(injectTapped(_:)), for: .touchUpInside)
            injectBtn.isEnabled = false
            injectButtons.append(injectBtn)
            injectIPAURLs.append(nil)

            let restoreBtn = UIButton(type: .system)
            restoreBtn.setTitle("↩ 恢复", for: .normal)
            restoreBtn.setTitleColor(.white, for: .normal)
            restoreBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            restoreBtn.backgroundColor = .systemOrange
            restoreBtn.layer.cornerRadius = 8
            restoreBtn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            restoreBtn.tag = injectRestoreButtons.count
            restoreBtn.addTarget(self, action: #selector(restoreTapped(_:)), for: .touchUpInside)
            restoreBtn.isEnabled = false
            injectRestoreButtons.append(restoreBtn)

            let btnRow = UIStackView(arrangedSubviews: [injectBtn, restoreBtn])
            btnRow.axis = .horizontal
            btnRow.spacing = 8

            let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, btnRow])
            stack.axis = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            ])

            injectCards.append(card)
        }
    }

    private func scanAndUpdateInjectUI() {
        let apps = DylibInjector.scanInstalledApps()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (i, target) in InjectTarget.all.enumerated() {
                guard i < self.injectStatusLabels.count else { break }
                if let found = apps.first(where: { $0.target.id == target.id }) {
                    let injected = DylibInjector.isInjected(appPath: found.appPath)
                    if injected {
                        self.injectStatusLabels[i].text = "✅ 已注入（需重装恢复）"
                        self.injectStatusLabels[i].textColor = .systemGreen
                        self.injectButtons[i].isEnabled = true
                        self.injectButtons[i].setTitle("📦 重新生成 IPA", for: .normal)
                        self.injectButtons[i].backgroundColor = .systemBlue
                    } else {
                        self.injectStatusLabels[i].text = "📦 已安装，可生成 IPA"
                        self.injectStatusLabels[i].textColor = .systemOrange
                        self.injectButtons[i].isEnabled = true
                        self.injectButtons[i].setTitle("📦 生成 IPA", for: .normal)
                        self.injectButtons[i].backgroundColor = .systemGreen
                    }
                    self.injectRestoreButtons[i].isEnabled = true
                    self.injectRestoreButtons[i].setTitle("↩ 恢复原版", for: .normal)
                } else {
                    self.injectStatusLabels[i].text = "❌ 未安装 \(target.name)"
                    self.injectStatusLabels[i].textColor = .systemRed
                    self.injectButtons[i].isEnabled = false
                    self.injectRestoreButtons[i].isEnabled = false
                }
            }
        }
    }

    @objc private func injectTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx < InjectTarget.all.count else { return }
        let target = InjectTarget.all[idx]

        injectButtons[idx].isEnabled = false
        injectButtons[idx].setTitle("⏳ 生成中...", for: .normal)
        injectStatusLabels[idx].text = "⏳ 正在生成 \(target.name) 的 IPA..."

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let apps = DylibInjector.scanInstalledApps()
            guard let found = apps.first(where: { $0.target.id == target.id }) else {
                DispatchQueue.main.async {
                    self.injectStatusLabels[idx].text = "❌ 未找到 \(target.name)"
                    self.injectButtons[idx].isEnabled = false
                    self.showAlert(title: "生成失败", message: "未找到 \(target.name) App，请先安装")
                }
                return
            }
            let result = DylibInjector.generateInjectedIPA(appPath: found.appPath)
            DispatchQueue.main.async {
                switch result {
                case .success(let ipaURL):
                    self.injectIPAURLs[idx] = ipaURL
                    self.injectStatusLabels[idx].text = "✅ IPA 已生成"
                    self.injectStatusLabels[idx].textColor = .systemGreen
                    self.injectButtons[idx].setTitle("🚀 TrollStore 安装", for: .normal)
                    self.injectButtons[idx].backgroundColor = .systemBlue
                    self.injectButtons[idx].isEnabled = true
                    // 切换按钮动作为安装
                    self.injectButtons[idx].removeTarget(self, action: #selector(self.injectTapped(_:)), for: .touchUpInside)
                    self.injectButtons[idx].addTarget(self, action: #selector(self.installTapped(_:)), for: .touchUpInside)
                    self.showAlert(title: "\(target.icon) \(target.name) IPA 已生成",
                        message: "IPA 路径: \(ipaURL.path)\n\n点击 '🚀 TrollStore 安装' 自动跳转安装。\n\n⚠️ 安装前请先备份微信/QQ 数据！")
                case .failure(let err):
                    self.injectButtons[idx].isEnabled = true
                    self.injectButtons[idx].setTitle("📦 重新生成", for: .normal)
                    self.injectStatusLabels[idx].text = "❌ 生成失败"
                    self.injectStatusLabels[idx].textColor = .systemRed
                    self.showAlert(title: "生成失败: \(target.name)", message: err.localizedDescription, showLogButton: true)
                }
            }
        }
    }

    @objc private func installTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx < injectIPAURLs.count, let ipaURL = injectIPAURLs[idx] else { return }
        DylibInjector.openTrollStoreInstall(ipaURL: ipaURL)
    }

    @objc private func restoreTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx < InjectTarget.all.count else { return }
        let target = InjectTarget.all[idx]

        let alert = UIAlertController(title: "↩ 恢复 \(target.icon) \(target.name) 原版", message: "请通过 TrollStore 卸载修改版，然后重新安装 App Store 原版。\n\n注意：卸载前请备份聊天记录！", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func updateSpoofStatus() {
        let dylibOn = SpoofConfig.isEnabled
        let model = SpoofConfig.productType
        let mgOn = MobileGestalt.isIPadModeActive()
        let mgModel = MobileGestalt.currentProductType() ?? "?"

        if dylibOn && mgOn {
            gestaltStatusLabel.text = "当前：已伪装 iPad（dylib: \(model) | Gestalt: \(mgModel)）"
            gestaltStatusLabel.textColor = .systemIndigo
        } else if dylibOn {
            gestaltStatusLabel.text = "当前：dylib 伪装 iPad（\(model)）\nMobileGestalt 未修改"
            gestaltStatusLabel.textColor = .systemOrange
        } else if mgOn {
            gestaltStatusLabel.text = "当前：MobileGestalt 伪装 iPad（\(mgModel)）\ndylib 关闭"
            gestaltStatusLabel.textColor = .systemOrange
        } else {
            gestaltStatusLabel.text = "当前：未伪装（真实设备）"
            gestaltStatusLabel.textColor = .secondaryLabel
        }
    }

    /// ⚠️ 已废弃：iOS 16+ 沙盒下 MobileGestalt 不可写，改用 libiPadSpoof.dylib（见 spoof/README.md）
    private func gestaltSetDevice(isPad: Bool) {
        toiPadBtn.isEnabled = false
        toiPhoneBtn.isEnabled = false
        let target = isPad ? "iPad" : "iPhone"
        gestaltStatusLabel.text = "⏳ 正在扫描并改为 \(target)..."
        gestaltStatusLabel.textColor = .secondaryLabel

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            // ── 步骤 1: 直接探测已知路径 (不依赖 shell, iOS 沙盒下更可靠) ──
            guard let plistPath = discoverGestaltPlist() else {
                DispatchQueue.main.async {
                    self.showGestaltResult("❌ 未找到 com.apple.MobileGestalt.plist\n系统可能不支持 / 请重启后重试", .red)
                }
                return
            }

            // ── 步骤 2: 备份 ──
            let backupPath = plistPath + ".backup"
            if !FileManager.default.fileExists(atPath: backupPath) {
                try? FileManager.default.copyItem(atPath: plistPath, toPath: backupPath)
                print("[Gestalt] 💾 已备份 → \(backupPath)")
            }

            // ── 步骤 3: 读取 ──
            guard let plist = NSMutableDictionary(contentsOfFile: plistPath) else {
                DispatchQueue.main.async {
                    self.showGestaltResult("❌ 无法读取 plist (权限不足?)", .red)
                }
                return
            }

            // ── 步骤 4: 智能扫描 + 修改 ──
            // 改为 iPhone 时：从备份文件恢复原始值
            // 改为 iPad 时：用预设的 iPad 标识覆盖

            var modified: [String] = []

            if !isPad, FileManager.default.fileExists(atPath: backupPath) {
                // ── 恢复模式：从备份读取原始值，回写回当前 plist ──
                guard let backupPlist = NSDictionary(contentsOfFile: backupPath) else {
                    DispatchQueue.main.async {
                        self.showGestaltResult("❌ 备份文件损坏，无法恢复", .red)
                    }
                    return
                }

                // 收集当前 plist 的全部可修改键
                var allKeys: [(container: NSMutableDictionary, key: String, label: String)] = []
                for rootKey in plist.allKeys {
                    if let k = rootKey as? String { allKeys.append((plist, k, k)) }
                }
                for subKey in ["CacheExtra", "CacheData", "CacheInfo", "Root"] {
                    if let sub = plist[subKey] as? NSMutableDictionary {
                        for k in sub.allKeys {
                            if let sk = k as? String { allKeys.append((sub, sk, "\(subKey).\(sk)")) }
                        }
                    }
                }

                // 关键恢复字段关键词
                let restoreKeywords = ["DeviceClass", "deviceClass", "MarketingName", "marketingName",
                                        "ProductType", "productType", "DeviceName", "deviceName",
                                        "ModelNumber", "modelNumber"]

                for (container, key, label) in allKeys {
                    guard let currentVal = container[key] as? String else { continue }
                    // 只恢复 DeviceClass 相关及被改为 iPad 值的字段
                    let shouldRestore = restoreKeywords.contains(where: {
                        key == $0 || key.lowercased() == $0.lowercased() ||
                        key.lowercased().contains($0.lowercased())
                    })
                    guard shouldRestore else { continue }

                    // 查找备份中对应值
                    var backupVal: String?
                    if let v = backupPlist[key] as? String { backupVal = v }
                    // 也查子树
                    for subKey in ["CacheExtra", "CacheData", "CacheInfo", "Root"] {
                        if let sub = backupPlist[subKey] as? NSDictionary,
                           let v = sub[key] as? String { backupVal = v }
                    }
                    guard let original = backupVal, original != currentVal else { continue }

                    container[key] = original
                    modified.append("\(label): \(currentVal) → \(original)")
                    print("[Gestalt] 🔄 恢复 \(label): \(currentVal) → \(original)")
                }

                if modified.isEmpty {
                    DispatchQueue.main.async {
                        self.showGestaltResult("ℹ️ 已是原始 iPhone 值，无需恢复", .green)
                    }
                    return
                }

            } else {
                // ── 修改模式：智能匹配键名，写入 iPad 值 ──
                typealias KeyMapping = (keywords: [String], padValue: String, phoneValue: String?)
                let mappings: [KeyMapping] = [
                    (["DeviceClass", "deviceClass", "device-class"],                         "iPad",      "iPhone"),
                    (["MarketingName", "marketingName", "marketing-name"],                   "iPad",      nil),
                    (["ProductType", "productType", "product-type", "hw.product-type"],      "iPad14,2",  nil),
                    (["DeviceName", "deviceName", "device-name"],                            "iPad",      nil),
                    (["ModelNumber", "modelNumber", "model-number"],                         "A2588",     nil),
                ]

                var allKeys: [(container: NSMutableDictionary, key: String, label: String)] = []
                for rootKey in plist.allKeys {
                    if let k = rootKey as? String { allKeys.append((plist, k, k)) }
                }
                for subKey in ["CacheExtra", "CacheData", "CacheInfo", "Root"] {
                    if let sub = plist[subKey] as? NSMutableDictionary {
                        for k in sub.allKeys {
                            if let sk = k as? String { allKeys.append((sub, sk, "\(subKey).\(sk)")) }
                        }
                    }
                }

                for mapping in mappings {
                    let val = isPad ? mapping.padValue : (mapping.phoneValue ?? mapping.padValue)
                    let newValue = val

                    var bestMatch: (container: NSMutableDictionary, key: String, label: String)?
                    // 精确 → 大小写不敏感 → 包含匹配
                    for (container, key, label) in allKeys {
                        if mapping.keywords.contains(key) { bestMatch = (container, key, label); break }
                    }
                    if bestMatch == nil {
                        let lower = mapping.keywords.map { $0.lowercased() }
                        for (container, key, label) in allKeys {
                            if lower.contains(key.lowercased()) { bestMatch = (container, key, label); break }
                        }
                    }
                    if bestMatch == nil {
                        for (container, key, label) in allKeys {
                            let lk = key.lowercased()
                            for kw in mapping.keywords.map({ $0.lowercased() }) {
                                if lk.contains(kw) || kw.contains(lk) { bestMatch = (container, key, label); break }
                            }
                            if bestMatch != nil { break }
                        }
                    }
                    if let match = bestMatch {
                        let old = match.container[match.key] as? String ?? "?"
                        match.container[match.key] = newValue
                        modified.append("\(match.label): \(old) → \(newValue)")
                        print("[Gestalt] ✅ \(match.label): \(old) → \(newValue)")
                    }
                }

                guard !modified.isEmpty else {
                    let keyNames = allKeys.map { $0.label }.joined(separator: ", ")
                    DispatchQueue.main.async {
                        self.showGestaltResult("⚠️ 未找到可修改的键\n可用键: \(keyNames.prefix(300))", .orange)
                    }
                    return
                }
            }

            // ── 步骤 5: 写入 ──
            if plist.write(toFile: plistPath, atomically: true) {
                let _ = runShellCommandSimple("/usr/bin/killall -HUP cfprefsd")
                let msg = "✅ 已改为 \(target)\n\(modified.joined(separator: "\n"))\n⚠️ 请重启手机使变更生效"
                DispatchQueue.main.async {
                    self.showGestaltResult(msg, .green)
                }
                print("[Gestalt] ✅ 修改完成")
            } else {
                DispatchQueue.main.async {
                    self.showGestaltResult("❌ 写入 plist 失败", .red)
                }
            }
        }
    }

    private func showGestaltResult(_ msg: String, _ color: UIColor) {
        gestaltStatusLabel.text = msg
        gestaltStatusLabel.textColor = color
        toiPadBtn.isEnabled = true
        toiPhoneBtn.isEnabled = true
    }

    private func showAlert(title: String, message: String, showLogButton: Bool = false) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        if showLogButton {
            alert.addAction(UIAlertAction(title: "查看日志", style: .default) { _ in
                let logPath = "/var/mobile/Library/Logs/trollserver.log"
                let logContent = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "无法读取日志文件"
                let logVC = UIViewController()
                let tv = UITextView()
                tv.text = logContent
                tv.isEditable = false
                tv.font = UIFont(name: "Menlo", size: 10) ?? UIFont.systemFont(ofSize: 10)
                tv.translatesAutoresizingMaskIntoConstraints = false
                logVC.view.addSubview(tv)
                NSLayoutConstraint.activate([
                    tv.topAnchor.constraint(equalTo: logVC.view.safeAreaLayoutGuide.topAnchor),
                    tv.bottomAnchor.constraint(equalTo: logVC.view.bottomAnchor),
                    tv.leadingAnchor.constraint(equalTo: logVC.view.leadingAnchor),
                    tv.trailingAnchor.constraint(equalTo: logVC.view.trailingAnchor)
                ])
                logVC.title = "trollserver.log"
                let nav = UINavigationController(rootViewController: logVC)
                nav.modalPresentationStyle = .formSheet
                self.present(nav, animated: true)
            })
        }
        present(alert, animated: true)
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

import UIKit
import Darwin

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
    // 悬浮球控制按钮
    private let showFloatBtn = UIButton(type: .system)
    private let hideFloatBtn = UIButton(type: .system)
    private let scriptStatusLabel = UILabel()

    // 手机控制按钮
    private let rebootBtn = UIButton(type: .system)
    private let respringBtn = UIButton(type: .system)

    // 定时刷新
    private var refreshTimer: Timer?

    // 客户端模式（由 AppDelegate 启动时设置）
    var clientMode: Bool = false

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
        subtitleLabel.text = "开发者:子平  QQ:173179642"
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

        let row3 = UIStackView(arrangedSubviews: [showFloatBtn, hideFloatBtn])
        row3.axis = .horizontal
        row3.spacing = 12
        row3.distribution = .fillEqually
        row3.translatesAutoresizingMaskIntoConstraints = false

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

        let scriptStack = UIStackView(arrangedSubviews: [row1, row2, row3, scriptStatusLabel])
        scriptStack.axis = .vertical
        scriptStack.spacing = 10
        scriptStack.translatesAutoresizingMaskIntoConstraints = false
        scriptCard.addSubview(scriptStack)

        // ---- 手机控制区域 ----
        let phoneSectionTitle = UILabel()
        phoneSectionTitle.text = "📱 手机控制"
        phoneSectionTitle.font = UIFont.boldSystemFont(ofSize: 16)
        phoneSectionTitle.textColor = .label
        phoneSectionTitle.translatesAutoresizingMaskIntoConstraints = false

        let phoneRow = UIStackView(arrangedSubviews: [rebootBtn, respringBtn])
        phoneRow.axis = .horizontal
        phoneRow.spacing = 12
        phoneRow.distribution = .fillEqually
        phoneRow.translatesAutoresizingMaskIntoConstraints = false

        // 手机控制状态反馈标签
        let phoneStatusLabel = UILabel()
        phoneStatusLabel.text = ""
        phoneStatusLabel.font = UIFont.systemFont(ofSize: 12)
        phoneStatusLabel.textColor = .secondaryLabel
        phoneStatusLabel.textAlignment = .center
        phoneStatusLabel.numberOfLines = 2
        phoneStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        phoneStatusLabel.tag = 9001  // 用于 viewWithTag 查找

        // 查看日志小按钮
        let viewLogBtn = UIButton(type: .system)
        viewLogBtn.setTitle("📋 查看执行日志", for: .normal)
        viewLogBtn.titleLabel?.font = UIFont.systemFont(ofSize: 11)
        viewLogBtn.setTitleColor(.systemGray, for: .normal)
        viewLogBtn.addTarget(self, action: #selector(viewPhoneLog), for: .touchUpInside)
        viewLogBtn.translatesAutoresizingMaskIntoConstraints = false

        let phoneCard = UIView()
        phoneCard.backgroundColor = .secondarySystemGroupedBackground
        phoneCard.layer.cornerRadius = 12
        phoneCard.translatesAutoresizingMaskIntoConstraints = false

        let phoneStack = UIStackView(arrangedSubviews: [phoneRow, phoneStatusLabel, viewLogBtn])
        phoneStack.axis = .vertical
        phoneStack.spacing = 10
        phoneStack.translatesAutoresizingMaskIntoConstraints = false
        phoneCard.addSubview(phoneStack)

        // 配置手机控制按钮
        _ = {
            let configs: [(UIButton, String, UIColor, Selector)] = [
                (rebootBtn,   "🔄 重启手机", UIColor(red: 0.85, green: 0.22, blue: 0.18, alpha: 1.0), #selector(rebootDevice)),
                (respringBtn, "🔄 注销手机", UIColor(red: 0.95, green: 0.52, blue: 0.10, alpha: 1.0), #selector(respringDevice)),
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

        // 配置按钮
        _ = {
            let configs: [(UIButton, String, UIColor, Selector)] = [
                (startBtn,     "▶ 启动",       UIColor.systemGreen,  #selector(scriptStart)),
                (stopBtn,      "⏹ 停止",       UIColor.systemRed,    #selector(scriptStop)),
                (pauseBtn,     "⏸ 暂停",       UIColor.systemOrange, #selector(scriptPause)),
                (resumeBtn,    "▶ 恢复",       UIColor.systemBlue,   #selector(scriptResume)),
                (showFloatBtn, "🔵 显示悬浮球", UIColor.systemTeal,   #selector(scriptShowFloat)),
                (hideFloatBtn, "🔴 隐藏悬浮球", UIColor.systemGray,   #selector(scriptHideFloat)),
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

        // 使用 UIScrollView 包裹所有内容, 支持垂直滚动
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
        contentView.addSubview(phoneSectionTitle)
        contentView.addSubview(phoneCard)

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

            // 手机控制区域
            phoneSectionTitle.topAnchor.constraint(equalTo: scriptCard.bottomAnchor, constant: 28),
            phoneSectionTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            phoneCard.topAnchor.constraint(equalTo: phoneSectionTitle.bottomAnchor, constant: 10),
            phoneCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            phoneCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            phoneStack.topAnchor.constraint(equalTo: phoneCard.topAnchor, constant: 16),
            phoneStack.leadingAnchor.constraint(equalTo: phoneCard.leadingAnchor, constant: 16),
            phoneStack.trailingAnchor.constraint(equalTo: phoneCard.trailingAnchor, constant: -16),
            phoneStack.bottomAnchor.constraint(equalTo: phoneCard.bottomAnchor, constant: -16),

            // 关键: 内容底部锚定, 否则最后一块会被挤出屏幕且无法滚动
            phoneCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
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

    // ===================== 手机控制操作 =====================

    /// 日志文件路径
    private static let phoneLogPath = "/var/mobile/Library/Logs/trollserver_phone.log"

    /// 写日志到文件 + print
    private func phoneLog(_ msg: String) {
        let line = "[\(DateFormatter.phoneLogFormatter.string(from: Date()))] \(msg)"
        print(line)
        // 追加写入文件
        if let data = (line + "\n").data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: Self.phoneLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                // 首次创建
                try? (line + "\n").write(toFile: Self.phoneLogPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 更新手机控制状态标签
    private func updatePhoneStatus(_ text: String, color: UIColor = .secondaryLabel) {
        DispatchQueue.main.async { [weak self] in
            if let label = self?.view.viewWithTag(9001) as? UILabel {
                label.text = text
                label.textColor = color
            }
        }
    }

    /// 查看手机控制日志
    @objc private func viewPhoneLog() {
        let logContent = (try? String(contentsOfFile: Self.phoneLogPath, encoding: .utf8))
            ?? "暂无日志"

        let alert = UIAlertController(
            title: "📋 手机控制执行日志",
            message: logContent,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "关闭", style: .default))
        alert.addAction(UIAlertAction(title: "清空日志", style: .destructive) { _ in
            try? "".write(toFile: Self.phoneLogPath, atomically: true, encoding: .utf8)
            self.updatePhoneStatus("日志已清空", color: .systemGray)
        })
        present(alert, animated: true)
    }

    // MARK: - 重启手机

    @objc private func rebootDevice() {
        let alert = UIAlertController(
            title: "⚠️ 重启手机",
            message: "确定要重启手机吗？\n重启后设备将断开连接。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认重启", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.updatePhoneStatus("⏳ 正在重启...", color: .systemOrange)
            self.performReboot()
        })
        present(alert, animated: true)
    }

    private func performReboot() {
        phoneLog("========== 开始重启手机 ==========")

        // 先同步磁盘
        sync()
        phoneLog("✅ sync() 完成")

        // 禁用按钮
        DispatchQueue.main.async { [weak self] in
            self?.rebootBtn.isEnabled = false
            self?.respringBtn.isEnabled = false
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 方法1: 直接 reboot(0) — 如果本进程有 root 权限则直接重启
            self.phoneLog("[1/3] 直接 reboot() 尝试 (UID=\(getuid()))...")
            var ret = reboot(0)
            self.phoneLog("      reboot(0) => ret=\(ret) errno=\(errno): \(String(cString: strerror(errno)))")
            if ret != 0 {
                self.phoneLog("[2/3] 直接 reboot(0x400)...")
                ret = reboot(0x400)
                self.phoneLog("      reboot(0x400) => ret=\(ret) errno=\(errno): \(String(cString: strerror(errno)))")
            }

            // 方法2: 通过 HTTP 调用本地 daemon（daemon 以 root 运行，可以重启）
            self.phoneLog("[3/3] 通过 HTTP 调用本地 daemon (127.0.0.1:51111/api/reboot)...")
            let url = URL(string: "http://127.0.0.1:51111/api/reboot")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 5

            let sem = DispatchSemaphore(value: 0)
            var daemonResult = "未收到响应"
            let task = URLSession.shared.dataTask(with: req) { data, response, error in
                if let httpResp = response as? HTTPURLResponse {
                    daemonResult = "HTTP \(httpResp.statusCode)"
                    if let d = data, let body = String(data: d, encoding: .utf8) {
                        daemonResult += " body=\(body.prefix(80))"
                    }
                } else if let err = error {
                    daemonResult = "请求失败: \(err.localizedDescription)"
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 6)

            self.phoneLog("      daemon 结果: \(daemonResult)")

            // 如果 daemon 成功执行 reboot，设备会重启，不会执行到这里
            let currentUID = getuid()
            var msg: String
            if currentUID != 0 {
                msg = "所有重启方法均未生效\n"
                msg += "直接调用: EPERM (权限不足)\n"
                msg += "Daemon: \(daemonResult)\n\n"
                msg += "诊断: 当前 UID=501(mobile)，应用未获得 root 权限。\n\n"
                msg += "解决步骤:\n"
                msg += "1. 打开 TrollStore → Settings → 开启 'Enable Helper'\n"
                msg += "2. 在 TrollStore 中卸载后重新安装为 System 应用\n"
                msg += "3. 确认 TrollStore 版本 >= 2.0\n"
                msg += "4. 安装后打开一次 App，再试重启\n\n"
                msg += "如果仍失败，说明当前环境缺少 setuid 二进制，\n"
                msg += "可能需要配合 palera1n/Dopamine 等 bootstrap 使用。"
            } else {
                msg = "所有重启方法均未生效\n直接调用: EPERM\nDaemon: \(daemonResult)"
            }
            self.phoneLog("❌ \(msg)")
            self.updatePhoneStatus(msg, color: .systemRed)

            DispatchQueue.main.async { [weak self] in
                self?.rebootBtn.isEnabled = true
                self?.respringBtn.isEnabled = true
                self?.showPhoneResultAlert("重启失败", msg)
            }
        }
    }

    // MARK: - 注销手机

    @objc private func respringDevice() {
        let alert = UIAlertController(
            title: "⚠️ 注销手机",
            message: "确定要注销（Respring）手机吗？\nSpringBoard 将重新启动。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认注销", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.updatePhoneStatus("⏳ 正在注销...", color: .systemOrange)
            self.performRespring()
        })
        present(alert, animated: true)
    }

    private func performRespring() {
        phoneLog("========== 开始注销手机 (Respring) ==========")

        DispatchQueue.main.async { [weak self] in
            self?.rebootBtn.isEnabled = false
            self?.respringBtn.isEnabled = false
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 方法1: 通过系统 API 获取 SpringBoard PID，直接 kill(SIGKILL)
            self.phoneLog("[1/2] 查找 SpringBoard PID 并发送 SIGKILL...")
            if let pid = self.getProcessPID(named: "SpringBoard") {
                self.phoneLog("      找到 SpringBoard PID=\(pid)，发送 SIGKILL...")
                let ret = kill(pid, SIGKILL)
                self.phoneLog("      kill(\(pid), SIGKILL) => ret=\(ret) errno=\(errno)")
                if ret == 0 {
                    self.phoneLog("✅ SIGKILL 已成功发送给 SpringBoard")
                    DispatchQueue.main.async { [weak self] in
                        self?.updatePhoneStatus("✅ SpringBoard 已终止，正在注销...", color: .systemGreen)
                    }
                    return
                }
            }

            // 方法2: 杀死 backboardd
            self.phoneLog("[2/2] 查找 backboardd PID 并发送 SIGKILL...")
            if let pid = self.getProcessPID(named: "backboardd") {
                self.phoneLog("      找到 backboardd PID=\(pid)，发送 SIGKILL...")
                let ret = kill(pid, SIGKILL)
                self.phoneLog("      kill(\(pid), SIGKILL) => ret=\(ret) errno=\(errno)")
                if ret == 0 {
                    self.phoneLog("✅ SIGKILL 已成功发送给 backboardd")
                    DispatchQueue.main.async { [weak self] in
                        self?.updatePhoneStatus("✅ backboardd 已终止，正在注销...", color: .systemGreen)
                    }
                    return
                }
            }

            let msg = "注销失败：未找到目标进程或发送信号失败"
            self.phoneLog("❌ \(msg)")
            self.updatePhoneStatus(msg, color: .systemRed)

            DispatchQueue.main.async { [weak self] in
                self?.rebootBtn.isEnabled = true
                self?.respringBtn.isEnabled = true
                self?.showPhoneResultAlert("注销失败", msg)
            }
        }
    }

    // MARK: - 核心工具

    /// 执行 shell 命令并返回 exitCode（精简版，用于手机控制）
    @discardableResult
    private func phoneShell(_ command: String) -> Int32 {
        var pid: pid_t = 0
        let shellPath = findAvailableShell() ?? "/bin/sh"
        let cArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup(shellPath),
            strdup("-c"),
            strdup(command),
            nil
        ]
        defer { cArgs.forEach { $0.map { free($0) } } }

        let ret = posix_spawn(&pid, shellPath, nil, nil, cArgs, nil)
        guard ret == 0 else {
            phoneLog("      posix_spawn 失败: \(ret)")
            return ret
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        phoneLog("      shell 输出: pid=\(pid) rawStatus=\(status)")
        return (status >> 8) & 0xFF
    }

    /// 获取指定名称进程的 PID（不依赖 shell）
    private func getProcessPID(named: String) -> pid_t? {
        let maxPids = 4096
        let bufferSize = MemoryLayout<pid_t>.size * maxPids
        var buffer = [pid_t](repeating: 0, count: maxPids)
        let count = proc_listpids(1, 0, &buffer, Int32(bufferSize))
        let numPids = Int(count) / MemoryLayout<pid_t>.size
        
        for i in 0..<numPids {
            let pid = buffer[i]
            if pid <= 0 { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLen = proc_name(pid, &nameBuffer, 256)
            if nameLen > 0 {
                let name = String(cString: nameBuffer)
                if name == named {
                    phoneLog("      找到 \(named) PID=\(pid)")
                    return pid
                }
            }
        }
        phoneLog("      ⚠️ 未找到 \(named)")
        return nil
    }

    /// 弹窗显示执行结果
    private func showPhoneResultAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        alert.addAction(UIAlertAction(title: "查看日志", style: .default) { [weak self] _ in
            self?.viewPhoneLog()
        })
        present(alert, animated: true)
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

    @objc private func scriptShowFloat() {
        sendFloatCommand(x: 0, y: 500, action: "显示悬浮球")
    }

    @objc private func scriptHideFloat() {
        sendFloatCommand(x: 0, y: -100, action: "隐藏悬浮球")
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
        showFloatBtn.isEnabled = enabled
        hideFloatBtn.isEnabled = enabled
    }

    private func sendFloatCommand(x: Int, y: Int, action: String) {
        setScriptButtonsEnabled(false)
        scriptStatusLabel.text = "⏳ 正在\(action)..." 
        scriptStatusLabel.textColor = .secondaryLabel

        let urlString = "http://127.0.0.1:8989/float?x=\(x)&y=\(y)"
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

        print("[Float] 📤 \(action): \(urlString)")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                let msg = "\(action)失败: \(error.localizedDescription)"
                print("[Float] ❌ \(msg)")
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
            let msg = "\(success ? "✅" : "⚠️") \(action) - HTTP \(statusCode): \(body.prefix(200))"
            print("[Float] \(msg)")

            DispatchQueue.main.async {
                self.setScriptButtonsEnabled(true)
                self.scriptStatusLabel.text = msg
                self.scriptStatusLabel.textColor = success ? .systemGreen : .systemRed
            }
        }
        task.resume()
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

// MARK: - DateFormatter 工具
extension DateFormatter {
    static let phoneLogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
}

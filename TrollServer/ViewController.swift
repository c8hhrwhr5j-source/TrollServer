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

        let phoneCard = UIView()
        phoneCard.backgroundColor = .secondarySystemGroupedBackground
        phoneCard.layer.cornerRadius = 12
        phoneCard.translatesAutoresizingMaskIntoConstraints = false

        let phoneStack = UIStackView(arrangedSubviews: [phoneRow])
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

    // MARK: - 重启手机（多级回退 + 直接系统调用）

    @objc private func rebootDevice() {
        let alert = UIAlertController(
            title: "⚠️ 重启手机",
            message: "确定要重启手机吗？重启后设备将断开连接。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认重启", style: .destructive) { [weak self] _ in
            self?.performReboot()
        })
        present(alert, animated: true)
    }

    private func performReboot() {
        print("[PhoneControl] ╔══════════════════════════════╗")
        print("[PhoneControl] ║  🔄 执行「重启手机」         ║")
        print("[PhoneControl] ╚══════════════════════════════╝")

        // 0. 先同步文件系统
        sync()
        print("[PhoneControl] [prep] ✅ sync() 完成")

        // 状态反馈：更新 scriptStatusLabel 提示用户
        DispatchQueue.main.async { [weak self] in
            self?.scriptStatusLabel.text = "⏳ 正在重启手机..."
            self?.scriptStatusLabel.textColor = .systemOrange
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 方法1: 直接 reboot() 系统调用 (内核级，最可靠)
            print("[PhoneControl] [1/4] reboot(0) 系统调用...")
            var ret = reboot(0)
            print("[PhoneControl]       reboot(0) => \(ret) | errno=\(errno): \(String(cString: strerror(errno)))")

            // 方法2: 尝试 reboot(RB_AUTOBOOT) 即 reboot(0x400)
            if ret != 0 {
                print("[PhoneControl] [2/4] reboot(0x400) 系统调用...")
                ret = reboot(0x400)
                print("[PhoneControl]       reboot(0x400) => \(ret) | errno=\(errno): \(String(cString: strerror(errno)))")
            }

            // 方法3: /bin/launchctl reboot (全路径避免 PATH 问题)
            print("[PhoneControl] [3/4] /bin/launchctl reboot...")
            if self.commandExists("/bin/launchctl") {
                let r = runShellCommand("/bin/launchctl reboot 2>&1")
                print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")
            } else {
                print("[PhoneControl]       ⚠️ /bin/launchctl 不存在")
            }

            // 方法4: launchctl reboot userspace (用户空间重启，兼容旧版 iOS)
            print("[PhoneControl] [4/4] /bin/launchctl reboot userspace...")
            if self.commandExists("/bin/launchctl") {
                let r = runShellCommand("/bin/launchctl reboot userspace 2>&1")
                print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")
            }

            print("[PhoneControl] ⚠️ 所有方法均已尝试，若未重启请检查日志")
            DispatchQueue.main.async { [weak self] in
                self?.scriptStatusLabel.text = "⚠️ 重启指令已发送，若 3 秒后未重启请检查日志"
                self?.scriptStatusLabel.textColor = .systemYellow
            }
        }
    }

    // MARK: - 注销手机（Respring，多级回退）

    @objc private func respringDevice() {
        let alert = UIAlertController(
            title: "⚠️ 注销手机",
            message: "确定要注销（Respring）手机吗？SpringBoard 将重新启动。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认注销", style: .destructive) { [weak self] _ in
            self?.performRespring()
        })
        present(alert, animated: true)
    }

    private func performRespring() {
        print("[PhoneControl] ╔══════════════════════════════╗")
        print("[PhoneControl] ║  🔄 执行「注销手机」         ║")
        print("[PhoneControl] ╚══════════════════════════════╝")

        DispatchQueue.main.async { [weak self] in
            self?.scriptStatusLabel.text = "⏳ 正在注销手机..."
            self?.scriptStatusLabel.textColor = .systemOrange
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 方法1: killall -9 SpringBoard (直接可靠)
            print("[PhoneControl] [1/5] killall -9 SpringBoard...")
            var r = runShellCommand("killall -9 SpringBoard 2>&1")
            print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")

            // 方法2: 通过 ps 获取 SpringBoard PID 直接 kill (更精确)
            print("[PhoneControl] [2/5] ps + grep 查找 SpringBoard PID...")
            if let pid = self.getPID(of: "SpringBoard") {
                print("[PhoneControl]       找到 PID=\(pid)，发送 SIGKILL...")
                let ret = kill(pid, SIGKILL)
                print("[PhoneControl]       kill(\(pid),SIGKILL)=>\(ret) errno=\(errno)")
            } else {
                // 备用方式: pgrep (部分系统可用)
                let pgR = runShellCommand("pgrep -x SpringBoard 2>/dev/null")
                if let pid2 = pid_t(pgR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), pid2 > 0 {
                    print("[PhoneControl]       (pgrep) 找到 PID=\(pid2)，发送 SIGKILL...")
                    kill(pid2, SIGKILL)
                } else {
                    print("[PhoneControl]       ⚠️ 未找到 SpringBoard 进程")
                }
            }

            // 方法3: launchctl kickstart backboardd (优雅重启)
            print("[PhoneControl] [3/5] /bin/launchctl kickstart backboardd...")
            r = runShellCommand("/bin/launchctl kickstart -k system/com.apple.backboardd 2>&1")
            print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")

            // 方法4: killall -9 backboardd (备选)
            print("[PhoneControl] [4/5] killall -9 backboardd...")
            r = runShellCommand("killall -9 backboardd 2>&1")
            print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")

            // 方法5: sbreload (部分越狱设备可用)
            print("[PhoneControl] [5/5] sbreload...")
            r = runShellCommand("sbreload 2>&1")
            print("[PhoneControl]       exitCode=\(r.exitCode) out=\(r.stdout.prefix(200))")

            print("[PhoneControl] ⚠️ 所有方法均已尝试")
            DispatchQueue.main.async { [weak self] in
                self?.scriptStatusLabel.text = "⚠️ 注销指令已发送，若未生效请检查日志"
                self?.scriptStatusLabel.textColor = .systemYellow
            }
        }
    }

    // MARK: - 工具方法

    /// 检查命令是否存在且可执行
    private func commandExists(_ path: String) -> Bool {
        if access(path, X_OK) == 0 { return true }
        let r = runShellCommand("which \(path) 2>/dev/null")
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 通过进程名获取 PID（兼容 BusyBox / 标准 ps）
    private func getPID(of processName: String) -> pid_t? {
        let r = runShellCommand("ps ax 2>/dev/null | grep -w \(processName) | grep -v grep | awk '{print $1}' | head -1")
        let pidStr = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pidStr.isEmpty, let pid = pid_t(pidStr), pid > 0 else { return nil }
        return pid
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

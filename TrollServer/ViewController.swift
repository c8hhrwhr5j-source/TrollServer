import UIKit

// ============================================================
//  主界面控制器 - 显示服务器状态、守护进程信息
//  支持手动启动/停止 WebDAV 服务、查看连接统计
// ============================================================

class ViewController: UIViewController {
    
    private let serverRunner: DaemonServerRunner
    
    // 状态标签
    private let daemonStatusLabel = UILabel()
    private let webdavStatusLabel = UILabel()
    private let scriptStatusLabel = UILabel()
    private let connectionsLabel = UILabel()
    private let ipAddressLabel = UILabel()
    private let basePathLabel = UILabel()
    
    // 控制按钮
    private let restartWebDAVBtn = UIButton(type: .system)
    private let reloadDaemonBtn = UIButton(type: .system)
    
    // 定时刷新
    private var refreshTimer: Timer?
    
    init(serverRunner: DaemonServerRunner) {
        self.serverRunner = serverRunner
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    // MARK: - 生命周期
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startRefreshTimer()
        updateStatus()
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStatus),
            name: .serviceWatchdogDidHeal, object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
    }
    
    // MARK: - UI 布局
    
    private func setupUI() {
        view.backgroundColor = UIColor.systemGroupedBackground
        
        // 标题
        let titleLabel = UILabel()
        titleLabel.text = "TrollServer"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let subtitleLabel = UILabel()
        subtitleLabel.text = "文件服务 · 全自动常驻（看门狗 12s）"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // 状态卡片容器
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        
        // 各状态行
        daemonStatusLabel.font = UIFont.systemFont(ofSize: 15)
        daemonStatusLabel.numberOfLines = 0
        
        webdavStatusLabel.font = UIFont.systemFont(ofSize: 15)
        webdavStatusLabel.numberOfLines = 0
        
        scriptStatusLabel.font = UIFont.systemFont(ofSize: 15)
        scriptStatusLabel.numberOfLines = 0
        
        connectionsLabel.font = UIFont.systemFont(ofSize: 13)
        connectionsLabel.textColor = .secondaryLabel
        
        ipAddressLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        ipAddressLabel.textColor = .systemBlue
        
        basePathLabel.font = UIFont.systemFont(ofSize: 13)
        basePathLabel.textColor = .secondaryLabel
        
        let stackView = UIStackView(arrangedSubviews: [
            daemonStatusLabel, webdavStatusLabel, scriptStatusLabel,
            connectionsLabel, ipAddressLabel, basePathLabel
        ])
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        statusCard.addSubview(stackView)
        
        // 按钮
        restartWebDAVBtn.setTitle("重启 WebDAV 服务", for: .normal)
        restartWebDAVBtn.addTarget(self, action: #selector(restartWebDAV), for: .touchUpInside)
        restartWebDAVBtn.translatesAutoresizingMaskIntoConstraints = false
        restartWebDAVBtn.backgroundColor = .systemBlue
        restartWebDAVBtn.setTitleColor(.white, for: .normal)
        restartWebDAVBtn.layer.cornerRadius = 8
        restartWebDAVBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        
        reloadDaemonBtn.setTitle("立即修复", for: .normal)
        reloadDaemonBtn.addTarget(self, action: #selector(reloadDaemon), for: .touchUpInside)
        reloadDaemonBtn.translatesAutoresizingMaskIntoConstraints = false
        reloadDaemonBtn.backgroundColor = .systemGray4
        reloadDaemonBtn.layer.cornerRadius = 8
        reloadDaemonBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        
        let buttonStack = UIStackView(arrangedSubviews: [restartWebDAVBtn, reloadDaemonBtn])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        
        // 布局
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(statusCard)
        view.addSubview(buttonStack)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            statusCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 30),
            statusCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            stackView.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -20),
            
            buttonStack.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 24),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
    
    // MARK: - 定时刷新
    
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }
    
    // MARK: - 状态防抖动（防止"运行中"↔"自动修复中"快速切换）
    
    private var lastRunningTime: Date = .distantPast
    private let statusDebounceDuration: TimeInterval = 5.0  // 服务中断 5 秒内仍显示"运行中"
    
    // MARK: - 状态更新 (在后台线程检测守护进程状态，避免卡UI)
    
    @objc private func updateStatus() {
        let iconRunning = "●"
        let iconStopped = "○"
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let daemonStatus = DaemonInstaller.getStatus()
            let daemonInstalled = daemonStatus.installed
            let daemonRunning = daemonStatus.running
            let daemonPID = daemonStatus.pid
            let port51111Up = LocalPortChecker.isOpen(51111)
            let port8989Up = LocalPortChecker.isOpen(8989)
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                let now = Date()
                
                // 端口通了就算"运行中"，不管 launchctl 返回什么
                let serviceActuallyUp = port51111Up && port8989Up
                let daemonEffectiveRunning = daemonRunning || serviceActuallyUp
                
                // 记录最近一次"运行中"的时间
                if daemonEffectiveRunning {
                    self.lastRunningTime = now
                }
                
                // 防抖动：如果最近 5 秒内服务还在运行，保持"运行中"
                let inDebounceWindow = !daemonEffectiveRunning && now.timeIntervalSince(self.lastRunningTime) < self.statusDebounceDuration
                let displayAsRunning = daemonEffectiveRunning || inDebounceWindow
                
                let daemonIcon = displayAsRunning ? iconRunning : iconStopped
                let daemonColor: String
                if daemonEffectiveRunning {
                    daemonColor = "运行中"
                } else if inDebounceWindow {
                    daemonColor = "运行中（检测中…）"
                } else if daemonInstalled {
                    daemonColor = "自动修复中…"
                } else {
                    daemonColor = "自动安装中…"
                }
                
                self.daemonStatusLabel.attributedText = self.buildStatusLine(
                    icon: daemonIcon, title: "守护进程", detail: "\(daemonColor) \(daemonPID.map { "(PID: \($0))" } ?? "")",
                    ok: displayAsRunning
                )
                
                // WebDAV 状态（端口监听或守护进程托管即视为运行中）
                let webdavStats = self.serverRunner.webdavServer?.getStats()
                let wRunning = port51111Up || daemonRunning || (webdavStats?.running ?? false)
                let wConn = webdavStats?.connections ?? 0
                let wPort = webdavStats?.port ?? 51111
                let wDetail = daemonRunning && webdavStats?.running != true
                    ? "端口 \(wPort) · 守护进程托管"
                    : "端口 \(wPort) · \(wConn) 次请求"
                self.webdavStatusLabel.attributedText = self.buildStatusLine(
                    icon: wRunning ? iconRunning : iconStopped,
                    title: "WebDAV 文件服务", detail: wDetail,
                    ok: wRunning
                )
                
                // 脚本控制状态
                let sStatus = self.serverRunner.scriptServer?.getStatus()
                let sRunning = port8989Up || daemonRunning || (sStatus?.running ?? false)
                self.scriptStatusLabel.attributedText = self.buildStatusLine(
                    icon: sRunning ? iconRunning : iconStopped,
                    title: "脚本控制 (转发)", detail: "端口 8989 → \(sStatus?.forwardTo ?? "localhost:8899")",
                    ok: sRunning
                )
                
                self.connectionsLabel.text = "服务端口: WebDAV \(wPort) | 脚本转发 8989 | 基路径: /var/mobile/Downloads"
                
                if let ip = self.getWiFiIP() {
                    self.ipAddressLabel.text = "📶 \(ip)"
                } else {
                    self.ipAddressLabel.text = "⚠️ 未连接 WiFi"
                }
            }
        }
    }
    
    private func buildStatusLine(icon: String, title: String, detail: String, ok: Bool) -> NSAttributedString {
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(
            string: "\(icon) \(title)  ",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        ))
        attr.append(NSAttributedString(
            string: detail,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: ok ? UIColor.systemGreen : UIColor.systemRed
            ]
        ))
        return attr
    }
    
    // MARK: - 操作
    
    @objc private func restartWebDAV() {
        serverRunner.webdavServer?.stop()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            try? self?.serverRunner.webdavServer?.start()
            DispatchQueue.main.async { self?.updateStatus() }
        }
    }
    
    @objc private func reloadDaemon() {
        ServiceWatchdog.shared.healNow()
        updateStatus()
    }
    
    // MARK: - 工具
    
    private func getWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let flags = Int32(ptr!.pointee.ifa_flags)
            let addr = ptr!.pointee.ifa_addr
            if addr?.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0 {
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

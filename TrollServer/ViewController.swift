import UIKit

// ============================================================
//  主界面控制器 - 显示脚本控制服务器状态 + 快捷指令按钮
// ============================================================

class ViewController: UIViewController {

    private let serverRunner: DaemonServerRunner

    private let scriptStatusLabel = UILabel()
    private let ipAddressLabel = UILabel()

    private var refreshTimer: Timer?

    // 按钮
    private let startBtn = UIButton(type: .system)
    private let stopBtn = UIButton(type: .system)
    private let pauseBtn = UIButton(type: .system)
    private let resumeBtn = UIButton(type: .system)
    private let hideFloatBtn = UIButton(type: .system)
    private let showFloatBtn = UIButton(type: .system)

    init(serverRunner: DaemonServerRunner) {
        self.serverRunner = serverRunner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

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
        subtitleLabel.text = "脚本控制服务"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // 状态卡片
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        scriptStatusLabel.font = UIFont.systemFont(ofSize: 15)
        scriptStatusLabel.numberOfLines = 0
        ipAddressLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        ipAddressLabel.textColor = .systemBlue

        let stackView = UIStackView(arrangedSubviews: [scriptStatusLabel, ipAddressLabel])
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(stackView)

        // 任务控制按钮
        let taskLabel = makeSectionLabel("任务控制")
        setupButton(startBtn, title: "启动脚本", color: .systemGreen, action: #selector(sendStart))
        setupButton(stopBtn, title: "停止脚本", color: .systemRed, action: #selector(sendStop))
        setupButton(pauseBtn, title: "暂停脚本", color: .systemOrange, action: #selector(sendPause))
        setupButton(resumeBtn, title: "恢复脚本", color: .systemBlue, action: #selector(sendResume))

        let taskRow1 = makeButtonRow([startBtn, stopBtn])
        let taskRow2 = makeButtonRow([pauseBtn, resumeBtn])

        // 悬浮窗控制按钮
        let floatLabel = makeSectionLabel("悬浮窗控制")
        setupButton(hideFloatBtn, title: "隐藏悬浮", color: .systemGray, action: #selector(sendHideFloat))
        setupButton(showFloatBtn, title: "显示悬浮", color: .systemBlue, action: #selector(sendShowFloat))

        let floatRow = makeButtonRow([hideFloatBtn, showFloatBtn])

        // 滚动视图（防止小屏幕装不下）
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(statusCard)
        contentView.addSubview(taskLabel)
        contentView.addSubview(taskRow1)
        contentView.addSubview(taskRow2)
        contentView.addSubview(floatLabel)
        contentView.addSubview(floatRow)

        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            statusCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            statusCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            stackView.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -16),

            taskLabel.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 24),
            taskLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            taskRow1.topAnchor.constraint(equalTo: taskLabel.bottomAnchor, constant: 8),
            taskRow1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            taskRow2.topAnchor.constraint(equalTo: taskRow1.bottomAnchor, constant: 10),
            taskRow2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            floatLabel.topAnchor.constraint(equalTo: taskRow2.bottomAnchor, constant: 20),
            floatLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            floatRow.topAnchor.constraint(equalTo: floatLabel.bottomAnchor, constant: 8),
            floatRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            floatRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            floatRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
        ])
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.boldSystemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func setupButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        btn.layer.cornerRadius = 10
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 48).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    private func makeButtonRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - 定时刷新

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        let iconRunning = "●"
        let iconStopped = "○"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let sStatus = self.serverRunner.scriptServer?.getStatus()
            let sRunning = sStatus?.running ?? false

            DispatchQueue.main.async {
                let attr = NSMutableAttributedString()
                attr.append(NSAttributedString(
                    string: "\(sRunning ? iconRunning : iconStopped) 脚本控制 (转发)",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: UIColor.label
                    ]
                ))
                attr.append(NSAttributedString(
                    string: "  端口 8989 → \(sStatus?.forwardTo ?? "localhost:8899")",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 13),
                        .foregroundColor: sRunning ? UIColor.systemGreen : UIColor.systemRed
                    ]
                ))
                self.scriptStatusLabel.attributedText = attr

                if let ip = self.getWiFiIP() {
                    self.ipAddressLabel.text = "\u{1F4F6} \(ip)"
                } else {
                    self.ipAddressLabel.text = "\u{26A0}\u{FE0F} 未连接 WiFi"
                }
            }
        }
    }

    // MARK: - 网络请求

    private func sendRequest(_ path: String) {
        guard let url = URL(string: "http://127.0.0.1:8989\(path)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[UI] \(path) request failed: \(error.localizedDescription)")
            } else if let httpResp = response as? HTTPURLResponse {
                print("[UI] \(path) -> HTTP \(httpResp.statusCode)")
            }
        }.resume()
    }

    @objc private func sendStart()    { sendRequest("/task?cmd=start") }
    @objc private func sendStop()     { sendRequest("/task?cmd=stop") }
    @objc private func sendPause()    { sendRequest("/task?cmd=pause") }
    @objc private func sendResume()   { sendRequest("/task?cmd=resume") }
    @objc private func sendHideFloat(){ sendRequest("/float?x=0&y=-100") }
    @objc private func sendShowFloat(){ sendRequest("/float?x=1&y=100") }

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

import UIKit

// ============================================================
//  主界面控制器
//  功能：脚本控制按钮 | 下载安装最新脚本 | 实时日志
// ============================================================

// 日志缓冲区（支持 AccessoryKit 样式）
private let sharedLogBuffer = NSMutableAttributedString()
private var logUpdateHandler: (() -> Void)?

class ViewController: UIViewController {

    private let serverRunner: DaemonServerRunner

    // 状态
    private let ipAddressLabel = UILabel()
    private let installStatusLabel = UILabel()

    private var refreshTimer: Timer?

    // 脚本控制按钮
    private let startBtn = UIButton(type: .system)
    private let stopBtn  = UIButton(type: .system)
    private let pauseBtn = UIButton(type: .system)
    private let resumeBtn = UIButton(type: .system)
    private let hideFloatBtn = UIButton(type: .system)
    private let showFloatBtn = UIButton(type: .system)

    // 下载安装
    private let downloadBtn = UIButton(type: .system)
    private let progressLabel = UILabel()

    // 日志区域
    private let logTextView = UITextView()

    // 临时存储
    private var downloadedIPAPath: String?
    private var activeDownloadDelegate: DownloadDelegate? // 持有 delegate 防止被释放

    // ============================================================
    // MARK: - 硬编码下载地址（主 → 备用）
    // ============================================================
    private let primaryURL   = "https://gitee.com/ziping8888/mir/releases/download/2.0/app-release.ipa"
    private let fallbackURL  = "https://github.com/c8hhrwhr5j-source/app-updates/releases/download/1.1/app-release.ipa"

    // ============================================================
    // MARK: - Init
    // ============================================================

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

        logUpdateHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.logTextView.attributedText = sharedLogBuffer
                // 滚动到底部
                let range = NSMakeRange(sharedLogBuffer.length, 0)
                self?.logTextView.scrollRangeToVisible(range)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
    }

    // ============================================================
    // MARK: - 日志系统
    // ============================================================

    private enum LogLevel { case info, success, error, progress }

    private func appLog(_ msg: String, level: LogLevel = .info) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())

        let color: UIColor
        switch level {
        case .info:     color = UIColor.label
        case .success:  color = UIColor.systemGreen
        case .error:    color = UIColor.systemRed
        case .progress: color = UIColor.systemOrange
        }

        if sharedLogBuffer.length > 0 {
            sharedLogBuffer.append(NSAttributedString(string: "\n"))
        }
        sharedLogBuffer.append(NSAttributedString(
            string: "[\(ts)] ",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.secondaryLabel]
        ))
        sharedLogBuffer.append(NSAttributedString(
            string: msg,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]
        ))
        logUpdateHandler?()
    }

    // ============================================================
    // MARK: - UI 布局
    // ============================================================

    private func setupUI() {
        view.backgroundColor = UIColor.systemGroupedBackground

        let titleLabel = UILabel()
        titleLabel.text = "TrollServer"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = UILabel()
        subtitleLabel.text = "脚本控制 + IPA 安装"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 状态卡片 ----
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        ipAddressLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        ipAddressLabel.textColor = .systemBlue
        installStatusLabel.font = UIFont.systemFont(ofSize: 13)
        installStatusLabel.numberOfLines = 2

        let statusStack = UIStackView(arrangedSubviews: [ipAddressLabel, installStatusLabel])
        statusStack.axis = .vertical
        statusStack.spacing = 6
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusStack)

        // ---- 任务控制按钮 ----
        let taskLabel = makeSectionLabel("任务控制")

        setupButton(startBtn, title: "启动脚本", color: .systemGreen,  action: #selector(sendStart))
        setupButton(stopBtn,  title: "停止脚本", color: .systemRed,    action: #selector(sendStop))
        setupButton(pauseBtn, title: "暂停脚本", color: .systemOrange, action: #selector(sendPause))
        setupButton(resumeBtn,title: "恢复脚本", color: .systemBlue,   action: #selector(sendResume))

        let taskRow1 = makeButtonRow([startBtn, stopBtn])
        let taskRow2 = makeButtonRow([pauseBtn, resumeBtn])

        // ---- 悬浮窗按钮 ----
        let floatLabel = makeSectionLabel("悬浮窗控制")
        setupButton(hideFloatBtn, title: "隐藏悬浮", color: .systemGray, action: #selector(sendHideFloat))
        setupButton(showFloatBtn, title: "显示悬浮", color: .systemBlue, action: #selector(sendShowFloat))
        let floatRow = makeButtonRow([hideFloatBtn, showFloatBtn])

        // ---- 下载应用按钮 ----
        let downloadLabel = makeSectionLabel("下载最新应用脚本")
        setupButton(downloadBtn, title: "下载最新应用脚本", color: .systemIndigo, action: #selector(startDownloadApp))

        progressLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .secondaryLabel
        progressLabel.numberOfLines = 2
        progressLabel.textAlignment = .center
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 日志显示框 ----
        let logLabel = makeSectionLabel("运行日志")

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.backgroundColor = UIColor.secondarySystemGroupedBackground
        logTextView.layer.cornerRadius = 8
        logTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        logTextView.translatesAutoresizingMaskIntoConstraints = false

        // ---- 滚动视图 ----
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
        contentView.addSubview(downloadLabel)
        contentView.addSubview(downloadBtn)
        contentView.addSubview(progressLabel)
        contentView.addSubview(logLabel)
        contentView.addSubview(logTextView)

        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        // 日志框最小高度
        let logHeight = logTextView.heightAnchor.constraint(equalToConstant: 160)
        logHeight.priority = .defaultHigh

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

            // 标题
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // 状态卡片
            statusCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            statusCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14),

            // 任务控制
            taskLabel.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 20),
            taskLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            taskRow1.topAnchor.constraint(equalTo: taskLabel.bottomAnchor, constant: 8),
            taskRow1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            taskRow2.topAnchor.constraint(equalTo: taskRow1.bottomAnchor, constant: 10),
            taskRow2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 悬浮窗
            floatLabel.topAnchor.constraint(equalTo: taskRow2.bottomAnchor, constant: 18),
            floatLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            floatRow.topAnchor.constraint(equalTo: floatLabel.bottomAnchor, constant: 8),
            floatRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            floatRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 下载应用
            downloadLabel.topAnchor.constraint(equalTo: floatRow.bottomAnchor, constant: 20),
            downloadLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            downloadBtn.topAnchor.constraint(equalTo: downloadLabel.bottomAnchor, constant: 8),
            downloadBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            downloadBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressLabel.topAnchor.constraint(equalTo: downloadBtn.bottomAnchor, constant: 6),
            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 日志
            logLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 18),
            logLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            logTextView.topAnchor.constraint(equalTo: logLabel.bottomAnchor, constant: 8),
            logTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            logHeight,
            logTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30),
        ])
    }

    // ============================================================
    // MARK: - 帮助方法
    // ============================================================

    private func makeSectionLabel(_ text: String) -> UILabel {
        let l = UILabel(); l.text = text; l.font = UIFont.boldSystemFont(ofSize: 13)
        l.textColor = .secondaryLabel; l.translatesAutoresizingMaskIntoConstraints = false; return l
    }

    private func setupButton(_ btn: UIButton, title: String, color: UIColor, action: Selector) {
        btn.setTitle(title, for: .normal); btn.backgroundColor = color
        btn.setTitleColor(.white, for: .normal); btn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        btn.layer.cornerRadius = 10; btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 48).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
    }

    private func makeButtonRow(_ btns: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: btns); row.axis = .horizontal
        row.spacing = 12; row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false; return row
    }

    // ============================================================
    // MARK: - 定时刷新
    // ============================================================

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let iStatus = self.serverRunner.installAPI?.getStatus()
            let iRunning = iStatus?.running ?? false
            let helper = iStatus?.helper ?? "none"
            let icon = iRunning ? "●" : "○"

            DispatchQueue.main.async {
                let attr = NSMutableAttributedString()
                attr.append(NSAttributedString(
                    string: "\(icon) IPA安装API :\(iStatus?.port ?? 8081)  helper: \(helper)",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 13),
                        .foregroundColor: iRunning ? UIColor.systemGreen : UIColor.systemRed
                    ]
                ))
                self.installStatusLabel.attributedText = attr

                if let ip = self.getWiFiIP() {
                    self.ipAddressLabel.text = "\u{1F4F6} \(ip)"
                } else {
                    self.ipAddressLabel.text = "\u{26A0}\u{FE0F} 未连接 WiFi"
                }
            }
        }
    }

    // ============================================================
    // MARK: - 脚本控制按钮
    // ============================================================

    private func sendScriptCommand(_ cmd: String, chineseName: String) {
        let path: String
        switch cmd {
        case "start":  path = "/task?cmd=start";  break
        case "stop":   path = "/task?cmd=stop";   break
        case "pause":  path = "/task?cmd=pause";  break
        case "resume": path = "/task?cmd=resume"; break
        default:       return
        }

        appLog("发送: \(chineseName) → 8989 → :8899", level: .info)

        guard let url = URL(string: "http://127.0.0.1:8989\(path)") else {
            appLog("✗ 内部错误: URL 无效", level: .error)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                self?.appLog("✗ \(chineseName) 失败: \(error.localizedDescription)", level: .error)
                return
            }
            if let httpResp = resp as? HTTPURLResponse {
                let ok = (200...299).contains(httpResp.statusCode)
                if !ok {
                    self?.appLog("✗ \(chineseName) HTTP \(httpResp.statusCode)（脚本APP可能未运行）", level: .error)
                } else {
                    self?.appLog("✓ \(chineseName) 成功（HTTP \(httpResp.statusCode)）", level: .success)
                }
            }
        }.resume()
    }

    private func sendFloatCommand(_ x: String, _ y: String, chineseName: String) {
        let path = "/float?x=\(x)&y=\(y)"
        appLog("发送: \(chineseName) → 8989 → :8899", level: .info)

        guard let url = URL(string: "http://127.0.0.1:8989\(path)") else {
            appLog("✗ 内部错误: URL 无效", level: .error)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                self?.appLog("✗ \(chineseName) 失败: \(error.localizedDescription)", level: .error)
                return
            }
            if let httpResp = resp as? HTTPURLResponse {
                let ok = (200...299).contains(httpResp.statusCode)
                if !ok {
                    self?.appLog("✗ \(chineseName) HTTP \(httpResp.statusCode)（脚本APP可能未运行）", level: .error)
                } else {
                    self?.appLog("✓ \(chineseName) 成功（HTTP \(httpResp.statusCode)）", level: .success)
                }
            }
        }.resume()
    }

    @objc private func sendStart()     { sendScriptCommand("start",  chineseName: "启动脚本") }
    @objc private func sendStop()      { sendScriptCommand("stop",   chineseName: "停止脚本") }
    @objc private func sendPause()     { sendScriptCommand("pause",  chineseName: "暂停脚本") }
    @objc private func sendResume()    { sendScriptCommand("resume", chineseName: "恢复脚本") }
    @objc private func sendHideFloat() { sendFloatCommand("0", "-100", chineseName: "隐藏悬浮窗") }
    @objc private func sendShowFloat() { sendFloatCommand("1", "100",  chineseName: "显示悬浮窗") }

    // ============================================================
    // MARK: - 下载 + 安装最新应用脚本
    // ============================================================

    @objc private func startDownloadApp() {
        downloadBtn.isEnabled = false
        downloadBtn.setTitle("准备下载...", for: .normal)
        progressLabel.text = ""

        appLog("═══ 开始下载最新应用脚本 ═══", level: .info)
        appLog("尝试主地址: \(primaryURL)", level: .info)

        tryDownload(primaryURL, isPrimary: true)
    }

    private func tryDownload(_ urlStr: String, isPrimary: Bool) {
        guard let url = URL(string: urlStr) else {
            appLog("✗ URL 无效", level: .error)
            resetDownloadBtn()
            return
        }

        // 使用 delegate-based session 获取进度
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let delegate = DownloadDelegate(urlStr: urlStr, isPrimary: isPrimary, parent: self)
        activeDownloadDelegate = delegate // 保持强引用
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let task = session.downloadTask(with: url)
        task.resume()
    }

    /// 下载完成后处理 IPA 文件
    fileprivate func onDownloadComplete(localURL: URL, fileName: String, urlStr: String, isPrimary: Bool) {
        let destDir = "/var/mobile/Documents"
        let destPath = "\(destDir)/\(fileName)"

        // 确保目录存在
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destPath) {
            try? FileManager.default.removeItem(atPath: destPath)
        }

        do {
            try FileManager.default.moveItem(atPath: localURL.path, toPath: destPath)
        } catch {
            appLog("✗ 文件保存失败: \(error.localizedDescription)", level: .error)
            resetDownloadBtn()
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int64) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        appLog("✓ 下载完成: \(sizeStr)", level: .success)
        progressLabel.text = "下载完成: \(sizeStr)"

        // 开始安装
        appLog("正在安装最新程序...", level: .progress)
        progressLabel.text = "正在安装..."

        self.serverRunner.installAPI?.installFromLocalPath(destPath) { [weak self] success, message in
            guard let self = self else { return }

            if success {
                self.appLog("✓ 安装完成: \(message)", level: .success)
                self.progressLabel.text = "✅ 安装完成"
            } else {
                self.appLog("✗ 安装失败: \(message)", level: .error)
                self.progressLabel.text = "❌ 安装失败: \(message)"
            }
            self.resetDownloadBtn()
        }
    }

    /// 主地址失败时尝试备用地址
    fileprivate func onDownloadFailed(_ error: Error, urlStr: String, isPrimary: Bool) {
        if isPrimary {
            appLog("✗ 主地址下载失败: \(error.localizedDescription)", level: .error)
            appLog("尝试备用地址: \(fallbackURL)", level: .info)
            progressLabel.text = "主地址失败，尝试备用地址..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryDownload(self!.fallbackURL, isPrimary: false)
            }
        } else {
            appLog("✗ 备用地址也失败: \(error.localizedDescription)", level: .error)
            appLog("✗ 所有下载地址均不可用，请检查网络", level: .error)
            progressLabel.text = "❌ 下载失败，所有地址均不可用"
            resetDownloadBtn()
        }
    }

    /// 报告下载进度
    fileprivate func onDownloadProgress(percent: Int, downloaded: Int64, total: Int64, isPrimary: Bool) {
        let prefix = isPrimary ? "主地址" : "备用地址"
        let dStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        let tStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        progressLabel.text = "[\(prefix)] 下载中 \(percent)% (\(dStr) / \(tStr))"
    }

    private func resetDownloadBtn() {
        downloadBtn.isEnabled = true
        downloadBtn.setTitle("下载最新应用脚本", for: .normal)
    }

    // ============================================================
    // MARK: - WiFi IP
    // ============================================================

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
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr!.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    return String(cString: host)
                }
            }
            ptr = ptr!.pointee.ifa_next
        }
        return nil
    }
}

// ============================================================
// MARK: - URLSession 下载代理（支持进度回调）
// ============================================================

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    let urlStr: String
    let isPrimary: Bool
    weak var parent: ViewController?

    init(urlStr: String, isPrimary: Bool, parent: ViewController) {
        self.urlStr = urlStr
        self.isPrimary = isPrimary
        self.parent = parent
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        DispatchQueue.main.async {
            self.parent?.onDownloadProgress(percent: pct, downloaded: totalBytesWritten,
                                            total: totalBytesExpectedToWrite, isPrimary: self.isPrimary)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fileName = URL(string: urlStr)?.lastPathComponent ?? "app-release.ipa"
        parent?.onDownloadComplete(localURL: location, fileName: fileName,
                                   urlStr: urlStr, isPrimary: isPrimary)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            // 判断是否是真正的错误（不是正常的完成）
            let nsErr = error as NSError
            if nsErr.code != NSURLErrorCancelled {
                parent?.onDownloadFailed(error, urlStr: urlStr, isPrimary: isPrimary)
            }
            session.invalidateAndCancel()
        }
    }
}

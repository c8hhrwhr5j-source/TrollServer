import UIKit

// ============================================================
//  主界面控制器
//  功能：脚本控制按钮 | 下载安装最新脚本 | 实时日志
// ============================================================

// 日志缓冲区（支持 AccessoryKit 样式）
private let sharedLogBuffer = NSMutableAttributedString()
/// 串行写队列，防止多线程竞争崩溃
private let logWriteQueue = DispatchQueue(label: "com.wuyoufz.log", qos: .userInitiated)
/// 时间格式化器复用，避免每次 appLog 都新建
private let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
private var logUpdateHandler: (() -> Void)?

class ViewController: UIViewController {

    private let serverRunner: DaemonServerRunner

    // 状态
    private let ipAddressLabel = UILabel()
    private let modelLabel = UILabel()
    private let memoryLabel = UILabel()
    private let serialLabel = UILabel()
    private let sysVersionLabel = UILabel()

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
    private let installAppBtn = UIButton(type: .system)
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

    private enum LogLevel { case info, success, error, progress, warn }

    private func appLog(_ msg: String, level: LogLevel = .info) {
        let ts = logFmt.string(from: Date())

        let color: UIColor
        switch level {
        case .info:     color = UIColor.label
        case .success:  color = UIColor.systemGreen
        case .error:    color = UIColor.systemRed
        case .progress: color = UIColor.systemOrange
        case .warn:     color = UIColor.systemYellow
        }

        logWriteQueue.async {
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
    }

    // ============================================================
    // MARK: - UI 布局
    // ============================================================

    private func setupUI() {
        view.backgroundColor = UIColor.systemGroupedBackground

        let titleLabel = UILabel()
        titleLabel.text = "无忧辅助控制"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 状态卡片 ----
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        // 设备信息标签样式
        func makeStatusLabel() -> UILabel {
            let l = UILabel()
            l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
            l.textColor = .label
            l.numberOfLines = 1
            return l
        }
        modelLabel = makeStatusLabel()
        memoryLabel = makeStatusLabel()
        serialLabel = makeStatusLabel()
        ipAddressLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        ipAddressLabel.textColor = .systemBlue
        ipAddressLabel.numberOfLines = 1
        sysVersionLabel = makeStatusLabel()

        let statusStack = UIStackView(arrangedSubviews: [modelLabel, memoryLabel, serialLabel, ipAddressLabel, sysVersionLabel])
        statusStack.axis = .vertical
        statusStack.spacing = 4
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
        setupButton(downloadBtn, title: "下载应用", color: .systemRed, action: #selector(confirmDownloadLatestAppScript))
        setupButton(installAppBtn, title: "安装应用", color: .systemBlue, action: #selector(installAppTapped))

        let downloadRow = makeButtonRow([downloadBtn, installAppBtn])

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
        contentView.addSubview(statusCard)
        contentView.addSubview(taskLabel)
        contentView.addSubview(taskRow1)
        contentView.addSubview(taskRow2)
        contentView.addSubview(floatLabel)
        contentView.addSubview(floatRow)
        contentView.addSubview(downloadLabel)
        contentView.addSubview(downloadRow)
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

            // 状态卡片
            statusCard.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
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
            downloadRow.topAnchor.constraint(equalTo: downloadLabel.bottomAnchor, constant: 8),
            downloadRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            downloadRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressLabel.topAnchor.constraint(equalTo: downloadRow.bottomAnchor, constant: 6),
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
        btn.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(buttonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func buttonTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseOut, animations: {
            sender.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
            sender.alpha = 0.85
        })
    }

    @objc private func buttonTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseInOut, animations: {
            sender.transform = .identity
            sender.alpha = 1.0
        })
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
            let model = self.getDeviceModel()
            let memory = self.getDeviceMemory()
            let serial = self.getDeviceSerial()
            let sysVer = UIDevice.current.systemVersion
            let ip = self.getWiFiIP() ?? "未连接"

            DispatchQueue.main.async {
                self.modelLabel.text     = "📱 机型: \(model)"
                self.memoryLabel.text    = "💾 内存: \(memory)"
                self.serialLabel.text    = "🔑 序列号: \(serial)"
                self.ipAddressLabel.text = "📶 IP: \(ip)"
                self.sysVersionLabel.text = "⚙️ 系统: iOS \(sysVer)"
            }
        }
    }

    private func getDeviceModel() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func getDeviceMemory() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
        }
    }

    private func getDeviceSerial() -> String {
        // 尝试通过 MobileGestalt 获取序列号
        typealias MGCopyAnswerFunc = @convention(c) (CFString) -> Unmanaged<CFString>?
        if let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "MGCopyAnswer") {
                let f = unsafeBitCast(sym, to: MGCopyAnswerFunc.self)
                if let result = f("SerialNumber" as CFString)?.takeRetainedValue() as String? {
                    return result
                }
            }
        }
        return "不可用"
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

        appLog("发送: \(chineseName) → 脚本控制服务", level: .info)

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
        appLog("发送: \(chineseName) → 脚本控制服务", level: .info)

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

    @objc private func confirmDownloadLatestAppScript() {
        let alert = UIAlertController(
            title: "确认下载",
            message: "是否下载并安装最新版脚本程序？此操作会强制关闭并覆盖当前应用。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            self?.startDownloadApp()
        })
        present(alert, animated: true)
    }

    @objc private func startDownloadApp() {
        downloadBtn.isEnabled = false
        downloadBtn.setTitle("正在下载中...", for: .normal)
        progressLabel.text = ""

        appLog("═══ 开始下载最新应用脚本 ═══", level: .info)
        appLog("尝试主地址下载...", level: .info)

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

        // 弹出分享面板，让用户手动选择应用安装 IPA
        appLog("下载完成，请选择应用打开 IPA 安装包", level: .info)
        progressLabel.text = "请选择巨魔或其他应用进行安装"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let fileURL = URL(fileURLWithPath: destPath)
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)

            // iPad 上需要设置 sourceView 避免崩溃
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            }

            activityVC.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                guard let self = self else { return }
                if completed {
                    self.appLog("✓ 已通过外部应用打开 IPA", level: .success)
                } else {
                    self.appLog("⚠ 已取消分享", level: .warn)
                }
                self.resetDownloadBtn()
            }

            self.present(activityVC, animated: true)
        }
    }

    /// 主地址失败时尝试备用地址
    fileprivate func onDownloadFailed(_ error: Error, urlStr: String, isPrimary: Bool) {
        if isPrimary {
            appLog("✗ 主地址下载失败: \(error.localizedDescription)", level: .error)
            appLog("尝试备用地址下载...", level: .info)
            progressLabel.text = "主地址失败，尝试备用地址..."
            let fallback = self.fallbackURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.tryDownload(fallback, isPrimary: false)
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
        downloadBtn.setTitle("下载应用", for: .normal)
    }

    // ============================================================
    // MARK: - 安装已下载的应用
    // ============================================================

    @objc private func installAppTapped() {
        let targetPath = "/var/mobile/Documents/app-release.ipa"

        guard FileManager.default.fileExists(atPath: targetPath) else {
            let alert = UIAlertController(
                title: "提示",
                message: "您还没有下载应用，请先下载",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }

        // 直接弹出分享面板安装
        let fileURL = URL(fileURLWithPath: targetPath)
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
        }

        activityVC.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            guard let self = self else { return }
            if completed {
                self.appLog("✓ 已通过外部应用打开 IPA", level: .success)
            } else {
                self.appLog("⚠ 已取消分享", level: .warn)
            }
        }

        present(activityVC, animated: true)
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

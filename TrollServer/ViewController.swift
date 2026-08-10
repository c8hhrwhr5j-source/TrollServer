import UIKit
import Darwin

@_silgen_name("waitpid") func waitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>!, _ options: Int32) -> pid_t

// POSIX wait 状态宏
private func WIFEXITED(_ status: Int32) -> Bool { return (status & 0x7f) == 0 }
private func WEXITSTATUS(_ status: Int32) -> Int32 { return (status >> 8) & 0xff }

// persona-mgmt 私有 API — 用于以 root 身份 spawn 子进程
@_silgen_name("posix_spawnattr_init") func posix_spawnattr_init(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32
@_silgen_name("posix_spawnattr_destroy") func posix_spawnattr_destroy(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32
@_silgen_name("posix_spawnattr_set_persona_np") func posix_spawnattr_set_persona_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona_id: UInt32, _ flags: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np") func posix_spawnattr_set_persona_uid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ uid: uid_t) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np") func posix_spawnattr_set_persona_gid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ gid: gid_t) -> Int32

private let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1
private let POSIX_SPAWN_PERSONA_ID_ROOT: UInt32 = 99

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
    private var statusRows: [(key: UILabel, value: UILabel)] = []

    private var refreshTimer: Timer?

    // 脚本控制按钮
    private let startBtn = UIButton(type: .system)
    private let stopBtn  = UIButton(type: .system)
    private let pauseBtn = UIButton(type: .system)
    private let resumeBtn = UIButton(type: .system)
    private let hideFloatBtn = UIButton(type: .system)
    private let showFloatBtn = UIButton(type: .system)

    // 重启/注销
    private let rebootBtn   = UIButton(type: .system)
    private let respringBtn = UIButton(type: .system)

    // 下载安装
    private let downloadBtn = UIButton(type: .system)
    private let installAppBtn = UIButton(type: .system)
    private let progressLabel = UILabel()

    // 日志区域
    private let logTextView = UITextView()

    // 临时存储
    private var downloadedIPAPath: String?
    private var activeDownloadDelegate: DownloadDelegate? // 持有 delegate 防止被释放
    private var downloadSession: URLSession?             // 持有 session 防止被提前释放

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
        UIApplication.shared.isIdleTimerDisabled = true // 屏幕常亮，防止自动锁屏
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
        UIApplication.shared.isIdleTimerDisabled = false // 离开页面时恢复默认
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

        // ---- 设备信息标签（在白框外面） ----
        let deviceInfoLabel = makeSectionLabel("设备信息")

        // ---- 状态卡片 ----
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        let keys = ["机型", "CPU", "系统版本", "硬盘", "序列号", "IP地址"]
        statusRows.removeAll()
        var rowContainers: [UIView] = []

        for (idx, key) in keys.enumerated() {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let kLabel = UILabel()
            kLabel.text = key
            kLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            kLabel.textColor = .label
            kLabel.translatesAutoresizingMaskIntoConstraints = false

            let vLabel = UILabel()
            vLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            vLabel.textColor = .secondaryLabel
            vLabel.textAlignment = .right
            vLabel.numberOfLines = 1
            vLabel.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(kLabel)
            container.addSubview(vLabel)

            NSLayoutConstraint.activate([
                kLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                kLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                vLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                vLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                vLabel.leadingAnchor.constraint(greaterThanOrEqualTo: kLabel.trailingAnchor, constant: 12),
                container.heightAnchor.constraint(equalToConstant: 28)
            ])

            // 分隔线（最后一行不加）
            if idx < keys.count - 1 {
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 0.5)
                ])
            }

            rowContainers.append(container)
            statusRows.append((key: kLabel, value: vLabel))
        }

        let statusStack = UIStackView(arrangedSubviews: rowContainers)
        statusStack.axis = .vertical
        statusStack.spacing = 0
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusStack)

        // ---- 任务控制按钮 ----
        let taskLabel = makeSectionLabel("脚本控制")

        setupButton(startBtn, title: "启动脚本", color: .systemGreen,  action: #selector(sendStart))
        setupButton(stopBtn,  title: "停止脚本", color: .systemRed,    action: #selector(sendStop))
        setupButton(pauseBtn, title: "暂停脚本", color: .systemOrange, action: #selector(sendPause))
        setupButton(resumeBtn,title: "恢复脚本", color: .systemBlue,   action: #selector(sendResume))

        let taskRow1 = makeButtonRow([startBtn, stopBtn])
        let taskRow2 = makeButtonRow([pauseBtn, resumeBtn])

        // ---- 悬浮窗按钮 ----
        let floatLabel = makeSectionLabel("悬浮球控制")
        setupButton(hideFloatBtn, title: "隐藏悬浮", color: .systemGray, action: #selector(sendHideFloat))
        setupButton(showFloatBtn, title: "显示悬浮", color: .systemBlue, action: #selector(sendShowFloat))
        let floatRow = makeButtonRow([hideFloatBtn, showFloatBtn])

        // ---- 重启 / 注销 ----
        let systemLabel = makeSectionLabel("设备电源控制")
        setupButton(rebootBtn,   title: "重启设备", color: UIColor(red: 0.9, green: 0.45, blue: 0.0, alpha: 1.0), action: #selector(rebootTapped))
        setupButton(respringBtn, title: "注销",     color: UIColor(red: 0.3, green: 0.3, blue: 0.8, alpha: 1.0), action: #selector(respringTapped))
        let systemRow = makeButtonRow([rebootBtn, respringBtn])

        // ---- 下载应用按钮 ----
        let downloadLabel = makeSectionLabel("下载安装最新应用脚本")
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
        contentView.addSubview(deviceInfoLabel)
        contentView.addSubview(statusCard)
        contentView.addSubview(taskLabel)
        contentView.addSubview(taskRow1)
        contentView.addSubview(taskRow2)
        contentView.addSubview(floatLabel)
        contentView.addSubview(floatRow)
        contentView.addSubview(systemLabel)
        contentView.addSubview(systemRow)
        contentView.addSubview(downloadLabel)
        contentView.addSubview(downloadRow)
        contentView.addSubview(progressLabel)
        contentView.addSubview(logLabel)
        contentView.addSubview(logTextView)

        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        // 日志框最小高度
        let logHeight = logTextView.heightAnchor.constraint(equalToConstant: 120)
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
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // 脚本控制
            taskLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            taskLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            taskRow1.topAnchor.constraint(equalTo: taskLabel.bottomAnchor, constant: 6),
            taskRow1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            taskRow2.topAnchor.constraint(equalTo: taskRow1.bottomAnchor, constant: 8),
            taskRow2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            taskRow2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 悬浮球
            floatLabel.topAnchor.constraint(equalTo: taskRow2.bottomAnchor, constant: 14),
            floatLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            floatRow.topAnchor.constraint(equalTo: floatLabel.bottomAnchor, constant: 6),
            floatRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            floatRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 下载安装
            downloadLabel.topAnchor.constraint(equalTo: floatRow.bottomAnchor, constant: 14),
            downloadLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            downloadRow.topAnchor.constraint(equalTo: downloadLabel.bottomAnchor, constant: 6),
            downloadRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            downloadRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressLabel.topAnchor.constraint(equalTo: downloadRow.bottomAnchor, constant: 4),
            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 设备电源控制（重启/关机/注销）
            systemLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 14),
            systemLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            systemRow.topAnchor.constraint(equalTo: systemLabel.bottomAnchor, constant: 6),
            systemRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            systemRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 设备信息
            deviceInfoLabel.topAnchor.constraint(equalTo: systemRow.bottomAnchor, constant: 14),
            deviceInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            statusCard.topAnchor.constraint(equalTo: deviceInfoLabel.bottomAnchor, constant: 6),
            statusCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 10),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -10),

            // 日志
            logLabel.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 14),
            logLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            logTextView.topAnchor.constraint(equalTo: logLabel.bottomAnchor, constant: 6),
            logTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            logHeight,
            logTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
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
            let cpu = self.getDeviceCPU()
            let sysVer = UIDevice.current.systemVersion
            let storage = self.getDeviceStorage()
            let serial = self.getDeviceSerial()
            let ip = self.getWiFiIP() ?? "未连接"

            DispatchQueue.main.async {
                guard self.statusRows.count >= 6 else { return }
                self.statusRows[0].value.text = model
                self.statusRows[1].value.text = cpu
                self.statusRows[2].value.text = sysVer
                self.statusRows[3].value.text = storage
                self.statusRows[4].value.text = serial
                self.statusRows[5].value.text = ip
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
        return modelName(for: machine)
    }

    /// 将内部标识符映射为可读的设备名称
    private func modelName(for identifier: String) -> String {
        let map: [String: String] = [
            // iPhone
            "iPhone1,1": "iPhone",          "iPhone1,2": "iPhone 3G",
            "iPhone2,1": "iPhone 3GS",      "iPhone3,1": "iPhone 4 (GSM)",
            "iPhone3,2": "iPhone 4 (GSM)",  "iPhone3,3": "iPhone 4 (CDMA)",
            "iPhone4,1": "iPhone 4s",       "iPhone5,1": "iPhone 5 (GSM)",
            "iPhone5,2": "iPhone 5",        "iPhone5,3": "iPhone 5c (GSM)",
            "iPhone5,4": "iPhone 5c",       "iPhone6,1": "iPhone 5s (GSM)",
            "iPhone6,2": "iPhone 5s",       "iPhone7,1": "iPhone 6 Plus",
            "iPhone7,2": "iPhone 6",        "iPhone8,1": "iPhone 6s",
            "iPhone8,2": "iPhone 6s Plus",  "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7",        "iPhone9,3": "iPhone 7",
            "iPhone9,2": "iPhone 7 Plus",   "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8",       "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus",  "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X",       "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS",      "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max",  "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11",      "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",  "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",  "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd)",
            "iPhone14,7": "iPhone 14",      "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",  "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",      "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",  "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",  "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",      "iPhone17,4": "iPhone 16 Plus",
            // iPad
            "iPad1,1": "iPad",              "iPad2,1": "iPad 2 (WiFi)",
            "iPad2,2": "iPad 2 (GSM)",      "iPad2,3": "iPad 2 (CDMA)",
            "iPad2,4": "iPad 2",            "iPad3,1": "iPad 3 (WiFi)",
            "iPad3,2": "iPad 3",            "iPad3,3": "iPad 3",
            "iPad3,4": "iPad 4 (WiFi)",     "iPad3,5": "iPad 4 (GSM)",
            "iPad3,6": "iPad 4",            "iPad4,1": "iPad Air (WiFi)",
            "iPad4,2": "iPad Air",          "iPad4,3": "iPad Air",
            "iPad5,3": "iPad Air 2 (WiFi)", "iPad5,4": "iPad Air 2",
            "iPad6,11": "iPad 5 (WiFi)",    "iPad6,12": "iPad 5",
            "iPad7,5": "iPad 6 (WiFi)",     "iPad7,6": "iPad 6",
            "iPad7,11": "iPad 7 (WiFi)",    "iPad7,12": "iPad 7",
            "iPad11,6": "iPad 8 (WiFi)",   "iPad11,7": "iPad 8",
            "iPad12,1": "iPad 9 (WiFi)",   "iPad12,2": "iPad 9",
            "iPad13,18": "iPad 10",        "iPad13,19": "iPad 10",
            // iPad Pro
            "iPad6,3": "iPad Pro 9.7",     "iPad6,4": "iPad Pro 9.7",
            "iPad6,7": "iPad Pro 12.9",    "iPad6,8": "iPad Pro 12.9",
            "iPad7,1": "iPad Pro 12.9 (2nd)", "iPad7,2": "iPad Pro 12.9 (2nd)",
            "iPad7,3": "iPad Pro 10.5",    "iPad7,4": "iPad Pro 10.5",
            "iPad8,1": "iPad Pro 11 (1st)","iPad8,2": "iPad Pro 11 (1st)",
            "iPad8,3": "iPad Pro 11 (1st)","iPad8,4": "iPad Pro 11 (1st)",
            "iPad8,5": "iPad Pro 12.9 (3rd)","iPad8,6": "iPad Pro 12.9 (3rd)",
            "iPad8,7": "iPad Pro 12.9 (3rd)","iPad8,8": "iPad Pro 12.9 (3rd)",
            "iPad8,9": "iPad Pro 11 (2nd)","iPad8,10": "iPad Pro 11 (2nd)",
            "iPad8,11": "iPad Pro 12.9 (4th)","iPad8,12": "iPad Pro 12.9 (4th)",
            "iPad13,4": "iPad Pro 11 (3rd)","iPad13,5": "iPad Pro 11 (3rd)",
            "iPad13,6": "iPad Pro 11 (3rd)","iPad13,7": "iPad Pro 11 (3rd)",
            "iPad13,8": "iPad Pro 12.9 (5th)","iPad13,9": "iPad Pro 12.9 (5th)",
            "iPad13,10": "iPad Pro 12.9 (5th)","iPad13,11": "iPad Pro 12.9 (5th)",
            "iPad14,3": "iPad Pro 11 (4th)","iPad14,4": "iPad Pro 11 (4th)",
            "iPad14,5": "iPad Pro 12.9 (6th)","iPad14,6": "iPad Pro 12.9 (6th)",
            "iPad16,3": "iPad Pro 11 (5th)","iPad16,4": "iPad Pro 11 (5th)",
            "iPad16,5": "iPad Pro 12.9 (7th)","iPad16,6": "iPad Pro 12.9 (7th)",
            // iPad mini
            "iPad2,5": "iPad mini (WiFi)",  "iPad2,6": "iPad mini",
            "iPad2,7": "iPad mini",         "iPad4,4": "iPad mini 2 (WiFi)",
            "iPad4,5": "iPad mini 2",       "iPad4,6": "iPad mini 2",
            "iPad4,7": "iPad mini 3 (WiFi)","iPad4,8": "iPad mini 3",
            "iPad4,9": "iPad mini 3",       "iPad5,1": "iPad mini 4 (WiFi)",
            "iPad5,2": "iPad mini 4",       "iPad11,1": "iPad mini 5 (WiFi)",
            "iPad11,2": "iPad mini 5",      "iPad14,1": "iPad mini 6 (WiFi)",
            "iPad14,2": "iPad mini 6",
            // iPad Air
            "iPad11,3": "iPad Air 3 (WiFi)","iPad11,4": "iPad Air 3",
            "iPad13,1": "iPad Air 4 (WiFi)","iPad13,2": "iPad Air 4",
            "iPad13,16": "iPad Air 5 (WiFi)","iPad13,17": "iPad Air 5",
            "iPad14,8": "iPad Air 11 M2",  "iPad14,9": "iPad Air 11 M2",
            "iPad14,10": "iPad Air 13 M2", "iPad14,11": "iPad Air 13 M2",
            // iPod
            "iPod1,1": "iPod touch",        "iPod2,1": "iPod touch 2",
            "iPod3,1": "iPod touch 3",      "iPod4,1": "iPod touch 4",
            "iPod5,1": "iPod touch 5",      "iPod7,1": "iPod touch 6",
            "iPod9,1": "iPod touch 7",
            // Apple Silicon Mac
            "MacFamily20,1": "Mac (M1)",
            "arm64": "Apple Silicon"
        ]
        return map[identifier] ?? identifier
    }

    /// 获取设备总存储容量
    private func getDeviceStorage() -> String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) else {
            return "未知"
        }
        if let total = attrs[.systemSize] as? Int64 {
            let gb = Double(total) / 1_000_000_000.0
            if gb >= 1000 {
                return String(format: "%.2f TB", gb / 1000.0)
            } else if gb >= 1 {
                return String(format: "%.0f GB", gb)
            } else {
                return String(format: "%.0f MB", gb * 1000)
            }
        }
        return "未知"
    }

    /// 获取设备 CPU 信息
    private func getDeviceCPU() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        // 获取处理器核心数
        let cores = ProcessInfo.processInfo.processorCount
        _ = ProcessInfo.processInfo.activeProcessorCount
        // 获取架构
        let arch = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        // 解析 SoC 名称
        let soc = socName(for: arch)
        return "\(soc) (\(cores)核)"
    }

    private func socName(for identifier: String) -> String {
        let map: [String: String] = [
            "iPhone8,1": "A9",           "iPhone8,2": "A9",
            "iPhone8,4": "A9",           "iPhone9,1": "A10 Fusion",
            "iPhone9,2": "A10 Fusion",   "iPhone9,3": "A10 Fusion",
            "iPhone9,4": "A10 Fusion",   "iPhone10,1": "A11 Bionic",
            "iPhone10,2": "A11 Bionic",  "iPhone10,3": "A11 Bionic",
            "iPhone10,4": "A11 Bionic",  "iPhone10,5": "A11 Bionic",
            "iPhone10,6": "A11 Bionic",  "iPhone11,2": "A12 Bionic",
            "iPhone11,4": "A12 Bionic",  "iPhone11,6": "A12 Bionic",
            "iPhone11,8": "A12 Bionic",  "iPhone12,1": "A13 Bionic",
            "iPhone12,3": "A13 Bionic",  "iPhone12,5": "A13 Bionic",
            "iPhone13,1": "A14 Bionic",  "iPhone13,2": "A14 Bionic",
            "iPhone13,3": "A14 Bionic",  "iPhone13,4": "A14 Bionic",
            "iPhone14,2": "A15 Bionic",  "iPhone14,3": "A15 Bionic",
            "iPhone14,4": "A15 Bionic",  "iPhone14,5": "A15 Bionic",
            "iPhone14,6": "A15 Bionic",  "iPhone14,7": "A15 Bionic",
            "iPhone14,8": "A15 Bionic",  "iPhone15,2": "A16 Bionic",
            "iPhone15,3": "A16 Bionic",  "iPhone15,4": "A16 Bionic",
            "iPhone15,5": "A16 Bionic",  "iPhone16,1": "A17 Pro",
            "iPhone16,2": "A17 Pro",     "iPhone17,1": "A18 Pro",
            "iPhone17,2": "A18 Pro",     "iPhone17,3": "A18",
            "iPhone17,4": "A18",
        ]
        return map[identifier] ?? identifier
    }

    private func getDeviceSerial() -> String {
        typealias MGCopyAnswerFunc = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        // RTLD_DEFAULT = ((void *) -2)，Swift 中无法直接使用该宏，传入 UnsafeMutableRawPointer(bitPattern: 0xFFFFFFFFFFFFFFFE) 等效
        let handle = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: -2))
        if let sym = dlsym(handle, "MGCopyAnswer") {
            let f = unsafeBitCast(sym, to: MGCopyAnswerFunc.self)
            if let result = f("SerialNumber" as CFString)?.takeRetainedValue() as? String {
                return result
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
    // MARK: - 重启 / 注销
    // ============================================================

    private func performRebootAction(_ action: String, displayName: String) {
        let alert = UIAlertController(
            title: "确认操作",
            message: "确定要\(displayName)设备吗？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            self?.executeSystemCommand(action: action, displayName: displayName)
        })
        present(alert, animated: true)
    }

    private func executeSystemCommand(action: String, displayName: String) {
        appLog("⏳ 正在执行：\(displayName)...", level: .warn)

        switch action {
        case "reboot":
            rebootDevice()

        case "respring":
            respringDevice()

        default:
            break
        }
    }

    /// 获取 app bundle 中 bin/ 目录下的工具路径
    private func binPath(_ name: String) -> String {
        return Bundle.main.bundlePath + "/bin/" + name
    }

    /// 重启：自产卵（spawn 自身二进制 + --reboot 标志）
    /// 此前尝试过的方案及失败原因见 REBOOT_JOURNAL.md
    private func rebootDevice() {
        // 方案 4（当前）：spawn 主二进制自身，传入 --reboot 标志
        // 优势：子进程天然继承主二进制的 entitlements（含 com.apple.system.reboot），
        //       配合 persona=root，满足 reboot() 的两个必要条件。
        let selfBin = Bundle.main.executablePath ?? ""
        if selfBin.isEmpty {
            appLog("✗ 无法获取自身二进制路径", level: .error)
            return
        }

        let ret = spawnAndWait(path: selfBin, args: [selfBin, "--reboot"])
        if ret == 0 {
            appLog("✓ 重启指令执行成功 — 设备正在重启", level: .success)
        } else if ret == 1 {
            appLog("✗ reboot() 调用失败（返回 1），可能缺少 com.apple.system.reboot 权限", level: .error)
        } else {
            appLog("✗ spawn 失败，posix_spawn 返回: \(ret)", level: .error)
        }
    }

    /// 注销（respring）：先尝试 bundle 内的 launchctl userspace，失败则 killall backboardd
    private func respringDevice() {
        let launchctlBin = binPath("launchctl")
        let killallBin = binPath("killall")

        // 优先使用 launchctl reboot userspace
        let result1 = spawnAndWait(path: launchctlBin, args: ["launchctl", "reboot", "userspace"])
        if result1 == 0 {
            appLog("✓ 注销指令已发送", level: .success)
            return
        }
        appLog("⏳ launchctl 返回 \(result1)，尝试 killall backboardd...", level: .warn)

        // 降级：killall -9 backboardd
        let result2 = spawnAndWait(path: killallBin, args: ["killall", "-9", "backboardd"])
        if result2 == 0 {
            appLog("✓ 注销指令已发送 (backboardd)", level: .success)
        } else {
            appLog("✗ 注销失败，错误码: \(result2)", level: .error)
        }
    }

    /// 以 root 权限 spawn 子进程（需要 com.apple.private.persona-mgmt 权限）
    private func spawnAndWait(path: String, args: [String]) -> Int32 {
        // posix_spawn argv 必须以 NULL 结尾
        let cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }

        // 初始化 spawn 属性，设置 persona 为 root
        var attr: posix_spawnattr_t? = nil
        _ = posix_spawnattr_init(&attr)
        _ = posix_spawnattr_set_persona_np(&attr, POSIX_SPAWN_PERSONA_ID_ROOT, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)
        _ = posix_spawnattr_set_persona_uid_np(&attr, 0)
        _ = posix_spawnattr_set_persona_gid_np(&attr, 0)
        defer { _ = posix_spawnattr_destroy(&attr) }

        var pid: pid_t = 0
        let ret = posix_spawn(&pid, path, nil, &attr, cargs, environ)
        guard ret == 0 else { return ret }
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        // 返回子进程实际退出码
        if WIFEXITED(status) {
            return WEXITSTATUS(status)
        }
        return -1 // 子进程异常终止
    }

    @objc private func rebootTapped()   { performRebootAction("reboot",   displayName: "重启") }
    @objc private func respringTapped() { performRebootAction("respring", displayName: "注销") }

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

        // 取消上一次可能还残留的下载，防止 delegate 回调混乱
        activeDownloadDelegate = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let delegate = DownloadDelegate(urlStr: urlStr, isPrimary: isPrimary, parent: self)
        activeDownloadDelegate = delegate
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        downloadSession = session // 持有引用，防止被系统提前释放

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

            // 防止已经有其他 controller 正在 present 导致崩溃
            if self.presentedViewController != nil {
                self.appLog("⚠ 页面正在显示其他弹窗，请关闭后重试", level: .warn)
                self.progressLabel.text = "请关闭当前弹窗后重新下载"
                self.resetDownloadBtn()
                return
            }

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
        activeDownloadDelegate = nil
        downloadSession = nil
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

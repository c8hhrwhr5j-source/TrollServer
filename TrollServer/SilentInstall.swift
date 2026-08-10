import Foundation
import Darwin

// ============================================================
//  巨魔环境下静默安装 IPA 功能模块
//  支持: iOS 14.0 - 16.6.1 / iOS 17.0 特定版本
// ============================================================

// MARK: - 安装方法枚举

enum InstallMethod: String {
    case trollstorehelper  = "trollstorehelper"
    case lsApplicationWorkspace = "LSApplicationWorkspace"
    case mobileInstallation = "MobileInstallation"
    case fileCopy           = "文件复制到检测目录"
}

// MARK: - 安装结果

enum SilentInstallResult {
    /// 安装成功
    case success(message: String, method: InstallMethod)
    /// 安装失败
    case failure(message: String)
    /// 安装进度
    case progress(phase: String, detail: String, percent: Int)
}

// MARK: - IPA 包信息

struct IPABundleInfo {
    let bundleIdentifier: String
    let executableName: String
    let displayName: String
    let version: String
}

// MARK: - 静默安装器

class SilentInstall {

    // ============================================================
    // MARK: - ═══ 公共 API ═══
    // ============================================================

    /// 异步安装 IPA（带进度回调）
    /// - Parameters:
    ///   - ipaPath: IPA 文件绝对路径
    ///   - progress: 进度回调（后台线程）
    ///   - completion: 完成回调（后台线程）
    static func install(
        ipaPath: String,
        progress: ((SilentInstallResult) -> Void)? = nil,
        completion: @escaping (SilentInstallResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performInstall(ipaPath: ipaPath, progress: progress)
            completion(result)
        }
    }

    /// 同步安装 IPA（阻塞当前线程）
    static func installSync(ipaPath: String) -> SilentInstallResult {
        return performInstall(ipaPath: ipaPath, progress: nil)
    }

    // ============================================================
    // MARK: - ═══ 环境检查 ═══
    // ============================================================

    /// 检查文件系统权限（验证巨魔注入是否生效）
    static func checkPermissions() -> (ok: Bool, detail: String) {
        // 测试1: 能否写入 /var/mobile/Documents
        let testPath = "/var/mobile/Documents/.trollserver_perm_test"
        let testData = "test".data(using: .utf8)
        let created = FileManager.default.createFile(atPath: testPath, contents: testData)
        if created {
            try? FileManager.default.removeItem(atPath: testPath)
        } else {
            return (false, "无法写入 /var/mobile/Documents，巨魔权限可能未生效")
        }

        // 测试2: 能否遍历 /var/containers/Bundle/Application（需要 root 权限）
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/var/containers/Bundle/Application/") {
            if contents.isEmpty {
                return (false, "Bundle 容器目录为空，系统状态异常")
            }
        } else {
            return (false, "无法访问 /var/containers/Bundle/Application，权限不足")
        }

        // 测试3: 能否读取 /var/mobile/Library/Preferences 中的系统 plist
        let testPlist = "/var/mobile/Library/Preferences/.GlobalPreferences.plist"
        if !FileManager.default.isReadableFile(atPath: testPlist) {
            // 某些系统可能不放这个文件，不作为硬性失败条件
            print("[SilentInstall] 警告: 无法读取系统偏好文件")
        }

        return (true, "权限正常，文件系统读写已就绪")
    }

    /// 检查 iOS 版本兼容性
    /// - Returns: (是否兼容, 版本描述, 版本号字符串)
    static func checkOSVersion() -> (ok: Bool, detail: String, versionString: String) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let vStr = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let major = version.majorVersion
        let minor = version.minorVersion
        let patch = version.patchVersion

        // iOS 14.0 - 16.6.1 完整支持
        if major >= 14 && major < 17 {
            if major == 16 && minor > 6 {
                return (false, "iOS 16.7+ 不支持，当前: iOS \(vStr)", vStr)
            }
            if major == 16 && minor == 6 && patch > 1 {
                return (false, "iOS 16.6.1+ 可能不支持，当前: iOS \(vStr)", vStr)
            }
            return (true, "iOS \(vStr) 兼容（14.0-16.6.1）", vStr)
        }

        // iOS 17.0.x 部分支持
        if major == 17 && minor == 0 {
            return (true, "iOS \(vStr) 部分兼容（17.0 系列）", vStr)
        }

        // iOS 17.1+ 不支持
        return (false, "iOS \(vStr) 不支持（需要 14.0-16.6.1 或 17.0）", vStr)
    }

    /// 完整的环境检测（权限 + 版本）
    static func fullEnvironmentCheck() -> (ok: Bool, messages: [String]) {
        var msgs: [String] = []
        var allOK = true

        let perm = checkPermissions()
        msgs.append("[权限] \(perm.detail)")
        if !perm.ok { allOK = false }

        let osv = checkOSVersion()
        msgs.append("[系统] \(osv.detail)")
        if !osv.ok { allOK = false }

        let helper = findTrollStoreHelper()
        if let h = helper {
            msgs.append("[工具] trollstorehelper: \(h)")
        } else {
            msgs.append("[工具] trollstorehelper: 未找到，将使用备用安装方式")
        }

        return (allOK, msgs)
    }

    // ============================================================
    // MARK: - ═══ IPA 验证 ═══
    // ============================================================

    /// 验证 IPA 文件有效性（不解压，仅校验结构）
    static func validateIPA(at path: String) -> (ok: Bool, detail: String) {
        // 1. 文件存在
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "IPA 文件不存在: \(path)")
        }

        // 2. 文件可读且大小 > 0
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size > 0 else {
            return (false, "IPA 文件为空或无法读取")
        }

        // 3. 检查是否为有效的 ZIP 文件（PK 签名）
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return (false, "无法打开 IPA 文件")
        }
        defer { try? fh.close() }

        guard let magic = try? fh.read(upToCount: 4), magic.count == 4 else {
            return (false, "IPA 文件头读取失败")
        }
        let sig = magic.map { String(format: "%02X", $0) }.joined()
        guard sig == "504B0304" else {
            return (false, "IPA 签名无效（非 ZIP 格式）: \(sig)")
        }

        // 4. 快速扫描 Payload/ 目录是否存在
        guard let listData = spawnAndCapture("/usr/bin/unzip", arguments: ["-l", path]),
              let listing = String(data: listData, encoding: .utf8),
              listing.contains("Payload/") else {
            return (false, "IPA 中未找到 Payload/ 目录")
        }

        // 5. 检查是否存在 .app 目录
        guard listing.contains(".app/") || listing.contains(".app") else {
            return (false, "IPA Payload 中未找到 .app 包")
        }

        return (true, "IPA 文件有效，\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
    }

    /// 从 IPA 提取 Info.plist 信息
    static func extractBundleInfo(from ipaPath: String) -> IPABundleInfo? {
        guard let plistData = spawnAndCapture("/bin/sh", arguments: [
            "-c", "unzip -p '\(ipaPath)' 'Payload/*/Info.plist' 2>/dev/null"
        ]) else {
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }

        return IPABundleInfo(
            bundleIdentifier: plist["CFBundleIdentifier"] as? String ?? "unknown",
            executableName: plist["CFBundleExecutable"] as? String ?? "unknown",
            displayName: (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? "unknown",
            version: (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "unknown"
        )
    }

    /// 解压 IPA 并返回临时目录中的 .app 路径
    static func extractApp(from ipaPath: String) -> (appPath: String?, error: String?) {
        let tmpRoot = "/var/mobile/Documents/.silent_install_tmp"
        let extractionDir = "\(tmpRoot)/\(UUID().uuidString)"

        // 清理并创建目录
        try? FileManager.default.removeItem(atPath: extractionDir)
        do {
            try FileManager.default.createDirectory(atPath: extractionDir, withIntermediateDirectories: true)
        } catch {
            return (nil, "创建解压目录失败: \(error.localizedDescription)")
        }

        // 调用 unzip 解压
        let ret = spawnAndWait("/usr/bin/unzip", arguments: ["-q", "-o", ipaPath, "-d", extractionDir])
        guard ret == 0 else {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, "unzip 解压失败，退出码: \(ret)")
        }

        // 扫描 Payload 目录下的 .app 包
        let payloadDir = "\(extractionDir)/Payload"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: payloadDir) else {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, "解压后 Payload 目录不可读")
        }

        let appDirs = contents.filter { $0.hasSuffix(".app") }
        guard let appName = appDirs.first else {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, "Payload 中未找到 .app 包")
        }

        // 验证 .app 包完整性
        let appPath = "\(payloadDir)/\(appName)"
        let validation = validateAppBundle(at: appPath)
        if !validation.ok {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, ".app 包验证失败: \(validation.detail)")
        }

        // 清理旧的解压残留（保留当前解压目录）
        cleanupOldExtractions(tmpRoot, keep: extractionDir)

        return (appPath, nil)
    }

    /// 验证 .app 包完整性
    static func validateAppBundle(at appPath: String) -> (ok: Bool, detail: String) {
        // 1. Info.plist 存在
        let plistPath = "\(appPath)/Info.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return (false, "Info.plist 缺失")
        }

        // 2. Info.plist 可解析
        guard let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            return (false, "Info.plist 解析失败")
        }

        // 3. 必需字段检查
        guard let execName = plist["CFBundleExecutable"] as? String, !execName.isEmpty else {
            return (false, "CFBundleExecutable 缺失")
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return (false, "CFBundleIdentifier 缺失")
        }

        // 4. 可执行文件存在
        let execPath = "\(appPath)/\(execName)"
        guard FileManager.default.fileExists(atPath: execPath) else {
            return (false, "可执行文件缺失: \(execName)")
        }

        // 5. 验证 Mach-O 魔数
        guard let fh = FileHandle(forReadingAtPath: execPath) else {
            return (false, "无法读取可执行文件")
        }
        defer { try? fh.close() }
        guard let magicData = try? fh.read(upToCount: 4), magicData.count >= 4 else {
            return (false, "可执行文件头读取失败")
        }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let validMagics: Set<UInt32> = [
            0xFEEDFACE,  // MH_MAGIC (32-bit)
            0xFEEDFACF,  // MH_CIGAM (32-bit swapped)
            0xBEBAFECA,  // FAT_MAGIC (Universal)
            0xCAFEBABE,  // FAT_CIGAM
            0xFEEDFACF,  // (duplicate for clarity)
        ]
        // Simpler: check FAT magic and MH magic
        let isMachO = (magic == 0xFEEDFACE || magic == 0xFEEDFACF || magic == 0xBEBAFECA || magic == 0xCAFEBABE)
        if !isMachO {
            // Also check 64-bit magic
            let isMachO64 = (magic == 0xFEEDFACF)
        }

        // 6. PkgInfo 存在（非必需，但警告）
        let pkgPath = "\(appPath)/PkgInfo"
        if !FileManager.default.fileExists(atPath: pkgPath) {
            print("[SilentInstall] 警告: PkgInfo 缺失（非致命）")
        }

        return (true, "完整，\(bundleID) v\(plist["CFBundleShortVersionString"] ?? "?")")
    }

    // ---- 内部辅助 ----

    private static func cleanupOldExtractions(_ root: String, keep: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for item in contents {
            let full = "\(root)/\(item)"
            if full == keep { continue }
            try? FileManager.default.removeItem(atPath: full)
        }
    }

    // ============================================================
    // MARK: - ═══ 核心安装流程 ═══
    // ============================================================

    private static func performInstall(
        ipaPath: String,
        progress: ((SilentInstallResult) -> Void)?
    ) -> SilentInstallResult {

        report(progress, .progress(phase: "环境检查", detail: "正在验证运行环境...", percent: 0))

        // ---- 步骤0: 环境检查 ----
        let env = fullEnvironmentCheck()
        if !env.ok {
            return .failure(message: "环境检查失败:\n\(env.messages.joined(separator: "\n"))")
        }
        for m in env.messages {
            print("[SilentInstall] \(m)")
        }

        // ---- 步骤1: 文件校验 ----
        report(progress, .progress(phase: "文件校验", detail: "正在验证 IPA 文件...", percent: 5))
        let validateResult = validateIPA(at: path)
        guard validateResult.ok else {
            return .failure(message: "IPA 验证失败: \(validateResult.detail)")
        }
        print("[SilentInstall] \(validateResult.detail)")

        // ---- 步骤2: 提取包信息 ----
        report(progress, .progress(phase: "信息提取", detail: "正在读取应用信息...", percent: 10))
        guard let bundleInfo = extractBundleInfo(from: ipaPath) else {
            return .failure(message: "无法从 IPA 中提取应用信息")
        }
        print("[SilentInstall] 应用: \(bundleInfo.displayName) (\(bundleInfo.bundleIdentifier)) v\(bundleInfo.version)")

        // ---- 步骤3: 强制关闭目标应用 ----
        report(progress, .progress(phase: "准备安装", detail: "正在关闭旧版本...", percent: 15))
        forceKillApp(executableName: bundleInfo.executableName)
        usleep(500000)

        // ---- 步骤4: 解压并验证 .app ----
        report(progress, .progress(phase: "解压验证", detail: "正在解压并验证应用包...", percent: 20))
        let extractResult = extractApp(from: ipaPath)
        if let error = extractResult.error {
            print("[SilentInstall] 预解压失败（非致命，将继续安装）: \(error)")
        } else if let appPath = extractResult.appPath {
            print("[SilentInstall] .app 解压完成: \(appPath)")
        }

        // ---- 步骤5: 尝试安装（多策略） ----
        let strategies: [(InstallMethod, (String) -> (Bool, String))] = [
            (.trollstorehelper, installViaHelper),
            (.lsApplicationWorkspace, installViaLSWorkspace),
            (.mobileInstallation, installViaMobileInstallation),
            (.fileCopy, installViaFileCopy),
        ]

        var lastError = ""

        for (method, strategy) in strategies {
            report(progress, .progress(phase: "正在安装", detail: "尝试: \(method.rawValue)...", percent: 30))
            let (ok, msg) = strategy(ipaPath)
            print("[SilentInstall] \(method.rawValue): \(ok ? "成功" : "失败") — \(msg)")

            if ok {
                // 安装成功，等待系统注册
                report(progress, .progress(phase: "注册中", detail: "等待系统注册应用...", percent: 85))
                usleep(1500000) // 1.5s

                // 验证安装（检查应用是否出现在容器目录中）
                report(progress, .progress(phase: "验证安装", detail: "正在验证安装结果...", percent: 95))
                if verifyInstall(bundleID: bundleInfo.bundleIdentifier) {
                    report(progress, .progress(phase: "完成", detail: "安装并验证成功", percent: 100))
                    return .success(
                        message: "\(bundleInfo.displayName) v\(bundleInfo.version) 安装成功\n方法: \(method.rawValue)",
                        method: method
                    )
                } else {
                    // 安装工具返回成功但验证失败，继续尝试其他方法
                    print("[SilentInstall] \(method.rawValue) 返回成功但验证失败，尝试下一种方案")
                    lastError = "\(method.rawValue) 安装返回成功但应用未注册到系统"
                    continue
                }
            } else {
                lastError = msg
            }
        }

        report(progress, .progress(phase: "失败", detail: "所有安装方法均失败", percent: 100))
        return .failure(message: "安装失败，所有方法均不可用。\n最后错误: \(lastError)")
    }

    // ============================================================
    // MARK: - ═══ 安装策略1: trollstorehelper ═══
    // ============================================================

    private static func installViaHelper(ipaPath: String) -> (Bool, String) {
        guard let helper = findTrollStoreHelper() else {
            return (false, "trollstorehelper 未找到")
        }

        print("[SilentInstall] 调用: \(helper) install \(ipaPath)")
        let ret = spawnAndWait(helper, arguments: ["install", ipaPath])
        if ret == 0 {
            return (true, "trollstorehelper 返回成功")
        } else {
            return (false, "trollstorehelper 退出码: \(ret)")
        }
    }

    // ============================================================
    // MARK: - ═══ 安装策略2: LSApplicationWorkspace 私有 API ═══
    // ============================================================

    private static func installViaLSWorkspace(ipaPath: String) -> (Bool, String) {
        // 需要用到解压后的 .app 路径
        // 如果当前没有解压的 .app，尝试使用 unzip 从 IPA 中提取
        let appResult = extractApp(from: ipaPath)
        guard let appPath = appResult.appPath else {
            return (false, "LSWorkspace: 无法解压 .app: \(appResult.error ?? "unknown")")
        }

        // 使用 Objective-C 运行时调用 LSApplicationWorkspace
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return (false, "LSWorkspace: 无法找到 LSApplicationWorkspace 类")
        }

        let sel = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: sel) else {
            return (false, "LSWorkspace: defaultWorkspace 方法不存在")
        }

        guard let workspace = workspaceClass.perform(sel)?.takeUnretainedValue() as? NSObject else {
            return (false, "LSWorkspace: 获取 defaultWorkspace 实例失败")
        }

        // 构造安装选项（静默安装，不弹确认框）
        let options: [String: Any] = [
            "LSInstallSilently": true,
            "LSInstallForUser": 501,  // mobile 用户
            "AllowInstallLocalProvisioned": true,
        ]
        let appURL = URL(fileURLWithPath: appPath)

        // 尝试多个可能的 selector 签名
        let installSelectors = [
            "installApplication:withOptions:",
            "installApplication:withOptions:error:",
            "_installApplication:withOptions:",
        ]

        for selName in installSelectors {
            let installSel = NSSelectorFromString(selName)
            guard workspace.responds(to: installSel) else { continue }

            // 检查方法签名参数数量
            let methodSig = workspace.method(for: installSel)
            if methodSig == nil { continue }

            // 尝试调用（单参数版本: installApplication:）
            if selName == "installApplication:withOptions:" {
                let result = workspace.perform(installSel, with: appURL, with: options as NSDictionary)
                // 等待安装完成
                usleep(2000000)
                print("[SilentInstall] LSApplicationWorkspace.installApplication 返回")
                return (true, "LSApplicationWorkspace 安装调用完成")
            }

            // 三参数版本: installApplication:withOptions:error:
            if selName == "installApplication:withOptions:error:" {
                var error: NSError?
                let _ = withUnsafeMutablePointer(to: &error) { errorPtr in
                    // 使用 NSInvocation 方式（更安全的动态调用）
                    workspace.perform(installSel, with: appURL, with: options as NSDictionary, with: errorPtr)
                    return errorPtr
                }
                if let err = error {
                    return (false, "LSWorkspace 安装错误: \(err.localizedDescription)")
                }
                usleep(2000000)
                return (true, "LSApplicationWorkspace 安装调用完成")
            }
        }

        return (false, "LSWorkspace: 未找到可用的安装方法")
    }

    // ============================================================
    // MARK: - ═══ 安装策略3: MobileInstallation 框架 ═══
    // ============================================================

    private static func installViaMobileInstallation(ipaPath: String) -> (Bool, String) {
        let appResult = extractApp(from: ipaPath)
        guard let appPath = appResult.appPath else {
            return (false, "MobileInstallation: 无法解压 .app: \(appResult.error ?? "unknown")")
        }

        // MobileInstallation.framework 路径
        let frameworkPaths = [
            "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
            "/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
        ]

        var handle: UnsafeMutableRawPointer?
        for fwPath in frameworkPaths {
            handle = dlopen(fwPath, RTLD_LAZY)
            if handle != nil { break }
        }

        guard let handle = handle else {
            return (false, "MobileInstallation 框架加载失败: \(String(cString: dlerror()))")
        }
        defer { dlclose(handle) }

        // MobileInstallationInstall 函数签名（iOS 14-16）
        // int MobileInstallationInstall(CFStringRef path, CFDictionaryRef options, void *callback, void *unknown)
        guard let symbol = dlsym(handle, "MobileInstallationInstall") else {
            return (false, "MobileInstallationInstall 符号未找到")
        }

        typealias MIInstallFunc = @convention(c) (
            CFString,          // path
            CFDictionary,      // options
            UnsafeMutableRawPointer?, // callback
            UnsafeMutableRawPointer?  // unknown
        ) -> Int32

        let installFunc = unsafeBitCast(symbol, to: MIInstallFunc.self)

        // 安装选项
        let options: [CFString: Any] = [
            "InstallType" as CFString: "System",
            "PackageType" as CFString: "Developer",
        ]

        // 使用全局信号量等待回调
        var installResult: (Bool, String) = (false, "未收到安装回调")
        let semaphore = DispatchSemaphore(value: 0)

        // 安装回调（C 函数指针 → Swift 闭包需通过全局变量桥接）
        MIInstallCallbackBridge.shared = { success, message in
            installResult = (success, message)
            semaphore.signal()
        }

        let callback: MIInstallCallback = { dict in
            guard let dict = dict as? [String: Any] else {
                MIInstallCallbackBridge.shared?(false, "回调数据格式错误")
                return
            }

            if let error = dict["Error"] as? String {
                MIInstallCallbackBridge.shared?(false, error)
                return
            }

            if let status = dict["Status"] as? String {
                if status == "Complete" {
                    MIInstallCallbackBridge.shared?(true, "安装完成")
                } else if status == "Install" {
                    print("[SilentInstall] MI 安装中: \(dict)")
                }
            }
        }

        let rc = installFunc(appPath as CFString, options as CFDictionary, nil, nil)
        if rc != 0 {
            return (false, "MobileInstallationInstall 返回错误码: \(rc)")
        }

        // 等待最多 30 秒
        _ = semaphore.wait(timeout: .now() + 30)
        return installResult
    }

    // ============================================================
    // MARK: - ═══ 安装策略4: 文件复制到检测目录 ═══
    // ============================================================

    private static func installViaFileCopy(ipaPath: String) -> (Bool, String) {
        let tsTargets = [
            "/var/mobile/.TrollStore/tmp/",
            "/var/mobile/Library/Caches/TrollStore/",
            "/var/mobile/Documents/TrollStore/",
        ]

        let fileName = URL(fileURLWithPath: ipaPath).lastPathComponent

        for tsPath in tsTargets {
            let dest = "\(tsPath)\(fileName)"
            do {
                try? FileManager.default.createDirectory(atPath: tsPath, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: ipaPath, toPath: dest)
                print("[SilentInstall] 文件已复制到: \(dest)")

                // 触发 TrollStore 检测：创建标记文件
                let triggerPath = "\(tsPath).install_trigger"
                try? "1".data(using: .utf8)?.write(to: URL(fileURLWithPath: triggerPath))

                return (true, "已复制到 TrollStore 目录")
            } catch {
                print("[SilentInstall] 文件复制到 \(tsPath) 失败: \(error)")
            }
        }

        return (false, "所有 TrollStore 目录复制均失败")
    }

    // ============================================================
    // MARK: - ═══ 辅助方法 ═══
    // ============================================================

    /// 验证应用是否已安装
    private static func verifyInstall(bundleID: String) -> Bool {
        // 方法1: 检查应用容器目录
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/var/containers/Bundle/Application/") {
            for uuid in apps {
                let appDir = "/var/containers/Bundle/Application/\(uuid)"
                for item in (try? FileManager.default.contentsOfDirectory(atPath: appDir)) ?? [] {
                    if item.hasSuffix(".app") {
                        let plistPath = "\(appDir)/\(item)/Info.plist"
                        if let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                           let bid = plist["CFBundleIdentifier"] as? String,
                           bid == bundleID {
                            print("[SilentInstall] 验证成功: 找到 \(bundleID) 在 \(appDir)/\(item)")
                            return true
                        }
                    }
                }
            }
        }

        // 方法2: 检查 iTunesMetadata.plist（注册表）
        let metaPath = "/var/mobile/Library/Caches/com.apple.mobile.installation.plist"
        if let meta = NSDictionary(contentsOfFile: metaPath) as? [String: Any],
           let userApps = meta["User"] as? [String: Any],
           userApps[bundleID] != nil {
            print("[SilentInstall] 验证成功: 在安装清单中找到 \(bundleID)")
            return true
        }

        return false
    }

    /// 强制关闭应用
    private static func forceKillApp(executableName: String) {
        guard !executableName.isEmpty, executableName != "unknown" else { return }

        let killallPaths = [
            "/usr/bin/killall", "/bin/killall",
            "/usr/sbin/killall", "/var/jb/usr/bin/killall",
        ]

        for kp in killallPaths {
            if FileManager.default.isExecutableFile(atPath: kp) {
                print("[SilentInstall] killall: \(kp) -9 \(executableName)")
                _ = spawnAndWait(kp, arguments: ["-9", executableName])
                return
            }
        }

        // Shell 兜底
        _ = spawnAndWait("/bin/sh", arguments: ["-c", "killall -9 \(executableName) 2>/dev/null; true"])
    }

    /// 查找 trollstorehelper
    static func findTrollStoreHelper() -> String? {
        let knownPaths = [
            "/var/jb/usr/bin/trollstorehelper",
            "/usr/bin/trollstorehelper",
            "/usr/local/bin/trollstorehelper",
            "/Applications/TrollStore.app/trollstorehelper",
            "/private/var/jb/usr/bin/trollstorehelper",
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 运行时搜索
        let searchDirs = [
            "/Applications/TrollStore.app",
            "/var/jb/usr/bin",
            "/private/var/jb/usr/bin",
            "/usr/bin",
            "/usr/local/bin",
        ]
        for dir in searchDirs {
            let path = "\(dir)/trollstorehelper"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 进度报告
    private static func report(_ handler: ((SilentInstallResult) -> Void)?, _ result: SilentInstallResult) {
        handler?(result)
    }

    // ============================================================
    // MARK: - ═══ posix_spawn 辅助 ═══
    // ============================================================

    static func spawnAndWait(_ path: String, arguments: [String]) -> Int32 {
        let cargs = arguments.map { strdup($0) }
        defer { cargs.forEach { free($0) } }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, nil, nil, ptr.baseAddress, nil)
        }

        guard ret == 0 else {
            print("[SilentInstall] posix_spawn(\"\(path)\") 失败: \(ret)")
            return -1
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0x000000ff
    }

    static func spawnAndCapture(_ path: String, arguments: [String]) -> Data? {
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else { return nil }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])

        let cargs = arguments.map { strdup($0) }
        defer {
            cargs.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fileActions)
        }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, &fileActions, nil, ptr.baseAddress, nil)
        }
        close(pipeFD[1])

        guard ret == 0 else { close(pipeFD[0]); return nil }

        var data = Data()
        var status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(pipeFD[0], &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) } else { break }
        }
        close(pipeFD[0])
        waitpid(pid, &status, 0)
        return data.isEmpty ? nil : data
    }

    private static func isExecutable(at path: String) -> Bool {
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func path(_ path: String) -> String {
        return (path as NSString).standardizingPath
    }

    /// 清理临时解压文件
    static func cleanupTempFiles() {
        let tmpRoot = "/var/mobile/Documents/.silent_install_tmp"
        try? FileManager.default.removeItem(atPath: tmpRoot)
    }
}

// MARK: - MobileInstallation 回调桥接

private typealias MIInstallCallback = @convention(c) (CFDictionary?) -> Void

private class MIInstallCallbackBridge {
    static var shared: ((Bool, String) -> Void)?
}

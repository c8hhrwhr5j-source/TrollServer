import Foundation
import Darwin
import UIKit
import zlib

// ============================================================
//  巨魔环境下静默安装 IPA 功能模块
//  支持: iOS 14.0 - 16.6.1 / iOS 17.0 特定版本
// ============================================================

// MARK: - 安装方法枚举

enum InstallMethod: String {
    case trollstorehelper  = "trollstorehelper"
    case trollstoreURLScheme = "TrollStore URL Scheme"
    case lsApplicationWorkspace = "LSApplicationWorkspace"
    case mobileInstallation = "MobileInstallation"
    case fileCopy           = "文件复制"
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

        // 测试2: 能否读取一个系统文件（证明有沙盒外读权限）
        let testPlist = "/System/Library/CoreServices/SystemVersion.plist"
        if !FileManager.default.isReadableFile(atPath: testPlist) {
            return (false, "无法读取系统文件 /System/Library/CoreServices/SystemVersion.plist")
        }

        // 测试3: 能否读取一个用户文件
        if !FileManager.default.isReadableFile(atPath: "/var/mobile") {
            return (false, "无法读取 /var/mobile，权限不足")
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

    /// 返回可用的 unzip 二进制路径（iOS 上不一定在 /usr/bin）
    static func findUnzipBinary() -> String? {
        let candidates = [
            "/usr/bin/unzip",
            "/usr/local/bin/unzip",
            "/var/jb/usr/bin/unzip",
            "/var/bin/unzip",
            "/bin/unzip",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }



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

        // 4. 快速扫描 Payload/ 目录是否存在（尝试多个 unzip 路径）
        var listing: String = ""
        if let unzipPath = findUnzipBinary() {
            if let listData = spawnAndCapture(unzipPath, arguments: ["-l", path]) {
                listing = String(data: listData, encoding: .utf8) ?? ""
            }
        }

        // unzip 不存在时回退：读取本地 ZIP 中央目录，做简单目录名匹配
        if listing.isEmpty {
            listing = approximateZipListing(at: path) ?? ""
        }

        let hasPayload = listing.range(of: "Payload/", options: .caseInsensitive) != nil
            || listing.range(of: "Payload", options: .caseInsensitive) != nil
        let hasApp = listing.range(of: ".app/", options: .caseInsensitive) != nil
            || listing.range(of: ".app", options: .caseInsensitive) != nil

        guard hasPayload else {
            return (false, "IPA 中未找到 Payload/ 目录（unzip可用路径：\(findUnzipBinary() ?? "无")，解析条目数：\(listing.components(separatedBy: CharacterSet.newlines).count)）")
        }

        guard hasApp else {
            return (false, "IPA Payload 中未找到 .app 包")
        }

        return (true, "IPA 文件有效，\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
    }

    // MARK: - ZIP 解析（不依赖 unzip）

    struct ZipEntry {
        let name: String
        let localHeaderOffset: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count > 22 else { return nil }
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for i in (0..<(data.count - 22)).reversed() {
            if Array(data[i..<i+4]) == sig {
                // 校验 comment length 是否匹配尾部
                let commentLen = data.withUnsafeBytes { $0.load(fromByteOffset: i + 20, as: UInt16.self) }
                if i + 22 + Int(commentLen) == data.count {
                    return i
                }
            }
        }
        return nil
    }

    private static func listZipEntries(in data: Data) -> [ZipEntry] {
        guard let eocdOffset = findEOCD(in: data) else { return [] }
        let cdStart = Int(data.withUnsafeBytes { $0.load(fromByteOffset: eocdOffset + 16, as: UInt32.self) })
        let cdSize = Int(data.withUnsafeBytes { $0.load(fromByteOffset: eocdOffset + 12, as: UInt32.self) })
        guard cdStart + cdSize <= data.count else { return [] }

        let cdData = data.subdata(in: cdStart..<cdStart + cdSize)
        var entries: [ZipEntry] = []
        var offset = 0
        while offset + 46 <= cdData.count {
            let sig = cdData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            guard sig == 0x02014B50 else { break }
            let compressionMethod = cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self) }
            let compressedSize = cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: UInt32.self) }
            let uncompressedSize = cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 24, as: UInt32.self) }
            let nameLen = Int(cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 28, as: UInt16.self) })
            let extraLen = Int(cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 30, as: UInt16.self) })
            let commentLen = Int(cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 32, as: UInt16.self) })
            let localHeaderOffset = cdData.withUnsafeBytes { $0.load(fromByteOffset: offset + 42, as: UInt32.self) }
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.count else { break }
            let name = String(data: cdData.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            entries.append(ZipEntry(
                name: name,
                localHeaderOffset: localHeaderOffset,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                compressionMethod: compressionMethod
            ))
            offset = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func findZipEntry(namedPattern pattern: String, in data: Data) -> ZipEntry? {
        let entries = listZipEntries(in: data)
        // 简单通配符：把 * 转换为 .* 做前缀/后缀匹配
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        return entries.first { entry in
            var remaining = entry.name
            for (idx, part) in parts.enumerated() {
                let partStr = String(part)
                if idx == 0 {
                    if !partStr.isEmpty && !remaining.hasPrefix(partStr) { return false }
                    remaining = String(remaining.dropFirst(partStr.count))
                } else if idx == parts.count - 1 {
                    if !partStr.isEmpty && !remaining.hasSuffix(partStr) { return false }
                    remaining = ""
                } else {
                    if let range = remaining.range(of: partStr) {
                        remaining = String(remaining[range.upperBound...])
                    } else {
                        return false
                    }
                }
            }
            return true
        }
    }

    private static func extractZipEntry(_ entry: ZipEntry, from data: Data) -> Data? {
        guard entry.localHeaderOffset + 30 <= data.count else { return nil }
        let local = entry.localHeaderOffset
        let nameLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: local + 26, as: UInt16.self) })
        let extraLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: local + 28, as: UInt16.self) })
        let dataOffset = Int(local) + 30 + nameLen + extraLen
        let endOffset = dataOffset + Int(entry.compressedSize)
        guard endOffset <= data.count else { return nil }
        let compressed = data.subdata(in: dataOffset..<endOffset)

        if entry.compressionMethod == 0 {
            return compressed
        } else if entry.compressionMethod == 8 {
            return inflateDeflate(compressed, expectedSize: Int(entry.uncompressedSize))
        }
        return nil
    }

    private static func inflateDeflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        var status = compressed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expectedSize)
                return inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            }
        }
        guard status == Z_OK else { return nil }
        status = inflate(&stream, Z_FINISH)
        inflateEnd(&stream)
        guard status == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    private static func extractAllZipEntries(from data: Data, toDirectory dir: String) -> Bool {
        let entries = listZipEntries(in: data)
        guard !entries.isEmpty else { return false }
        for entry in entries {
            guard let raw = extractZipEntry(entry, from: data) else { continue }
            let destPath = "\(dir)/\(entry.name)"
            let destURL = URL(fileURLWithPath: destPath)
            let dirPath = destURL.deletingLastPathComponent().path
            if !FileManager.default.fileExists(atPath: dirPath) {
                try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
            if entry.name.hasSuffix("/") {
                try? FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
            } else {
                try? raw.write(to: destURL)
            }
        }
        return true
    }

    private static func approximateZipListing(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return nil
        }
        let entries = listZipEntries(in: data)
        return entries.map { $0.name }.joined(separator: "\n")
    }

    /// 简单判断是否为 ZIP 文件（PK\x03\x04）
    static func isZipFile(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path),
              let magic = try? fh.read(upToCount: 4),
              magic.count == 4 else { return false }
        try? fh.close()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// 从 IPA 提取 Info.plist 信息（不依赖 unzip，直接解析 ZIP）
    static func extractBundleInfo(from ipaPath: String) -> IPABundleInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ipaPath), options: [.mappedIfSafe]),
              let entry = findZipEntry(namedPattern: "Payload/*/Info.plist", in: data),
              let plistData = extractZipEntry(entry, from: data),
              let plist = try? PropertyListSerialization.propertyList(
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

    /// 解压 IPA 并返回临时目录中的 .app 路径（不依赖系统 unzip）
    static func extractApp(from ipaPath: String) -> (appPath: String?, error: String?) {
        let tmpRoot = "/var/mobile/Documents/.silent_install_tmp"
        let extractionDir = "\(tmpRoot)/\(UUID().uuidString)"

        try? FileManager.default.removeItem(atPath: extractionDir)
        do {
            try FileManager.default.createDirectory(atPath: extractionDir, withIntermediateDirectories: true)
        } catch {
            return (nil, "创建解压目录失败: \(error.localizedDescription)")
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ipaPath), options: [.mappedIfSafe]) else {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, "无法读取 IPA 文件")
        }
        if !extractAllZipEntries(from: data, toDirectory: extractionDir) {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, "ZIP 解压失败（可能是 DEFLATE 不支持）")
        }

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

        let appPath = "\(payloadDir)/\(appName)"
        let validation = validateAppBundle(at: appPath)
        if !validation.ok {
            try? FileManager.default.removeItem(atPath: extractionDir)
            return (nil, ".app 包验证失败: \(validation.detail)")
        }

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
        // FAT magic and MH magic (32+64-bit)
        let isMachO = (magic == 0xFEEDFACE || magic == 0xFEEDFACF || magic == 0xBEBAFECA || magic == 0xCAFEBABE
                        || magic == 0xFEEDFACF || magic == 0xCFFAEDFE || magic == 0xCEFAEDFE)

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
        let validateResult = validateIPA(at: ipaPath)
        if validateResult.ok {
            print("[SilentInstall] \(validateResult.detail)")
        } else {
            // 只要文件是合法 ZIP，就继续尝试安装（trollstorehelper 自己会再校验一次）
            if isZipFile(at: ipaPath) {
                print("[SilentInstall] IPA 结构校验警告: \(validateResult.detail)")
                print("[SilentInstall] 文件仍为合法 ZIP，将继续尝试安装")
            } else {
                return .failure(message: "IPA 验证失败: \(validateResult.detail)")
            }
        }

        // ---- 步骤2: 提取包信息（失败不阻塞） ----
        report(progress, .progress(phase: "信息提取", detail: "正在读取应用信息...", percent: 10))
        let bundleInfo = extractBundleInfo(from: ipaPath)
        if let info = bundleInfo {
            print("[SilentInstall] 应用: \(info.displayName) (\(info.bundleIdentifier)) v\(info.version)")
            // 强制关闭目标应用
            report(progress, .progress(phase: "准备安装", detail: "正在关闭旧版本...", percent: 15))
            forceKillApp(executableName: info.executableName)
            usleep(500000)
        } else {
            print("[SilentInstall] 警告: 无法从 IPA 中提取应用信息，将继续尝试安装")
        }

        // ---- 步骤3: 预解压 .app（失败不阻塞） ----
        report(progress, .progress(phase: "解压验证", detail: "正在解压并验证应用包...", percent: 20))
        let extractResult = extractApp(from: ipaPath)
        var extractedAppPath: String? = nil
        if let error = extractResult.error {
            print("[SilentInstall] 预解压失败（非致命，将继续安装）: \(error)")
        } else if let appPath = extractResult.appPath {
            print("[SilentInstall] .app 解压完成: \(appPath)")
            extractedAppPath = appPath
        }

        // ---- 步骤4: 尝试安装（多策略，从最可靠到最不可靠） ----
        var lastError = ""
        let targetPath = extractedAppPath ?? ipaPath

        let strategies: [(InstallMethod, () -> (Bool, String))] = [
            (.trollstorehelper, { installViaHelper(ipaPath) }),
            (.lsApplicationWorkspace, { installViaLSWorkspace(targetPath) }),
            (.mobileInstallation, { installViaMobileInstallation(targetPath) }),
            (.trollstoreURLScheme, { installViaURLScheme(ipaPath) }),
            (.fileCopy, { installViaFileCopy(ipaPath) }),
        ]

        for (method, strategy) in strategies {
            report(progress, .progress(phase: "正在安装", detail: "尝试: \(method.rawValue)...", percent: 30))
            let (ok, msg) = strategy()
            print("[SilentInstall] \(method.rawValue): \(ok ? "成功" : "失败") — \(msg)")

            if ok {
                report(progress, .progress(phase: "注册中", detail: "等待系统注册应用...", percent: 85))
                usleep(1500000)

                report(progress, .progress(phase: "验证安装", detail: "正在验证安装结果...", percent: 95))
                let verifyOK = bundleInfo.map { verifyInstall(bundleID: $0.bundleIdentifier) } ?? true
                if verifyOK {
                    report(progress, .progress(phase: "完成", detail: "安装并验证成功", percent: 100))
                    let appDesc = bundleInfo.map { "\($0.displayName) v\($0.version)" } ?? "IPA"
                    return .success(
                        message: "\(appDesc) 安装成功\n方法: \(method.rawValue)",
                        method: method
                    )
                } else {
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
    // MARK: - ═══ 安装策略1: trollstorehelper（root 提权执行） ═══
    // ============================================================

    private static func installViaHelper(_ targetPath: String) -> (Bool, String) {
        guard let helper = findTrollStoreHelper() else {
            return (false, "trollstorehelper 未找到")
        }

        // 用法: trollstorehelper install <ipaPath>
        print("[SilentInstall] spawnRoot: \(helper) install \(targetPath)")
        let ret = spawnRoot(helper, arguments: ["install", targetPath])
        if ret == 0 {
            return (true, "trollstorehelper 安装成功")
        } else {
            return (false, "trollstorehelper 退出码: \(ret)")
        }
    }

    // ============================================================
    // MARK: - ═══ 安装策略2: LSApplicationWorkspace 私有 API ═══
    // ============================================================

    private static func installViaLSWorkspace(_ targetPath: String) -> (Bool, String) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return (false, "LSWorkspace: 无法找到 LSApplicationWorkspace 类")
        }
        guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return (false, "LSWorkspace: 获取 defaultWorkspace 实例失败")
        }

        let appURL = URL(fileURLWithPath: targetPath)
        let options: [String: Any] = ["LSInstallSilently": true]

        // 标准 ObjC 方法签名: installApplication:withOptions: -> void
        let sel = NSSelectorFromString("installApplication:withOptions:")
        guard workspace.responds(to: sel) else {
            return (false, "LSWorkspace: 不响应 installApplication:withOptions:")
        }

        typealias InstallFunc = @convention(c) (AnyObject, Selector, URL, NSDictionary) -> Void
        let imp = workspace.method(for: sel)
        let install = unsafeBitCast(imp, to: InstallFunc.self)
        install(workspace, sel, appURL, options as NSDictionary)

        // 等待安装
        usleep(3000000)
        return (true, "LSApplicationWorkspace 安装调用完成")
    }

    // ============================================================
    // MARK: - ═══ 安装策略3: TrollStore URL Scheme（最通用方案） ═══
    // ============================================================
    /// TrollStore 注册了 apple-magnifier:// URL Scheme
    /// 这是最通用的安装方案：不依赖 helper 路径，任何 TrollStore 设备都支持

    private static func installViaURLScheme(_ ipaPath: String) -> (Bool, String) {
        let fileURL = URL(fileURLWithPath: ipaPath)
        let urlStr = "apple-magnifier://install?url=\(fileURL.absoluteString)"
            .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""

        guard let url = URL(string: urlStr) else {
            return (false, "TrollStore URL Scheme: 无法构造 URL")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                result = true
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return result ? (true, "已通过 TrollStore 安装") : (false, "TrollStore URL Scheme: 无法打开")
    }

    // ============================================================
    // MARK: - ═══ 安装策略4: MobileInstallation 框架 ═══
    // ============================================================

    private static func installViaMobileInstallation(_ targetPath: String) -> (Bool, String) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY) else {
            return (false, "MobileInstallation 框架加载失败")
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "MobileInstallationInstall") else {
            return (false, "MobileInstallationInstall 符号未找到")
        }

        typealias MIInstallFunc = @convention(c) (
            CFString, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
        ) -> Int32

        let installFunc = unsafeBitCast(symbol, to: MIInstallFunc.self)
        let rc = installFunc(targetPath as CFString, nil, nil, nil)

        if rc == 0 {
            usleep(2000000)
            return (true, "MobileInstallation 安装成功")
        }
        return (false, "MobileInstallation 返回错误码: \(rc)")
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

    /// 通用查找 trollstorehelper：先用 find 系统命令搜索，再回退到已知路径
    static func findTrollStoreHelper() -> String? {
        // 1. 用 find 命令全局搜索（最可靠，不受权限限制）
        if let data = spawnRootAndCapture("/usr/bin/find", arguments: [
            "/", "-name", "trollstorehelper", "-type", "f",
            "(", "-path", "*/TrollStore.app/*", "-o", "-path", "*/usr/bin/*", ")",
            "-not", "-path", "*/Backups/*", "-not", "-path", "*/.Trash/*",
            "-print", "-quit", "2>/dev/null"
        ]) {
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !output.isEmpty && FileManager.default.isExecutableFile(atPath: output) {
                return output
            }
        }

        // 2. 常见绝对路径（fast path）
        let knownPaths = [
            "/Applications/TrollStore.app/trollstorehelper",
            "/var/jb/Applications/TrollStore.app/trollstorehelper",
            "/private/var/jb/Applications/TrollStore.app/trollstorehelper",
            "/var/jb/usr/bin/trollstorehelper",
            "/usr/bin/trollstorehelper",
        ]
        for path in knownPaths {
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
    // MARK: - ═══ posix_spawn 辅助（通用） ═══
    // ============================================================

    /// 以 root 身份执行命令（TrollStore 内部标准做法）
    /// 使用 posix_spawnattr_set_persona_np 提权到 uid=0/gid=0
    static func spawnRoot(_ path: String, arguments: [String]) -> Int32 {
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        // TrollStore 标准提权流程
        let persona: UInt64 = 99
        let personaFlags: UInt32 = 1
        let uid: uid_t = 0
        let gid: gid_t = 0

        withUnsafePointer(to: persona) { p in posix_spawnattr_set_persona_np(&attrs, p, personaFlags) }
        withUnsafePointer(to: uid) { u in posix_spawnattr_set_persona_uid_np(&attrs, u) }
        withUnsafePointer(to: gid) { g in posix_spawnattr_set_persona_gid_np(&attrs, g) }

        let cargs = arguments.map { strdup($0) }
        defer { cargs.forEach { free($0) } }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, nil, &attrs, ptr.baseAddress, nil)
        }

        guard ret == 0 else {
            print("[SilentInstall] spawnRoot(\"\(path)\") 失败: \(ret)")
            return -1
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0x000000ff
    }

    /// 以 root 身份执行命令并捕获标准输出
    static func spawnRootAndCapture(_ path: String, arguments: [String]) -> Data? {
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else { return nil }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFD[0])

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)

        let persona: UInt64 = 99
        let personaFlags: UInt32 = 1
        let uid: uid_t = 0
        let gid: gid_t = 0
        withUnsafePointer(to: persona) { p in posix_spawnattr_set_persona_np(&attrs, p, personaFlags) }
        withUnsafePointer(to: uid) { u in posix_spawnattr_set_persona_uid_np(&attrs, u) }
        withUnsafePointer(to: gid) { g in posix_spawnattr_set_persona_gid_np(&attrs, g) }

        let cargs = arguments.map { strdup($0) }
        defer {
            cargs.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attrs)
        }

        var pid: pid_t = 0
        var argv = cargs + [nil]
        let ret = argv.withUnsafeMutableBufferPointer { ptr in
            posix_spawn(&pid, path, &fileActions, &attrs, ptr.baseAddress, nil)
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

    static func spawnAndWait(_ path: String, arguments: [String]) -> Int32 {
        return spawnRoot(path, arguments: arguments)
    }

    static func spawnAndCapture(_ path: String, arguments: [String]) -> Data? {
        return spawnRootAndCapture(path, arguments: arguments)
    }
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


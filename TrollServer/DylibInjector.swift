import Foundation

// MARK: - 目标 App 配置

struct InjectTarget: Identifiable, Equatable {
    let id: String          // bundleId
    let name: String        // 中文名
    let icon: String        // emoji

    static let all: [InjectTarget] = [
        InjectTarget(id: "com.tencent.xin", name: "微信", icon: "💬"),
        InjectTarget(id: "com.tencent.mqq", name: "QQ",   icon: "🐧"),
    ]
}

// MARK: - Mach-O 常量

private let MH_MAGIC_64: UInt32    = 0xFEEDFACF
private let MH_CIGAM_64: UInt32    = 0xCFFAEDFE

private let LC_LOAD_DYLIB: UInt32       = 0x0000000C
private let LC_CODE_SIGNATURE: UInt32   = 0x0000001D

// MARK: - 注入引擎

enum DylibInjector {

    static let dylibName = "libiPadSpoof.dylib"
    static let logPath = "/var/mobile/Library/Logs/trollserver.log"

    // MARK: - 日志

    private static func log(_ msg: String) {
        let line = "[\(Date())] [Injector] \(msg)\n"
        print(line, terminator: "")
        try? line.data(using: .utf8)?.appendTo(file: logPath)
    }

    // MARK: - 扫描已安装 App

    /// 扫描系统目录，返回已安装的目标 App（微信/QQ）
    static func scanInstalledApps() -> [(target: InjectTarget, appPath: String)] {
        var results: [(target: InjectTarget, appPath: String)] = []
        let bundleBases = [
            "/var/containers/Bundle/Application",
            "/private/var/containers/Bundle/Application",
        ]
        let fm = FileManager.default

        for base in bundleBases {
            guard let containerDirs = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for container in containerDirs {
                let containerPath = "\(base)/\(container)"
                guard let items = try? fm.contentsOfDirectory(atPath: containerPath) else { continue }
                for item in items {
                    guard item.hasSuffix(".app") else { continue }
                    let appPath = "\(containerPath)/\(item)"
                    let infoPath = "\(appPath)/Info.plist"
                    guard let info = NSDictionary(contentsOfFile: infoPath),
                          let bid = info["CFBundleIdentifier"] as? String else { continue }
                    if let t = InjectTarget.all.first(where: { $0.id == bid }) {
                        if !results.contains(where: { $0.target.id == bid }) {
                            results.append((target: t, appPath: appPath))
                        }
                    }
                }
            }
        }
        return results
    }

    /// 判断某 App 是否已注入
    static func isInjected(appPath: String) -> Bool {
        let execName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let binaryPath = "\(appPath)/\(execName)"
        return hasDylibLoadCommand(at: binaryPath, dylibName: dylibName)
    }

    // MARK: - 注入

    /// 尝试注入 dylib 到目标 App
    static func inject(appPath: String) -> Result<String, InjectError> {
        let fm = FileManager.default
        let execName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let binaryPath = "\(appPath)/\(execName)"
        let frameworksPath = "\(appPath)/Frameworks"
        let dylibDestPath = "\(frameworksPath)/\(dylibName)"
        let loadPath = "@executable_path/Frameworks/\(dylibName)"

        // 找到内嵌 dylib
        let dylibSrc: String
        if let rp = Bundle.main.resourcePath {
            dylibSrc = "\(rp)/\(dylibName)"
        } else {
            dylibSrc = "\(Bundle.main.bundlePath)/\(dylibName)"
        }
        guard fm.fileExists(atPath: dylibSrc) else {
            log("❌ 内置 dylib 不存在: \(dylibSrc)")
            return .failure(.dylibNotFound)
        }

        // 检查是否已注入
        if hasDylibLoadCommand(at: binaryPath, dylibName: dylibName) {
            log("⚠️ \(execName) 已注入过")
            return .failure(.alreadyInjected)
        }

        // 验证二进制可读写
        guard fm.isReadableFile(atPath: binaryPath) else {
            log("❌ 二进制不可读: \(binaryPath)")
            return .failure(.binaryNotReadable)
        }

        // 1. 备份二进制（第一次注入时）— 使用 cp 命令绕过沙盒
        let backupPath = "\(binaryPath).trollserver_backup"
        if !fm.fileExists(atPath: backupPath) {
            let r = runShellCommand("cp '\(binaryPath)' '\(backupPath)' 2>&1")
            if r.exitCode != 0 {
                log("⚠️ 备份失败 (cp exit=\(r.exitCode)): \(r.stdout)")
                // 不阻塞，继续尝试注入
            } else {
                log("✅ 已备份: \(backupPath)")
            }
        }

        // 2. 创建 Frameworks 目录 — 使用 mkdir 命令
        if !fm.fileExists(atPath: frameworksPath) {
            let r = runShellCommand("mkdir -p '\(frameworksPath)' 2>&1")
            if r.exitCode != 0 {
                log("❌ 创建 Frameworks 目录失败 (mkdir exit=\(r.exitCode)): \(r.stdout)")
                return .failure(.cantCreateFrameworks("mkdir exit=\(r.exitCode): \(r.stdout)"))
            }
            _ = runShellCommand("chmod 755 '\(frameworksPath)' 2>&1")
        }

        // 3. 复制 dylib — 使用 cp 命令
        if fm.fileExists(atPath: dylibDestPath) {
            _ = runShellCommand("rm -f '\(dylibDestPath)' 2>&1")
        }
        let cpResult = runShellCommand("cp '\(dylibSrc)' '\(dylibDestPath)' 2>&1")
        if cpResult.exitCode != 0 {
            log("❌ 复制 dylib 失败 (cp exit=\(cpResult.exitCode)): \(cpResult.stdout)")
            return .failure(.cantCopyDylib("cp exit=\(cpResult.exitCode): \(cpResult.stdout)"))
        }
        _ = runShellCommand("chmod 755 '\(dylibDestPath)' 2>&1")
        log("✅ dylib 已复制到 \(dylibDestPath)")

        // 4. 修补 Mach-O 二进制
        do {
            try patchMachO(at: binaryPath, dylibLoadPath: loadPath)
            log("✅ 二进制已修补: \(binaryPath)")
        } catch let e as InjectError {
            log("❌ 修补失败: \(e)")
            return .failure(e)
        } catch {
            log("❌ 修补失败: \(error)")
            return .failure(.patchFailed("\(error)"))
        }

        // 5. 尝试重签（用 ldid 修签名，让 App 能启动）
        let signResult = runShellCommand("/usr/bin/ldid -S \(binaryPath)")
        if signResult.exitCode == 0 {
            log("✅ ldid 重签成功")
        } else {
            log("⚠️ ldid 重签返回 exit=\(signResult.exitCode)（可能不影响 TrollStore 环境）")
        }

        // 6. 写入配置
        SpoofConfig.isEnabled = true

        return .success("✅ 注入成功！\n请上滑彻底关闭 \(execName)，重新打开即可生效")
    }

    // MARK: - 恢复注入

    /// 从备份恢复 App 二进制
    static func restore(appPath: String) -> Result<String, InjectError> {
        let fm = FileManager.default
        let execName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let binaryPath = "\(appPath)/\(execName)"
        let backupPath = "\(binaryPath).trollserver_backup"
        let frameworksPath = "\(appPath)/Frameworks"
        let dylibDestPath = "\(frameworksPath)/\(dylibName)"

        guard fm.fileExists(atPath: backupPath) else {
            return .failure(.noBackup)
        }

        // 恢复二进制 — 使用 cp 命令绕过沙盒
        let rmResult = runShellCommand("rm -f '\(binaryPath)' 2>&1")
        if rmResult.exitCode != 0 {
            log("⚠️ 删除旧二进制警告 (rm exit=\(rmResult.exitCode)): \(rmResult.stdout)")
        }
        let cpResult = runShellCommand("cp '\(backupPath)' '\(binaryPath)' 2>&1")
        if cpResult.exitCode != 0 {
            return .failure(.restoreFailed("cp exit=\(cpResult.exitCode): \(cpResult.stdout)"))
        }
        _ = runShellCommand("chmod 755 '\(binaryPath)' 2>&1")

        // 删除 dylib
        _ = runShellCommand("rm -f '\(dylibDestPath)' 2>&1")

        // 重签
        _ = runShellCommand("/usr/bin/ldid -S \(binaryPath)")

        log("✅ 已恢复 \(execName)")
        return .success("已恢复 \(execName)")
    }

    // MARK: - Mach-O 修补

    /// 在 Fat/单架构 Mach-O 中注入 LC_LOAD_DYLIB，并去除 LC_CODE_SIGNATURE
    /// 使用临时文件 + cp 命令绕过沙盒写入限制
    static func patchMachO(at path: String, dylibLoadPath: String) throws {
        let url = URL(fileURLWithPath: path)
        var data = try Data(contentsOf: url)

        guard data.count >= 4 else { throw InjectError.invalidBinary }

        // 读取魔数
        let magic = readU32(data: data, offset: 0)
        if magic == MH_MAGIC_64 || magic == MH_CIGAM_64 {
            try patchMachO64(data: &data, at: 0, dylibLoadPath: dylibLoadPath)
        } else if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            // Fat binary
            try patchFatBinary(data: &data, dylibLoadPath: dylibLoadPath)
        } else {
            throw InjectError.invalidBinary
        }

        // 先写入沙盒临时文件，再用 cp 命令覆盖目标（绕过沙盒）
        let tmpPath = "/tmp/trollserver_patch_\(UUID().uuidString).tmp"
        let tmpURL = URL(fileURLWithPath: tmpPath)
        try data.write(to: tmpURL)
        defer { _ = runShellCommand("rm -f '\(tmpPath)' 2>&1") }

        let cpResult = runShellCommand("cp '\(tmpPath)' '\(path)' 2>&1")
        if cpResult.exitCode != 0 {
            log("❌ 覆盖二进制失败 (cp exit=\(cpResult.exitCode)): \(cpResult.stdout)")
            throw InjectError.patchFailed("cp exit=\(cpResult.exitCode): \(cpResult.stdout)")
        }
        _ = runShellCommand("chmod 755 '\(path)' 2>&1")
    }

    // MARK: - 私有

    private static func patchFatBinary(data: inout Data, dylibLoadPath: String) throws {
        let isSwapped = (readU32(data: data, offset: 0) == 0xBEBAFECA)
        let narch = readU32(data: data, offset: 4, swapped: isSwapped)

        // 遍历 fat_arch 找 arm64 切片
        var foundArm64 = false
        for i in 0..<Int(narch) {
            let archOffset = 8 + i * 20
            let cputype = readU32(data: data, offset: archOffset + 4, swapped: isSwapped)
            if cputype == 0x0100000C { // CPU_TYPE_ARM64
                let sliceOffset = Int(readU32(data: data, offset: archOffset + 8, swapped: isSwapped))
                let sliceSize   = Int(readU32(data: data, offset: archOffset + 12, swapped: isSwapped))
                // 切片数据从 sliceOffset 开始
                var sliceData = data.subdata(in: sliceOffset..<sliceOffset + sliceSize)
                try patchMachO64(data: &sliceData, at: 0, dylibLoadPath: dylibLoadPath)

                // 对齐到页大小（0x4000）
                let aligned = ((sliceData.count + 0x3FFF) / 0x4000) * 0x4000
                if aligned > sliceData.count {
                    sliceData.append(Data(repeating: 0, count: aligned - sliceData.count))
                }

                // 替换原切片 + 更新 fat_arch size
                data.replaceSubrange(sliceOffset..<sliceOffset + sliceSize, with: sliceData)
                let newSliceSize = UInt32(aligned)
                writeU32(data: &data, offset: archOffset + 12, value: newSliceSize, swapped: isSwapped)
                foundArm64 = true
            }
        }

        guard foundArm64 else { throw InjectError.noArm64Slice }
    }

    private static func patchMachO64(data: inout Data, at baseOffset: Int, dylibLoadPath: String) throws {
        let magic = readU32(data: data, offset: baseOffset)
        let isSwapped = (magic == MH_CIGAM_64)

        var ncmds      = readU32(data: data, offset: baseOffset + 16, swapped: isSwapped)
        var sizeofcmds = readU32(data: data, offset: baseOffset + 20, swapped: isSwapped)

        // ------ 遍历 load commands ------
        var offset = baseOffset + 32 // sizeof mach_header_64
        var codeSigCmdOffset: Int? = nil

        for _ in 0..<Int(ncmds) {
            let lcCmd  = readU32(data: data, offset: offset, swapped: isSwapped)
            let lcSize = readU32(data: data, offset: offset + 4, swapped: isSwapped)

            if lcCmd == LC_CODE_SIGNATURE {
                codeSigCmdOffset = offset
            }

            offset += Int(lcSize)
        }

        let endOfLC = offset // 当前所有 load commands 结束位置

        // ------ 去除代码签名 ------
        if let sigOffset = codeSigCmdOffset {
            // 把 LC_CODE_SIGNATURE 的 cmd 设为 0（使内核忽略）
            writeU32(data: &data, offset: sigOffset, value: 0, swapped: isSwapped)
        }

        // ------ 构建 LC_LOAD_DYLIB ------
        let pathBytes  = Array(dylibLoadPath.utf8) + [0]
        let cmdSizeRaw = 24 + pathBytes.count   // sizeof(dylib_command) + path+'\0'
        let cmdSize    = ((cmdSizeRaw + 7) / 8) * 8  // 8 字节对齐

        var cmdData = Data(capacity: cmdSize)
        // cmd
        appendU32(to: &cmdData, value: LC_LOAD_DYLIB, swapped: isSwapped)
        // cmdsize
        appendU32(to: &cmdData, value: UInt32(cmdSize), swapped: isSwapped)
        // dylib.name_offset (always 24)
        appendU32(to: &cmdData, value: 24, swapped: isSwapped)
        // dylib.timestamp
        appendU32(to: &cmdData, value: 2, swapped: isSwapped)
        // dylib.current_version / compatibility_version
        appendU32(to: &cmdData, value: 0x00010000, swapped: isSwapped)
        appendU32(to: &cmdData, value: 0x00010000, swapped: isSwapped)
        // path string + padding
        cmdData.append(contentsOf: pathBytes)
        if cmdData.count < cmdSize {
            cmdData.append(Data(repeating: 0, count: cmdSize - cmdData.count))
        }

        // ------ 插入新 load command ------
        data.insert(contentsOf: cmdData, at: endOfLC)

        // ------ 更新 header ------
        ncmds      += 1
        sizeofcmds += UInt32(cmdSize)
        writeU32(data: &data, offset: baseOffset + 16, value: ncmds, swapped: isSwapped)
        writeU32(data: &data, offset: baseOffset + 20, value: sizeofcmds, swapped: isSwapped)
    }

    // MARK: - 辅助检测

    private static func hasDylibLoadCommand(at path: String, dylibName: String) -> Bool {
        guard let handle = fopen(path, "rb") else { return false }
        defer { fclose(handle) }

        var magic: UInt32 = 0
        guard fread(&magic, 4, 1, handle) == 1 else { return false }

        // 跳过 fat 头部
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            let isSwapped = (magic == 0xBEBAFECA)
            var nfat: UInt32 = 0
            fseeko(handle, 4, SEEK_SET)
            guard fread(&nfat, 4, 1, handle) == 1 else { return false }
            if isSwapped { nfat = nfat.byteSwapped }
            // 找 arm64 切片
            var found = false
            for i in 0..<Int(nfat) {
                fseeko(handle, off_t(8 + i * 20 + 4), SEEK_SET)
                var cpu: UInt32 = 0
                guard fread(&cpu, 4, 1, handle) == 1 else { continue }
                if isSwapped { cpu = cpu.byteSwapped }
                if cpu == 0x0100000C {
                    fseeko(handle, off_t(8 + i * 20 + 8), SEEK_SET)
                    var off: UInt32 = 0
                    guard fread(&off, 4, 1, handle) == 1 else { continue }
                    if isSwapped { off = off.byteSwapped }
                    fseeko(handle, off_t(off), SEEK_SET)
                    var m: UInt32 = 0
                    guard fread(&m, 4, 1, handle) == 1 else { continue }
                    magic = m
                    found = true
                    break
                }
            }
            guard found else { return false }
        }

        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { return false }
        let isSwapped = (magic == MH_CIGAM_64)

        // 读取 ncmds / sizeofcmds
        var header: [UInt32] = [0, 0, 0, 0]
        fseeko(handle, 12, SEEK_CUR)
        guard fread(&header, 4 * 4, 1, handle) == 1 else { return false }
        // header[0]=filetype, header[1]=ncmds, header[2]=sizeofcmds, header[3]=flags
        let ncmds = isSwapped ? header[1].byteSwapped : header[1]
        var lcOff = off_t(32) // skip mach_header_64

        for _ in 0..<Int(ncmds) {
            fseeko(handle, lcOff, SEEK_SET)
            var lc: [UInt32] = [0, 0]
            guard fread(&lc, 8, 1, handle) == 1 else { break }
            let cmd  = isSwapped ? lc[0].byteSwapped : lc[0]
            let size = isSwapped ? lc[1].byteSwapped : lc[1]

            if cmd == LC_LOAD_DYLIB {
                // 读取整个 load command
                fseeko(handle, lcOff, SEEK_SET)
                var buf = [UInt8](repeating: 0, count: Int(size))
                guard fread(&buf, buf.count, 1, handle) == 1 else { continue }
                // name_offset at bytes 12-15
                let no = readU32(buf: buf, offset: 12, swapped: isSwapped)
                if no < size {
                    let nb = Array(buf[Int(no)...]).prefix(while: { $0 != 0 })
                    if let name = String(bytes: nb, encoding: .utf8), name.contains(dylibName) {
                        return true
                    }
                }
            }
            lcOff += off_t(size)
        }
        return false
    }

    // MARK: - 小端读写

    private static func readU32(data: Data, offset: Int, swapped: Bool = false) -> UInt32 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return swapped ? v.byteSwapped : v
    }

    private static func readU32(buf: [UInt8], offset: Int, swapped: Bool = false) -> UInt32 {
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { ptr in
            ptr.copyBytes(from: buf[offset..<offset+4])
        }
        return swapped ? v.byteSwapped : v
    }

    private static func writeU32(data: inout Data, offset: Int, value: UInt32, swapped: Bool) {
        let v = swapped ? value.byteSwapped : value
        data.replaceSubrange(offset..<offset+4, with: Swift.withUnsafeBytes(of: v) { Data($0) })
    }

    private static func appendU32(to data: inout Data, value: UInt32, swapped: Bool) {
        let v = swapped ? value.byteSwapped : value
        data.append(contentsOf: Swift.withUnsafeBytes(of: v) { Array($0) })
    }

    // MARK: - 错误类型

    enum InjectError: Error, CustomStringConvertible {
        case dylibNotFound
        case alreadyInjected
        case binaryNotReadable
        case cantCreateFrameworks(String)
        case cantCopyDylib(String)
        case patchFailed(String)
        case invalidBinary
        case noArm64Slice
        case noBackup
        case restoreFailed(String)

        var description: String {
            switch self {
            case .dylibNotFound:       return "内嵌 dylib 未找到，请重新构建 IPA"
            case .alreadyInjected:     return "已注入过，无需重复操作"
            case .binaryNotReadable:    return "目标 App 二进制不可读（权限不足）"
            case .cantCreateFrameworks(let s): return "无法创建 Frameworks 目录: \(s)"
            case .cantCopyDylib(let s): return "无法复制 dylib: \(s)"
            case .patchFailed(let s):   return "二进制修补失败: \(s)"
            case .invalidBinary:        return "无法识别 App 二进制格式"
            case .noArm64Slice:         return "Fat binary 中未找到 arm64 切片"
            case .noBackup:             return "未找到注入前备份，无法恢复"
            case .restoreFailed(let s): return "恢复失败: \(s)"
            }
        }
    }
}

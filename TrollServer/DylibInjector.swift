import Foundation
import UIKit
import zlib


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

    /// 判断某 App 是否已注入（通过检查二进制中的 LC_LOAD_DYLIB）
    static func isInjected(appPath: String) -> Bool {
        let execName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let binaryPath = "\(appPath)/\(execName)"
        return hasDylibLoadCommand(at: binaryPath, dylibName: dylibName)
    }

    // MARK: - 生成已注入的 IPA

    /// 在 TrollServer 临时目录中复制 App → 注入 dylib → 打包 IPA
    /// 返回 IPA 文件的本地 URL，可通过 TrollStore 安装
    static func generateInjectedIPA(appPath: String) -> Result<URL, InjectError> {
        let fm = FileManager.default
        let execName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let appName = (appPath as NSString).lastPathComponent
        let binaryPath = "\(appPath)/\(execName)"
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

        // 检查是否已注入（扫描原始二进制）
        if hasDylibLoadCommand(at: binaryPath, dylibName: dylibName) {
            log("⚠️ \(execName) 已注入过")
            return .failure(.alreadyInjected)
        }

        // 1. 创建临时工作目录
        let uuid = UUID().uuidString
        let tmpDir = NSTemporaryDirectory() + "trollserver_inject_\(uuid)"
        let fmURL = URL(fileURLWithPath: tmpDir)
        do {
            try fm.createDirectory(at: fmURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            log("❌ 创建临时目录失败: \(error)")
            return .failure(.cantCreateTempDir("\(error)"))
        }
        log("📁 临时目录: \(tmpDir)")

        // 2. 复制整个 App Bundle 到临时目录（沙盒内可写自己的 tmp）
        let tmpAppPath = "\(tmpDir)/\(appName)"
        do {
            try fm.copyItem(atPath: appPath, toPath: tmpAppPath)
            log("✅ 已复制 App Bundle 到临时目录")
        } catch {
            log("❌ 复制 App Bundle 失败: \(error)")
            return .failure(.cantCopyApp("\(error)"))
        }

        let tmpBinaryPath = "\(tmpAppPath)/\(execName)"
        let tmpFrameworksPath = "\(tmpAppPath)/Frameworks"
        let tmpDylibDestPath = "\(tmpFrameworksPath)/\(dylibName)"

        // 3. 创建 Frameworks 目录
        if !fm.fileExists(atPath: tmpFrameworksPath) {
            do {
                try fm.createDirectory(atPath: tmpFrameworksPath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            } catch {
                log("❌ 创建 Frameworks 目录失败: \(error)")
                return .failure(.cantCreateFrameworks("\(error)"))
            }
        }

        // 4. 复制 dylib 到临时 App
        do {
            try fm.copyItem(atPath: dylibSrc, toPath: tmpDylibDestPath)
        } catch {
            log("❌ 复制 dylib 失败: \(error)")
            return .failure(.cantCopyDylib("\(error)"))
        }
        chmod(tmpDylibDestPath, 0o755)
        log("✅ dylib 已复制到临时 App")

        // 5. 在临时目录中修补 Mach-O 二进制
        do {
            try patchMachO(at: tmpBinaryPath, dylibLoadPath: loadPath)
            log("✅ 二进制已修补")
        } catch let e as InjectError {
            log("❌ 修补失败: \(e)")
            return .failure(e)
        } catch {
            log("❌ 修补失败: \(error)")
            return .failure(.patchFailed("\(error)"))
        }

        // 6. 去除代码签名（用 ldid 或 codesign）
        let signResult = runShellCommand("/usr/bin/ldid -S '\(tmpBinaryPath)' 2>&1")
        if signResult.exitCode == 0 {
            log("✅ ldid 重签成功")
        } else {
            log("⚠️ ldid 重签返回 exit=\(signResult.exitCode)（可能不影响 TrollStore 安装）")
        }

        // 7. 创建 Payload 目录并放入 .app
        let payloadDir = "\(tmpDir)/Payload"
        do {
            try fm.createDirectory(atPath: payloadDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            log("❌ 创建 Payload 目录失败: \(error)")
            return .failure(.packFailed("创建 Payload 失败: \(error)"))
        }
        do {
            try fm.moveItem(atPath: tmpAppPath, toPath: "\(payloadDir)/\(appName)")
        } catch {
            log("❌ 移动 App 到 Payload 失败: \(error)")
            return .failure(.packFailed("移动 App 失败: \(error)"))
        }

        // 8. 打包为 IPA — 使用 Swift 实现 ZIP 格式，不依赖外部 zip 命令
        let ipaPath = "\(tmpDir)/\(execName)_injected.ipa"
        do {
            try createZipArchive(from: payloadDir, to: ipaPath)
            log("✅ IPA 已打包: \(ipaPath)")
            return .success(URL(fileURLWithPath: ipaPath))
        } catch {
            log("❌ 打包 IPA 失败: \(error)")
            return .failure(.packFailed("\(error)"))
        }
    }

    // MARK: - ZIP 创建器（纯 Swift，不依赖 /usr/bin/zip）

    private static func createZipArchive(from sourceDir: String, to zipPath: String) throws {
        let fm = FileManager.default
        let zipURL = URL(fileURLWithPath: zipPath)
        try Data().write(to: zipURL)
        let fh = try FileHandle(forWritingTo: zipURL)
        defer { try? fh.closeFile() }

        var entries: [(name: String, size: UInt32, crc: UInt32, offset: UInt32, isDir: Bool)] = []

        // 写入 Payload 目录条目（ZIP 根目录必须包含 Payload/）
        let payloadEntryName = "Payload/"
        let payloadEntryData = payloadEntryName.data(using: .utf8) ?? Data()
        let payloadEntryLen = UInt16(payloadEntryData.count)
        let payloadOffset = UInt32(try fh.offsetInFile)
        try writeLocalFileHeader(fh: fh, name: payloadEntryData, nameLen: payloadEntryLen, crc: 0, size: 0, flags: 0)
        entries.append((name: payloadEntryName, size: 0, crc: 0, offset: payloadOffset, isDir: true))

        func traverse(dir: String, prefix: String) throws {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for item in items {
                let path = "\(dir)/\(item)"
                let name = prefix + "/" + item
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)

                let nameData = name.data(using: .utf8) ?? Data()
                let nameLen = UInt16(nameData.count)
                let offset = UInt32(try fh.offsetInFile)

                if isDir.boolValue {
                    // 目录条目必须以 "/" 结尾
                    let dirName = name + "/"
                    let dirNameData = dirName.data(using: .utf8) ?? Data()
                    let dirNameLen = UInt16(dirNameData.count)
                    try writeLocalFileHeader(fh: fh, name: dirNameData, nameLen: dirNameLen, crc: 0, size: 0, flags: 0)
                    entries.append((name: dirName, size: 0, crc: 0, offset: offset, isDir: true))
                    try traverse(dir: path, prefix: name)
                } else {
                    let (crc, size) = try writeFileEntry(fh: fh, sourcePath: path, name: nameData, nameLen: nameLen)
                    entries.append((name: name, size: size, crc: crc, offset: offset, isDir: false))
                }
            }
        }

        try traverse(dir: sourceDir, prefix: "Payload")

        let cdOffset = UInt32(try fh.offsetInFile)
        for entry in entries {
            let nameData = entry.name.data(using: .utf8) ?? Data()
            let nameLen = UInt16(nameData.count)
            try fh.write(contentsOf: Data([0x50, 0x4B, 0x01, 0x02]))
            try fh.write(contentsOf: u16(0x0314))
            try fh.write(contentsOf: u16(0x0014))
            try fh.write(contentsOf: u16(entry.isDir ? 0x0000 : 0x0008))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u32(entry.crc))
            try fh.write(contentsOf: u32(entry.size))
            try fh.write(contentsOf: u32(entry.size))
            try fh.write(contentsOf: u16(nameLen))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u16(0x0000))
            try fh.write(contentsOf: u32(entry.isDir ? 0x41ED0000 : 0x81A40000))
            try fh.write(contentsOf: u32(entry.offset))
            try fh.write(contentsOf: nameData)
        }

        let cdSize = UInt32(try fh.offsetInFile) - cdOffset
        let numEntries = UInt16(entries.count)
        try fh.write(contentsOf: Data([0x50, 0x4B, 0x05, 0x06]))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: u16(numEntries))
        try fh.write(contentsOf: u16(numEntries))
        try fh.write(contentsOf: u32(cdSize))
        try fh.write(contentsOf: u32(cdOffset))
        try fh.write(contentsOf: u16(0x0000))
    }

    private static func writeLocalFileHeader(fh: FileHandle, name: Data, nameLen: UInt16, crc: UInt32, size: UInt32, flags: UInt16) throws {
        try fh.write(contentsOf: Data([0x50, 0x4B, 0x03, 0x04]))
        try fh.write(contentsOf: u16(0x0014))
        try fh.write(contentsOf: u16(flags))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: u32(crc))
        try fh.write(contentsOf: u32(size))
        try fh.write(contentsOf: u32(size))
        try fh.write(contentsOf: u16(nameLen))
        try fh.write(contentsOf: u16(0x0000))
        try fh.write(contentsOf: name)
    }

    private static func writeFileEntry(fh: FileHandle, sourcePath: String, name: Data, nameLen: UInt16) throws -> (crc: UInt32, size: UInt32) {
        try writeLocalFileHeader(fh: fh, name: name, nameLen: nameLen, crc: 0, size: 0, flags: 0x0008)
        guard let sourceFH = try? FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath)) else { return (0, 0) }
        defer { try? sourceFH.closeFile() }

        var crc: CUnsignedLong = 0
        var size: UInt32 = 0
        while true {
            let chunk = sourceFH.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { bytes in
                if let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress {
                    crc = zlib.crc32(crc, baseAddress, CUnsignedInt(chunk.count))
                }
            }
            try fh.write(contentsOf: chunk)
            size += UInt32(chunk.count)
        }

        try fh.write(contentsOf: u32(UInt32(crc)))
        try fh.write(contentsOf: u32(size))
        try fh.write(contentsOf: u32(size))
        return (UInt32(crc), size)
    }

    private static func u16(_ value: UInt16) -> Data {
        return Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func u32(_ value: UInt32) -> Data {
        return Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    // MARK: - TrollStore 安装

    /// 通过 TrollStore URL scheme 安装 IPA，若无法跳转则通过系统分享
    static func openTrollStoreInstall(appURL: URL) {
        // 如果是 IPA 文件，先尝试 trollstore:// URL scheme
        if appURL.pathExtension == "ipa" {
            let encodedPath = appURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "trollstore://install?url=\(encodedPath)"),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }

        // 备选：分享 .app 目录或 IPA 文件，用户在分享菜单中选择 TrollStore
        let activityVC = UIActivityViewController(activityItems: [appURL], applicationActivities: nil)
        if let root = UIApplication.shared.keyWindow?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }

    // MARK: - Mach-O 修补

    /// 在 Fat/单架构 Mach-O 中注入 LC_LOAD_DYLIB，并去除 LC_CODE_SIGNATURE
    static func patchMachO(at path: String, dylibLoadPath: String) throws {
        let url = URL(fileURLWithPath: path)
        var data = try Data(contentsOf: url)

        guard data.count >= 4 else { throw InjectError.invalidBinary }

        let magic = readU32(data: data, offset: 0)
        if magic == MH_MAGIC_64 || magic == MH_CIGAM_64 {
            try patchMachO64(data: &data, at: 0, dylibLoadPath: dylibLoadPath)
        } else if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            try patchFatBinary(data: &data, dylibLoadPath: dylibLoadPath)
        } else {
            throw InjectError.invalidBinary
        }

        try data.write(to: url)
    }

    private static func patchFatBinary(data: inout Data, dylibLoadPath: String) throws {
        let isSwapped = (readU32(data: data, offset: 0) == 0xBEBAFECA)
        let narch = readU32(data: data, offset: 4, swapped: isSwapped)

        var foundArm64 = false
        for i in 0..<Int(narch) {
            let archOffset = 8 + i * 20
            let cputype = readU32(data: data, offset: archOffset + 4, swapped: isSwapped)
            if cputype == 0x0100000C { // CPU_TYPE_ARM64
                let sliceOffset = Int(readU32(data: data, offset: archOffset + 8, swapped: isSwapped))
                let sliceSize   = Int(readU32(data: data, offset: archOffset + 12, swapped: isSwapped))
                var sliceData = data.subdata(in: sliceOffset..<sliceOffset + sliceSize)
                try patchMachO64(data: &sliceData, at: 0, dylibLoadPath: dylibLoadPath)

                let aligned = ((sliceData.count + 0x3FFF) / 0x4000) * 0x4000
                if aligned > sliceData.count {
                    sliceData.append(Data(repeating: 0, count: aligned - sliceData.count))
                }

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

        var offset = baseOffset + 32
        var codeSigCmdOffset: Int? = nil

        for _ in 0..<Int(ncmds) {
            let lcCmd  = readU32(data: data, offset: offset, swapped: isSwapped)
            let lcSize = readU32(data: data, offset: offset + 4, swapped: isSwapped)
            if lcCmd == LC_CODE_SIGNATURE {
                codeSigCmdOffset = offset
            }
            offset += Int(lcSize)
        }

        let endOfLC = offset

        if let sigOffset = codeSigCmdOffset {
            writeU32(data: &data, offset: sigOffset, value: 0, swapped: isSwapped)
        }

        let pathBytes  = Array(dylibLoadPath.utf8) + [0]
        let cmdSizeRaw = 24 + pathBytes.count
        let cmdSize    = ((cmdSizeRaw + 7) / 8) * 8

        var cmdData = Data(capacity: cmdSize)
        appendU32(to: &cmdData, value: LC_LOAD_DYLIB, swapped: isSwapped)
        appendU32(to: &cmdData, value: UInt32(cmdSize), swapped: isSwapped)
        appendU32(to: &cmdData, value: 24, swapped: isSwapped)
        appendU32(to: &cmdData, value: 2, swapped: isSwapped)
        appendU32(to: &cmdData, value: 0x00010000, swapped: isSwapped)
        appendU32(to: &cmdData, value: 0x00010000, swapped: isSwapped)
        cmdData.append(contentsOf: pathBytes)
        if cmdData.count < cmdSize {
            cmdData.append(Data(repeating: 0, count: cmdSize - cmdData.count))
        }

        data.insert(contentsOf: cmdData, at: endOfLC)

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

        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            let isSwapped = (magic == 0xBEBAFECA)
            var nfat: UInt32 = 0
            fseeko(handle, 4, SEEK_SET)
            guard fread(&nfat, 4, 1, handle) == 1 else { return false }
            if isSwapped { nfat = nfat.byteSwapped }
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

        var header: [UInt32] = [0, 0, 0, 0]
        fseeko(handle, 12, SEEK_CUR)
        guard fread(&header, 4 * 4, 1, handle) == 1 else { return false }
        let ncmds = isSwapped ? header[1].byteSwapped : header[1]
        var lcOff = off_t(32)

        for _ in 0..<Int(ncmds) {
            fseeko(handle, lcOff, SEEK_SET)
            var lc: [UInt32] = [0, 0]
            guard fread(&lc, 8, 1, handle) == 1 else { break }
            let cmd  = isSwapped ? lc[0].byteSwapped : lc[0]
            let size = isSwapped ? lc[1].byteSwapped : lc[1]

            if cmd == LC_LOAD_DYLIB {
                fseeko(handle, lcOff, SEEK_SET)
                var buf = [UInt8](repeating: 0, count: Int(size))
                guard fread(&buf, buf.count, 1, handle) == 1 else { continue }
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
        case cantCreateTempDir(String)
        case cantCopyApp(String)
        case cantCreateFrameworks(String)
        case cantCopyDylib(String)
        case patchFailed(String)
        case invalidBinary
        case noArm64Slice
        case packFailed(String)

        var description: String {
            switch self {
            case .dylibNotFound:       return "内嵌 dylib 未找到，请重新构建 IPA"
            case .alreadyInjected:     return "已注入过，无需重复操作"
            case .cantCreateTempDir(let s): return "无法创建临时目录: \(s)"
            case .cantCopyApp(let s):  return "无法复制 App Bundle: \(s)"
            case .cantCreateFrameworks(let s): return "无法创建 Frameworks 目录: \(s)"
            case .cantCopyDylib(let s): return "无法复制 dylib: \(s)"
            case .patchFailed(let s):   return "二进制修补失败: \(s)"
            case .invalidBinary:        return "无法识别 App 二进制格式"
            case .noArm64Slice:         return "Fat binary 中未找到 arm64 切片"
            case .packFailed(let s):    return "IPA 打包失败: \(s)"
            }
        }
    }
}

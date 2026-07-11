import Foundation

/// 一键修改 MobileGestalt 伪装 iPad（Go 方案直译）
///
/// 直接读写 com.apple.MobileGestalt.plist 的 CacheExtra 字段，
/// 写入特定 iPad 标识键，不破坏系统原有结构。
/// 路径通过 discoverGestaltPlist() 动态探测（iOS 14~17 兼容）。
/// TrollStore 下具备完整读写权限即可直接生效。
enum MobileGestalt {

    // MARK: - 路径

    /// 动态定位 MobileGestalt.plist（复用 discoverGestaltPlist 多路径探测）
    static func resolvePlistPath() throws -> String {
        guard let path = discoverGestaltPlist() else {
            throw NSError(domain: "MobileGestalt", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "未找到 com.apple.MobileGestalt.plist，系统可能不支持或沙盒受限"])
        }
        return path
    }

    /// 备份路径（基于实际命中路径）
    static func backupPath(for mgPath: String) -> String { mgPath + ".backup" }

    // MARK: - iPad 伪装字段（CacheExtra 内写入）

    static let ipadFields: [String: Any] = [
        "ProductType":              "iPad14,2",
        "DeviceClass":              "iPad",
        "SupportsiPad":             true,
        "qeaj75wk3HF4DwQ8qbIi7g":   Int64(1),
        "Z/dqyWS6OZTRy10UcmUAhw":   "iPad Pro 12.9-inch (6th generation)",
    ]

    // MARK: - 读取

    /// 读取完整 plist（二进制格式，指定路径）
    static func readPlist(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "MobileGestalt", code: 1, userInfo: [NSLocalizedDescriptionKey: "根节点不是字典"])
        }
        return root
    }

    // MARK: - 写入

    // MARK: - 日志

    static let logPath = "/var/mobile/Library/Logs/trollserver.log"

    static func log(_ msg: String) {
        let line = "[\(Date())] [MobileGestalt] \(msg)\n"
        print(line, terminator: "")
        try? line.data(using: .utf8)?.appendTo(file: logPath)
    }

    // MARK: - 写入

    /// 写入二进制 plist（指定路径）
    /// 多级容错：setuid(0) 提权 → chmod → FileHandle → /tmp + cp -f → Data.write
    static func writePlist(_ dict: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let fm = FileManager.default
        var reasons: [String] = []

        // 0) 尝试 setuid(0) 提权（TrollStore 越狱环境常见有效）
        let origUid = getuid()
        let origGid = getgid()
        let setuidOk = (setuid(0) == 0)
        let setgidOk = (setgid(0) == 0)
        log("setuid(0)=\(setuidOk)(was=\(origUid)), setgid(0)=\(setgidOk)(was=\(origGid))")

        defer {
            if setuidOk { _ = setuid(origUid) }
            if setgidOk { _ = setgid(origGid) }
        }

        // 1) 尝试 chmod 获取文件写权限
        let chmodResult = runShellCommand("chmod 666 \(path) 2>/dev/null; echo $?")
        let chmodExit = Int(chmodResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        log("chmod 666 exit=\(chmodExit) (raw=\(chmodResult.stdout))")
        if chmodExit != 0 {
            reasons.append("chmod 666 失败(退出码=\(chmodExit))")
        }

        // 2) FileHandle 直接覆盖
        if fm.isWritableFile(atPath: path) {
            do {
                let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try fh.truncateFile(atOffset: 0)
                try fh.write(contentsOf: data)
                try fh.close()
                log("✅ FileHandle 写入成功")
                return
            } catch {
                log("FileHandle 写入失败: \(error)")
                reasons.append("FileHandle: \(error.localizedDescription)")
            }
        } else {
            log("isWritableFile=false")
            reasons.append("isWritableFile=false")
        }

        // 3) /tmp + cp -f 覆盖
        let tmpPath = "/tmp/MobileGestalt_\(Int.random(in: 1000...9999)).plist"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            let cpResult = runShellCommand("cp -f \(tmpPath) \(path) 2>&1; echo \"?$\"")
            try? fm.removeItem(atPath: tmpPath)
            let cpOut = cpResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if cpOut.contains("?$0") || cpOut.isEmpty {
                log("✅ cp -f 覆盖成功")
                return
            }
            log("cp -f 失败: exit=\(cpResult.exitCode) out=\(cpOut)")
            reasons.append("cp -f: \(cpOut)")
        } catch {
            log("/tmp 写入失败: \(error)")
            reasons.append("/tmp: \(error.localizedDescription)")
        }

        // 4) 直接 Data.write 兜底
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [])
            log("✅ Data.write 成功")
            return
        } catch {
            log("Data.write 失败: \(error)")
            reasons.append("Data.write: \(error.localizedDescription)")
        }

        // 全部失败，返回详细原因
        let detail = reasons.joined(separator: "; ")
        log("❌ 所有写入策略均失败: \(detail)")
        throw NSError(domain: "MobileGestalt", code: 3,
                      userInfo: [NSLocalizedDescriptionKey:
                        "无法写入系统 MobileGestalt.plist。\n失败原因: \(detail)\n\n请检查:\n1) TrollStore 是否已开启'持久化/以 root 运行'\n2) 系统版本是否受支持\n3) 日志: \(logPath)"])
    }

    // MARK: - 备份 / 恢复

    /// 首次备份（仅在备份文件不存在时执行）
    static func backupIfNeeded(mgPath: String) {
        let bkPath = backupPath(for: mgPath)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: bkPath) else { return }
        try? fm.copyItem(atPath: mgPath, toPath: bkPath)
        print("[MobileGestalt] 💾 已备份 → \(bkPath)")
    }

    /// 从备份恢复原始 plist
    static func restoreFromBackup(mgPath: String) throws {
        let bkPath = backupPath(for: mgPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: bkPath) else {
            throw NSError(domain: "MobileGestalt", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "备份文件不存在，无法恢复"])
        }
        try fm.removeItem(atPath: mgPath)
        try fm.copyItem(atPath: bkPath, toPath: mgPath)
        print("[MobileGestalt] 🔄 已从备份恢复原始文件")
    }

    // MARK: - 开启 iPad 模式

    @discardableResult
    static func enableIPadMode(productType: String = "iPad14,2",
                                marketingName: String = "iPad Pro 12.9-inch (6th generation)") -> Result<String, Error> {
        do {
            let mgPath = try resolvePlistPath()
            backupIfNeeded(mgPath: mgPath)

            var root = try readPlist(at: mgPath)

            // 获取或创建 CacheExtra
            var cacheExtra = root["CacheExtra"] as? [String: Any] ?? [:]

            // 写入 iPad 字段
            var fields = ipadFields
            fields["ProductType"] = productType
            fields["Z/dqyWS6OZTRy10UcmUAhw"] = marketingName
            for (k, v) in fields {
                cacheExtra[k] = v
            }

            root["CacheExtra"] = cacheExtra
            try writePlist(root, to: mgPath)

            // 刷新缓存
            _ = runShellCommandSimple("/usr/bin/killall -HUP cfprefsd 2>/dev/null || true")

            let msg = "✅ 已伪装为 iPad (\(productType))"
            print("[MobileGestalt] \(msg)")
            return .success(msg)
        } catch {
            print("[MobileGestalt] ❌ 开启失败: \(error)")
            return .failure(error)
        }
    }

    // MARK: - 关闭 iPad 模式（恢复）

    @discardableResult
    static func disableIPadMode() -> Result<String, Error> {
        do {
            let mgPath = try resolvePlistPath()
            backupIfNeeded(mgPath: mgPath)

            var root = try readPlist(at: mgPath)

            guard var cacheExtra = root["CacheExtra"] as? [String: Any] else {
                return .success("已是原始模式，无需恢复")
            }

            // 只删除我们写入的 iPad 伪装字段
            var removed = false
            for k in ipadFields.keys {
                if cacheExtra.removeValue(forKey: k) != nil {
                    removed = true
                }
            }

            guard removed else {
                return .success("已是原始模式，无需恢复")
            }

            root["CacheExtra"] = cacheExtra
            try writePlist(root, to: mgPath)

            _ = runShellCommandSimple("/usr/bin/killall -HUP cfprefsd 2>/dev/null || true")

            let msg = "✅ 已恢复原生 iPhone 模式"
            print("[MobileGestalt] \(msg)")
            return .success(msg)
        } catch {
            print("[MobileGestalt] ❌ 恢复失败: \(error)")
            return .failure(error)
        }
    }

    // MARK: - 型号映射

    /// 根据产品标识符获取展示名称（MarketingName）
    static func marketingName(for productType: String) -> String {
        let mapping: [String: String] = [
            "iPad14,2":  "iPad Pro 12.9-inch (6th generation)",
            "iPad14,3":  "iPad Pro 12.9-inch (5th generation)",
            "iPad13,1":  "iPad Air (4th generation)",
            "iPad13,16": "iPad Air (5th generation)",
            "iPad12,1":  "iPad (10th generation)",
            "iPad11,6":  "iPad (9th generation)",
            "iPad11,1":  "iPad mini (5th generation)",
            "iPad7,11":  "iPad (10.2-inch)",
        ]
        return mapping[productType] ?? "iPad Pro 12.9-inch (6th generation)"
    }

    // MARK: - 检查当前状态

    /// 读取当前是否处于 iPad 伪装模式（检查 CacheExtra 中是否有 iPad 标识）
    static func isIPadModeActive() -> Bool {
        guard let mgPath = try? resolvePlistPath(),
              let root = try? readPlist(at: mgPath),
              let cacheExtra = root["CacheExtra"] as? [String: Any] else {
            return false
        }
        return (cacheExtra["DeviceClass"] as? String) == "iPad"
    }

    /// 读取当前伪装的型号
    static func currentProductType() -> String? {
        guard let mgPath = try? resolvePlistPath(),
              let root = try? readPlist(at: mgPath),
              let cacheExtra = root["CacheExtra"] as? [String: Any] else {
            return nil
        }
        return cacheExtra["ProductType"] as? String
    }
}

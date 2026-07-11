import Foundation

/// 一键修改 MobileGestalt 伪装 iPad（Go 方案直译）
///
/// 直接读写 com.apple.MobileGestalt.plist 的 CacheExtra 字段，
/// 写入特定 iPad 标识键，不破坏系统原有结构。
/// TrollStore 下具备完整读写权限即可直接生效。
enum MobileGestalt {

    // MARK: - 路径

    /// iOS 14~17 固定缓存路径（TrollStore 可读写）
    static let mgPlistPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

    /// 备份路径
    static var backupPath: String { mgPlistPath + ".backup" }

    // MARK: - iPad 伪装字段（CacheExtra 内写入）

    static let ipadFields: [String: Any] = [
        "ProductType":              "iPad14,2",
        "DeviceClass":              "iPad",
        "SupportsiPad":             true,
        "qeaj75wk3HF4DwQ8qbIi7g":   Int64(1),
        "Z/dqyWS6OZTRy10UcmUAhw":   "iPad Pro 12.9-inch (6th generation)",
    ]

    // MARK: - 读取

    /// 读取完整 plist（二进制格式）
    static func readPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: mgPlistPath))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "MobileGestalt", code: 1, userInfo: [NSLocalizedDescriptionKey: "根节点不是字典"])
        }
        return root
    }

    // MARK: - 写入

    /// 写入二进制 plist
    static func writePlist(_ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: mgPlistPath), options: .atomic)
    }

    // MARK: - 备份 / 恢复

    /// 首次备份（仅在备份文件不存在时执行）
    static func backupIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backupPath) else { return }
        try? fm.copyItem(atPath: mgPlistPath, toPath: backupPath)
        print("[MobileGestalt] 💾 已备份 → \(backupPath)")
    }

    /// 从备份恢复原始 plist
    static func restoreFromBackup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else {
            throw NSError(domain: "MobileGestalt", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "备份文件不存在，无法恢复"])
        }
        try fm.removeItem(atPath: mgPlistPath)
        try fm.copyItem(atPath: backupPath, toPath: mgPlistPath)
        print("[MobileGestalt] 🔄 已从备份恢复原始文件")
    }

    // MARK: - 开启 iPad 模式

    @discardableResult
    static func enableIPadMode(productType: String = "iPad14,2",
                                marketingName: String = "iPad Pro 12.9-inch (6th generation)") -> Result<String, Error> {
        do {
            backupIfNeeded()

            var root = try readPlist()

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
            try writePlist(root)

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
            backupIfNeeded()

            var root = try readPlist()

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
            try writePlist(root)

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
        guard let root = try? readPlist(),
              let cacheExtra = root["CacheExtra"] as? [String: Any] else {
            return false
        }
        return (cacheExtra["DeviceClass"] as? String) == "iPad"
    }

    /// 读取当前伪装的型号
    static func currentProductType() -> String? {
        guard let root = try? readPlist(),
              let cacheExtra = root["CacheExtra"] as? [String: Any] else {
            return nil
        }
        return cacheExtra["ProductType"] as? String
    }
}

import Foundation

/// 与 libiPadSpoof.dylib 共享的伪装配置。
///
/// dylib 在 QQ / 微信进程内读取此配置，决定 Hook 时返回什么设备型号。
/// 只有“启用开关 + 目标型号”两项，保持极小、稳定、易解析（plist / JSON 均可）。
enum SpoofConfig {

    /// dylib 会按顺序尝试读取这些路径（第一个存在的生效）。
    /// 放在 /var/mobile/Library/Preferences 下：TrollServer（或 root daemon）
    /// 写入并 chmod 0644，即使 QQ/微信处于沙盒也能读取。
    static let filePaths: [String] = [
        "/var/mobile/Library/Preferences/com.trollserver.spoof.plist",
        "/var/mobile/.trollserver_spoof.plist",
    ]

    /// 默认注入型号（iPad Pro 11-inch 第三代，对应 iPad14,2）
    static let defaultProductType = "iPad14,2"

    static var isEnabled: Bool {
        get { (read()?["Enabled"] as? Bool) ?? false }
        set { var d = read() ?? [:] ; d["Enabled"] = newValue ; write(d) }
    }

    static var productType: String {
        get { (read()?["ProductType"] as? String) ?? defaultProductType }
        set { var d = read() ?? [:] ; d["ProductType"] = newValue ; write(d) }
    }

    static func read() -> [String: Any]? {
        for p in filePaths {
            if let d = NSDictionary(contentsOfFile: p) as? [String: Any] { return d }
        }
        return nil
    }

    static func write(_ dict: [String: Any]) {
        let payload = dict as NSDictionary
        for p in filePaths {
            payload.write(toFile: p, atomically: true)
            chmod(p, 0o644)
        }
    }

    /// 导出为 JSON，供 HTTP 端点 /api/spoof 返回给 dylib（沙盒读不到文件时的回退）。
    static func jsonData() -> Data {
        let d = read() ?? ["Enabled": false, "ProductType": defaultProductType]
        return (try? JSONSerialization.data(withJSONObject: d)) ?? Data()
    }
}

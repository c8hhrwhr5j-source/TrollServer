import Foundation

// ============================================================
//  文件系统操作 - 基于 FileManager 的安全文件读写
//  所有路径操作均以设定的基础目录为根，防止路径穿越
// ============================================================

class FileOperations {
    
    let basePath: String
    private let fm = FileManager.default
    
    init(basePath: String = "/var/mobile/Downloads") {
        self.basePath = (basePath as NSString).standardizingPath
    }
    
    // MARK: - 路径安全
    
    /// 将相对路径解析为完整路径，阻止 ../ 穿越攻击
    /// - Throws: FileError.pathTraversal 如果路径试图跳出基础目录
    func resolvePath(_ relativePath: String) throws -> String {
        // URL 解码（处理中文等被 percent-encode 的路径）
        let decodedPath = relativePath.removingPercentEncoding ?? relativePath
        
        // 去除开头的 /
        var cleanPath = decodedPath
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        
        // 兼容客户端直接发送完整路径（如 /var/mobile/Downloads/xxx），
        // 去除与 basePath 重叠的前缀，避免路径重复
        let baseRelative = basePath.hasPrefix("/") ? String(basePath.dropFirst()) : basePath
        if cleanPath.hasPrefix(baseRelative + "/") {
            cleanPath = String(cleanPath.dropFirst(baseRelative.count + 1))
        }
        
        let fullPath = (basePath as NSString).appendingPathComponent(cleanPath)
        let standardized = (fullPath as NSString).standardizingPath
        
        // 安全检查：确保未跳出基础目录
        guard standardized.hasPrefix(basePath) else {
            throw FileError.pathTraversal
        }
        
        return standardized
    }
    
    // MARK: - 读取
    
    /// 读取文件内容
    func readFile(at relativePath: String) throws -> Data {
        let fullPath = try resolvePath(relativePath)
        return try Data(contentsOf: URL(fileURLWithPath: fullPath))
    }
    
    /// 读取文件文本（UTF-8）
    func readTextFile(at relativePath: String) throws -> String {
        let data = try readFile(at: relativePath)
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // MARK: - 写入
    
    /// 写入文件（Data）
    func writeFile(_ data: Data, to relativePath: String) throws {
        let fullPath = try resolvePath(relativePath)
        let dir = (fullPath as NSString).deletingLastPathComponent
        
        // 确保父目录存在
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        }
        
        try data.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
    }
    
    /// 写入文件（String）
    func writeTextFile(_ text: String, to relativePath: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw FileError.encodingFailed
        }
        try writeFile(data, to: relativePath)
    }
    
    // MARK: - 目录操作
    
    /// 列出目录内容
    func listDirectory(_ relativePath: String = "") throws -> [String] {
        let fullPath = try resolvePath(relativePath)
        return try fm.contentsOfDirectory(atPath: fullPath)
    }
    
    /// 列目录（含详细信息）
    func listDirectoryDetailed(_ relativePath: String = "") throws -> [[String: Any]] {
        let fullPath = try resolvePath(relativePath)
        let names = try fm.contentsOfDirectory(atPath: fullPath)
        
        return names.compactMap { name in
            let itemPath = (fullPath as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: itemPath) else { return nil }
            
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            return [
                "name": name,
                "isDirectory": isDir,
                "size": attrs[.size] as? Int64 ?? 0,
                "modified": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            ]
        }
    }
    
    /// 创建目录（递归）
    func createDirectory(_ relativePath: String) throws {
        let fullPath = try resolvePath(relativePath)
        try fm.createDirectory(atPath: fullPath, withIntermediateDirectories: true, attributes: nil)
    }
    
    /// 删除文件或目录
    func deleteItem(_ relativePath: String) throws {
        let fullPath = try resolvePath(relativePath)
        try fm.removeItem(atPath: fullPath)
    }
    
    // MARK: - 查询
    
    /// 判断路径是否存在
    func exists(_ relativePath: String) -> Bool {
        guard let fullPath = try? resolvePath(relativePath) else { return false }
        return fm.fileExists(atPath: fullPath)
    }
    
    /// 判断是否为目录
    func isDirectory(_ relativePath: String) -> Bool {
        guard let fullPath = try? resolvePath(relativePath) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
    }
    
    /// 获取文件大小
    func fileSize(_ relativePath: String) -> Int64 {
        guard let fullPath = try? resolvePath(relativePath) else { return 0 }
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { return 0 }
        return (attrs[.size] as? Int64) ?? 0
    }
    
    // MARK: - 数据文件（设备状态数据 data.txt）
    
    /// 读取设备状态数据 key=value 格式
    func readDeviceData(appDir: String) -> [String: String] {
        let dataPath = "\(appDir)/data.txt"
        guard let content = try? readTextFile(at: dataPath) else { return [:] }
        
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "=")
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
    
    /// 写入设备状态数据
    func writeDeviceData(_ data: [String: String], appDir: String) throws {
        let lines = data.map { "\($0.key)=\($0.value)" }
        let content = lines.joined(separator: "\n")
        try writeTextFile(content, to: "\(appDir)/data.txt")
    }
}

enum FileError: Error {
    case encodingFailed
    case pathTraversal
    case notFound
}

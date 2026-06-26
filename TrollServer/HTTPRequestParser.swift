import Foundation

// ============================================================
//  轻量级 HTTP/1.1 请求解析器
//  解析标准 HTTP 请求，支持 WebDAV 方法
// ============================================================

struct HTTPRequest {
    let method: String          // GET, PUT, MKCOL, PROPFIND, DELETE
    let path: String            // /path/to/resource?query=value
    let pathWithoutQuery: String // /path/to/resource
    let queryParameters: [String: String]
    let headers: [String: String]
    let body: Data
    
    /// 从原始字节流解析 HTTP 请求（二进制安全版本）
    /// 关键修复：之前将整个 data（含二进制 body）尝试转 UTF-8 字符串会失败，
    /// 导致所有二进制文件 PUT 请求被误判为 "Bad Request"。
    /// 现在先通过原始字节找到 headers 边界，仅解析 headers 为 UTF-8，
    /// body 直接从原始 data 中按 Content-Length 截取。
    static func parse(from data: Data) -> HTTPRequest? {
        // 1. 在原始字节中定位 headers/body 边界 \r\n\r\n
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerEndIndex = separatorRange.lowerBound
        let bodyStartIndex = separatorRange.upperBound
        
        // 2. 仅将 headers 部分转为 UTF-8 字符串（headers 始终是 ASCII/UTF-8）
        let headerData = data.subdata(in: 0..<headerEndIndex)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return nil
        }
        
        // 3. 解析请求行: METHOD PATH HTTP/1.1
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }
        
        let method = requestParts[0].uppercased()
        let rawPath = requestParts.dropFirst().first ?? "/"
        
        // 4. 分离路径和查询参数，并做 URL 解码（支持中文目录名）
        let pathComponents = rawPath.components(separatedBy: "?")
        let rawPathOnly = pathComponents.first ?? "/"
        let pathWithoutQuery = rawPathOnly.removingPercentEncoding ?? rawPathOnly
        var queryParams: [String: String] = [:]
        
        if pathComponents.count > 1 {
            let queryString = pathComponents.dropFirst().joined(separator: "?")
            for pair in queryString.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                } else if kv.count == 1 {
                    queryParams[kv[0]] = ""
                }
            }
        }
        
        // 5. 解析 headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key.lowercased()] = value
        }
        
        // 6. 从原始 data 中按 Content-Length 提取 body（完全二进制安全）
        var body = Data()
        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr),
           contentLength > 0,
           bodyStartIndex < data.count {
            let actualEnd = min(bodyStartIndex + contentLength, data.count)
            body = data.subdata(in: bodyStartIndex..<actualEnd)
            
            if body.count != contentLength {
                print("[HTTP] Warning: body truncated (expected \(contentLength), got \(body.count))")
            }
        }
        
        return HTTPRequest(
            method: method,
            path: rawPath,
            pathWithoutQuery: pathWithoutQuery,
            queryParameters: queryParams,
            headers: headers,
            body: body
        )
    }
}

// ============================================================
//  HTTP 响应构建器
// ============================================================

struct HTTPResponse {
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data
    
    /// 序列化为 HTTP 响应字节流
    func serialize() -> Data {
        var response = Data()
        
        // 状态行
        let statusLine = "HTTP/1.1 \(statusCode) \(statusMessage)\r\n"
        response.append(statusLine.data(using: .utf8)!)
        
        // 响应头
        for (key, value) in headers {
            response.append("\(key): \(value)\r\n".data(using: .utf8)!)
        }
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        response.append("\r\n".data(using: .utf8)!)
        
        // 响应体
        response.append(body)
        
        return response
    }
    
    // MARK: - 工厂方法
    
    static func ok(body: Data = Data(), contentType: String = "text/plain") -> HTTPResponse {
        return HTTPResponse(statusCode: 200, statusMessage: "OK", headers: ["Content-Type": contentType], body: body)
    }
    
    static func okJson(_ jsonString: String) -> HTTPResponse {
        return ok(body: jsonString.data(using: .utf8)!, contentType: "application/json; charset=utf-8")
    }
    
    static func okText(_ text: String) -> HTTPResponse {
        return ok(body: text.data(using: .utf8)!, contentType: "text/plain; charset=utf-8")
    }
    
    static func created() -> HTTPResponse {
        return HTTPResponse(statusCode: 201, statusMessage: "Created", headers: [:], body: Data())
    }
    
    static func notFound(_ message: String = "Not Found") -> HTTPResponse {
        return HTTPResponse(statusCode: 404, statusMessage: "Not Found", headers: ["Content-Type": "text/plain"], body: message.data(using: .utf8)!)
    }
    
    static func methodNotAllowed() -> HTTPResponse {
        return HTTPResponse(statusCode: 405, statusMessage: "Method Not Allowed", headers: [:], body: Data())
    }
    
    static func internalServerError(_ message: String) -> HTTPResponse {
        return HTTPResponse(statusCode: 500, statusMessage: "Internal Server Error", headers: ["Content-Type": "text/plain"], body: message.data(using: .utf8)!)
    }
    
    static func multiStatus(_ xmlBody: String) -> HTTPResponse {
        return HTTPResponse(statusCode: 207, statusMessage: "Multi-Status", headers: ["Content-Type": "application/xml; charset=utf-8"], body: xmlBody.data(using: .utf8)!)
    }
}

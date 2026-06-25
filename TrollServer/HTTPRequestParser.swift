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
    
    /// 从原始字节流解析 HTTP 请求
    static func parse(from data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8) else { return nil }
        
        let parts = requestString.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else { return nil }
        
        let headerSection = parts[0]
        let bodyData: Data
        if parts.count > 1 {
            bodyData = parts.dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8) ?? Data()
        } else {
            bodyData = Data()
        }
        
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        
        // 解析请求行: METHOD PATH HTTP/1.1
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }
        
        let method = requestParts[0].uppercased()
        let rawPath = requestParts.dropFirst().first ?? "/"
        
        // 分离路径和查询参数
        let pathComponents = rawPath.components(separatedBy: "?")
        let pathWithoutQuery = pathComponents.first ?? "/"
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
        
        // 解析头部
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let separatorIndex = line.firstIndex(of: ":")
            guard let idx = separatorIndex else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key.lowercased()] = value
        }
        
        // 根据 Content-Length 读取 body 中的实际数据（二进制安全）
        var actualBody = bodyData
        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr),
           contentLength > 0 {
            // body 在 raw data 中: 找到 \r\n\r\n 分隔符后的二进制数据
            if let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) {
                let bodyStartIndex = separatorRange.upperBound
                if bodyStartIndex < data.count {
                    let rawBody = data.subdata(in: bodyStartIndex..<min(bodyStartIndex + contentLength, data.count))
                    if rawBody.count > 0 {
                        actualBody = rawBody
                    }
                }
            }
        }
        
        return HTTPRequest(
            method: method,
            path: rawPath,
            pathWithoutQuery: pathWithoutQuery,
            queryParameters: queryParams,
            headers: headers,
            body: actualBody
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

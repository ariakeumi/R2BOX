import CryptoKit
import Foundation

/// AWS Signature Version 4（S3 单次编码变体）。
/// 纯函数实现，可用 AWS 官方文档测试向量校验（见 Checker）。
public enum SigV4 {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private static let allowed: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )

    /// RFC3986 URI 编码。key path 段保留 "/"（encodeSlash=false），query 值全编码。
    public static func uriEncode(_ string: String, encodeSlash: Bool = true) -> String {
        var out = String()
        out.reserveCapacity(string.count)
        for byte in string.utf8 {
            if allowed.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else if byte == UInt8(ascii: "/") && !encodeSlash {
                out.append("/")
            } else {
                let hex = String(byte, radix: 16, uppercase: true)
                out.append("%" + (hex.count == 1 ? "0" + hex : hex))
            }
        }
        return out
    }

    /// 查询串：先编码、按 key 再 value 字典序排序、`k=v` 以 & 连接。
    public static func canonicalQuery(_ pairs: [(String, String)]) -> String {
        var encoded: [(String, String)] = []
        encoded.reserveCapacity(pairs.count)
        for pair in pairs {
            encoded.append((uriEncode(pair.0), uriEncode(pair.1)))
        }
        encoded.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        var out = String()
        for item in encoded {
            if !out.isEmpty { out += "&" }
            out += item.0 + "=" + item.1
        }
        return out
    }

    /// 规范 URI：逐段编码、保留 "/"。S3 使用单次编码。
    public static func canonicalURI(path: String) -> String {
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { uriEncode(String($0), encodeSlash: false) }
        return "/" + parts.joined(separator: "/")
    }

    /// 规范 host：非默认端口需带端口。
    public static func canonicalHost(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, port != 80, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }

    // MARK: - 哈希 / HMAC

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 分块流式计算文件 SHA256（不整载内存）。
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func signingKey(secretKey: String, dateScope: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(Data(("AWS4" + secretKey).utf8), Data(dateScope.utf8))
        let kRegion = hmacSHA256(kDate, Data(region.utf8))
        let kService = hmacSHA256(kRegion, Data(service.utf8))
        return hmacSHA256(kService, Data("aws4_request".utf8))
    }

    // MARK: - 时间

    public static func amzDate(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    public static func dateScope(from amzDate: String) -> String {
        String(amzDate.prefix(8))
    }

    // MARK: - 签名

    /// 计算 Authorization 头。extraHeaders 中除 host / x-amz-content-sha256 / x-amz-date
    /// 之外的头（如 range、if-match、x-amz-copy-source）都会纳入签名。
    /// - Parameter signContentHash: S3 必须签 x-amz-content-sha256（默认 true）。
    ///   非 S3 服务的官方向量（如 get-vanilla）只签 host;x-amz-date，传 false 复现。
    public static func authorization(
        accessKey: String,
        secretKey: String,
        region: String,
        method: String,
        url: URL,
        extraHeaders: [String: String],
        payloadHash: String,
        amzDate: String,
        dateScope: String,
        service: String = "s3",
        signContentHash: Bool = true
    ) -> String {
        let fixedNames: Set<String> = ["host", "x-amz-content-sha256", "x-amz-date"]
        var headerPairs: [(String, String)] = [
            ("host", canonicalHost(url)),
            ("x-amz-date", amzDate),
        ]
        if signContentHash {
            headerPairs.insert(("x-amz-content-sha256", payloadHash), at: 1)
        }
        for (name, value) in extraHeaders {
            let lower = name.lowercased()
            guard !fixedNames.contains(lower) else { continue }
            headerPairs.append((lower, value.trimmingCharacters(in: .whitespaces)))
        }
        headerPairs.sort { $0.0 < $1.0 }
        let signedHeaders = headerPairs.map(\.0).joined(separator: ";")
        let canonicalHeaders = headerPairs.map { "\($0.0):\($0.1)\n" }.joined()

        let canonicalQuery = canonicalQuery(urlQueryPairs(url))
        let canonicalRequest = [
            method,
            canonicalURI(path: url.path),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateScope)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let key = signingKey(secretKey: secretKey, dateScope: dateScope, region: region, service: service)
        let signature = hmacSHA256(key, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(signature)"
    }

    /// 从已编码 URL 还原 query 对（签名用）。
    public static func urlQueryPairs(_ url: URL) -> [(String, String)] {
        guard let query = url.query, !query.isEmpty else { return [] }
        return query.split(separator: "&").map { piece in
            let kv = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return (key, value)
        }
    }
}

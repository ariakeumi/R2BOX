import Foundation

/// 极简 S3 XML 响应解析（仅提取 R2BOX 用到的字段）。
/// S3 响应结构简单无嵌套同名标签，用字符串扫描而非 XMLParser，
/// 注意匹配标签时要求紧跟 `>`、空格或 `/` 以避免 <Key 误配 <KeyCount>。
public enum S3XML {
    // MARK: 基础

    /// 提取指定标签的首个文本内容（自动解 XML 实体）。
    static func element(_ name: String, in xml: String) -> String? {
        guard let bounds = openTag(name, in: xml) else { return nil }
        let tagEnd = bounds.upperBound
        if xml[bounds].hasSuffix("/>") { return "" }
        guard let close = xml.range(of: "</\(name)>", range: tagEnd..<xml.endIndex)?.lowerBound else {
            return ""
        }
        return unescape(String(xml[tagEnd..<close]))
    }

    /// 拆出同名标签的内部 XML 数组。
    static func elements(_ name: String, in xml: String) -> [String] {
        var out: [String] = []
        var rest = xml  // 全程使用同一 String，保证索引空间一致
        while true {
            guard let open = openTag(name, in: rest) else { break }
            let afterOpen = rest[open.upperBound...]
            guard let closeRange = afterOpen.range(of: "</\(name)>") else { break }
            out.append(String(afterOpen[..<closeRange.lowerBound]))
            rest = String(afterOpen[closeRange.upperBound...])
        }
        return out
    }

    /// 标签开始到 `>` 的范围；要求标签名后紧跟 `>`、空格或 `/`。
    private static func openTag(_ name: String, in xml: String) -> Range<String.Index>? {
        let variants = ["<\(name)>", "<\(name) ", "<\(name)/"]
        for variant in variants {
            if let r = xml.range(of: variant) {
                if variant.hasSuffix(">") {
                    return r.lowerBound..<r.upperBound
                }
                // 属性/自闭合形式：找到本标签的 `>`
                guard let gt = xml.range(of: ">", range: r.upperBound..<xml.endIndex) else { continue }
                return r.lowerBound..<gt.upperBound
            }
        }
        return nil
    }

    static func unescape(_ s: String?) -> String? {
        guard var s else { return nil }
        for (raw, entity) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: raw, with: entity)
        }
        return s
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: 错误映射

    public static func mapError(code: String?, status: Int) -> S3Error {
        switch code ?? "" {
        case "NoSuchKey", "NoSuchBucket":
            return .notFound
        case "AccessDenied", "SignatureDoesNotMatch", "InvalidAccessKeyId":
            return .accessDenied
        case "PreconditionFailed":
            return .preconditionFailed
        default:
            switch status {
            case 404: return .notFound
            case 403: return .accessDenied
            case 412: return .preconditionFailed
            default: return .unknown(code ?? "HTTP \(status)")
            }
        }
    }

    // MARK: ListAllMyBuckets

    public static func parseListBuckets(_ xml: String) -> [BucketInfo] {
        let bucketsXML = element("Buckets", in: xml) ?? ""
        return elements("Bucket", in: bucketsXML).map { bucket in
            let name = element("Name", in: bucket) ?? ""
            let date = element("CreationDate", in: bucket).flatMap(parseDate)
            return BucketInfo(name: name, creationDate: date)
        }
    }

    // MARK: ListObjectsV2

    public struct ListV2Result: Sendable {
        public let objects: [ObjectEntry]
        public let commonPrefixes: [String]   // 以 "/" 结尾
        public let isTruncated: Bool
        public let nextContinuationToken: String?
    }

    /// ETag 规范化：S3/R2 各接口返回的 ETag 引号形态不一致
    /// （XML 列表带引号、HTTP 头/head/download 常见去引号实现）。
    /// 全系统统一为【不带引号】存储比较，否则 baseETag 与远程 ETag 永不相等，
    /// 会导致"远程已变化"误判 → 重新下载覆盖本地未同步修改（已发生的真实事故）。
    public static func normalizeETag(_ etag: String) -> String {
        etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public static func parseListObjectsV2(_ xml: String) -> ListV2Result {
        let objects = elements("Contents", in: xml).compactMap { content -> ObjectEntry? in
            guard let key = element("Key", in: content) else { return nil }
            let size = Int64(element("Size", in: content) ?? "0") ?? 0
            let lastModified = element("LastModified", in: content).flatMap(parseDate) ?? Date()
            let etag = normalizeETag(element("ETag", in: content) ?? "")
            return ObjectEntry(key: key, size: size, lastModified: lastModified, etag: etag)
        }
        let prefixes = elements("CommonPrefixes", in: xml).compactMap { element("Prefix", in: $0) }
        let truncated = (element("IsTruncated", in: xml) ?? "false") == "true"
        let token = element("NextContinuationToken", in: xml)
        return ListV2Result(
            objects: objects,
            commonPrefixes: prefixes,
            isTruncated: truncated,
            nextContinuationToken: token
        )
    }

    // MARK: CopyObject

    public static func parseCopyResult(_ xml: String) -> String? {
        element("ETag", in: xml)
    }

    // MARK: DeleteObjects 批量删除结果

    public static func parseDeleteErrors(_ xml: String) -> [(key: String, code: String)] {
        elements("Error", in: xml).map {
            (element("Key", in: $0) ?? "", element("Code", in: $0) ?? "Unknown")
        }
    }

    // MARK: 错误响应体

    public static func parseError(_ xml: String) -> (code: String, message: String) {
        (element("Code", in: xml) ?? "", element("Message", in: xml) ?? "")
    }

    // MARK: DeleteObjects 请求体

    public static func batchDeleteBody(_ keys: [String]) -> Data {
        var xml = "<Delete>"
        for key in keys {
            xml += "<Object><Key>\(escapeXML(key))</Key></Object>"
        }
        xml += "</Delete>"
        return Data(xml.utf8)
    }

    // MARK: 时间（固定 UTC 手工解析，线程安全）

    /// "2024-01-02T03:04:05(.000-999)?Z"
    public static func parseDate(_ s: String) -> Date? {
        let pattern = #"^(-?\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range) else { return nil }
        func group(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: s) else { return 0 }
            return Int(s[r]) ?? 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var comps = DateComponents()
        comps.year = group(1)
        comps.month = group(2)
        comps.day = group(3)
        comps.hour = group(4)
        comps.minute = group(5)
        comps.second = group(6)
        var date = calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
        if let fracRange = Range(m.range(at: 7), in: s) {
            let frac = Double("0." + s[fracRange]) ?? 0
            date = date.addingTimeInterval(frac)
        }
        return date
    }

    /// RFC1123（HEAD 响应 Last-Modified 头），线程安全手工解析。
    public static func parseRFC1123(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: s)
    }
}

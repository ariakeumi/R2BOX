import Foundation

/// 一个 S3 / R2 连接配置。Secret Access Key 不进此结构，只存 macOS Keychain。
public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    public var region: String
    public var accessKeyID: String
    public var pathStyle: Bool
    /// 限定储存桶：空 = 列出全部（默认行为）；设置后侧栏只显示该桶，
    /// 并跳过 ListBuckets（仅授权单桶的 R2 API Token 没有列出全部桶的权限）。
    public var bucket: String

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        region: String,
        accessKeyID: String,
        pathStyle: Bool,
        bucket: String = ""
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.region = region
        self.accessKeyID = accessKeyID
        self.pathStyle = pathStyle
        self.bucket = bucket
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, region, accessKeyID, pathStyle, bucket
    }

    /// 兼容旧配置文件（无 bucket 字段）→ 视为列出全部
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        region = try c.decode(String.self, forKey: .region)
        accessKeyID = try c.decode(String.self, forKey: .accessKeyID)
        pathStyle = try c.decode(Bool.self, forKey: .pathStyle)
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
    }
}

public struct BucketInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let creationDate: Date?
    public var id: String { name }

    public init(name: String, creationDate: Date? = nil) {
        self.name = name
        self.creationDate = creationDate
    }
}

public struct ObjectEntry: Identifiable, Hashable, Sendable {
    public let key: String
    public let size: Int64
    public let lastModified: Date
    public let etag: String
    public var id: String { key }
    public var fileName: String { (key as NSString).lastPathComponent }

    public init(key: String, size: Int64, lastModified: Date, etag: String) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
    }
}

public enum S3Error: Error, Equatable, Sendable {
    /// 连接失败 / 模拟断网
    case network
    case notFound
    case accessDenied
    /// 条件写入失败：远程 ETag 与预期不符（典型 412 Precondition Failed）
    case preconditionFailed
    case unknown(String)
}

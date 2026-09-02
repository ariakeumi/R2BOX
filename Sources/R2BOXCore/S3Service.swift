import Foundation

/// 0...1 的进度回调。实现必须可在任意线程调用。
public typealias ProgressHandler = @Sendable (_ fraction: Double) -> Void

/// S3 / R2 抽象接口。
///
/// 约定：
/// - 大文件必须流式处理：download 逐块写入 destination，upload 逐块读取 source，
///   不允许整文件一次性载入内存（Phase 2 的真实实现同样遵守）。
/// - `ifMatch` 非空时执行条件写入，远程 ETag 不匹配时抛 `S3Error.preconditionFailed`。
public protocol S3Service: Sendable {
    var serviceName: String { get }

    func listBuckets() async throws -> [BucketInfo]
    /// prefix 以 "/" 结尾或为空。folders 返回的元素以 "/" 结尾。
    func listObjects(bucket: String, prefix: String) async throws -> (folders: [String], objects: [ObjectEntry])
    func headObject(bucket: String, key: String) async throws -> ObjectEntry?

    /// 流式下载到 destination，返回远程 ETag。
    @discardableResult
    func download(bucket: String, key: String, destination: URL, progress: ProgressHandler?) async throws -> String

    /// 流式上传，返回新 ETag。
    @discardableResult
    func upload(bucket: String, key: String, source: URL, ifMatch: String?, progress: ProgressHandler?) async throws -> String

    func delete(bucket: String, key: String, isFolder: Bool) async throws
    /// 重命名（S3 语义：copy + delete）
    func move(bucket: String, key: String, isFolder: Bool, newKeyName: String) async throws
    func createFolder(bucket: String, prefix: String) async throws
}

public enum S3ServiceFactory {
    /// 按连接选择实现：
    /// - 端点含 "demo." 或 accessKey 为空 → 内置 Mock（Phase 1 演示数据）
    /// - 其余 → 真实 S3/R2（SigV4 + URLSession）
    /// Secret 经 provider 在每次请求时从 Keychain 读取，不落内存缓存。
    public static func service(for connection: Connection, secretProvider: (@Sendable () -> String?)? = nil) -> S3Service {
        let endpoint = connection.endpoint.lowercased()
        let isDemo = endpoint.contains("demo.") || connection.accessKeyID.isEmpty
        if isDemo {
            return MockS3Service()
        }
        let provider: @Sendable () -> String?
        if let secretProvider {
            provider = secretProvider
        } else {
            let store = ConnectionStore.shared
            let id = connection.id
            provider = { store.secret(for: id) }
        }
        return AWSS3Service(connection: connection, secretKeyProvider: provider)
    }

    /// Phase 1 兼容入口：无 Secret 时一律 Mock。
    public static func service(for connection: Connection) -> S3Service {
        service(for: connection, secretProvider: nil)
    }
}

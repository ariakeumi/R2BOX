import Foundation

/// 本地工作区：~/Library/Application Support/R2BOX/workspace/<bucket>/<key>
/// 远程文件下载到这里编辑；SyncEngine 监听变化并自动上传。
public final class Workspace: Sendable {
    public let baseURL: URL

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("R2BOX/workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    /// 本地缓存路径（不确保父目录存在）
    public func localURL(bucket: String, key: String) -> URL {
        baseURL.appendingPathComponent(bucket).appendingPathComponent(key)
    }

    public func exists(bucket: String, key: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(bucket: bucket, key: key).path)
    }

    public func removeLocal(bucket: String, key: String) {
        try? FileManager.default.removeItem(at: localURL(bucket: bucket, key: key))
    }
}

import Foundation
import R2BOXCore

/// 同步元数据：跟踪中的文件与其 baseETag，持久化在 workspace 的 .r2box/ 下，
/// 应用重启后恢复跟踪与冲突检测基线。
public struct MetadataStore: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var bucket: String
        public var key: String
        public var baseETag: String
        /// 上次确认与远程一致时的本地文件指纹（mtime+size）。
        /// 持久化后重启也能识别"本地有未同步修改"，打开时不会误判为干净副本而被远程覆盖。
        public var syncedMtime: Date?
        public var syncedSize: Int64?

        public init(bucket: String, key: String, baseETag: String, syncedMtime: Date? = nil, syncedSize: Int64? = nil) {
            self.bucket = bucket
            self.key = key
            self.baseETag = baseETag
            self.syncedMtime = syncedMtime
            self.syncedSize = syncedSize
        }

        private enum CodingKeys: String, CodingKey {
            case bucket, key, baseETag, syncedMtime, syncedSize
        }

        /// 兼容旧 tracked.json（无指纹字段）
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bucket = try c.decode(String.self, forKey: .bucket)
            key = try c.decode(String.self, forKey: .key)
            baseETag = try c.decode(String.self, forKey: .baseETag)
            syncedMtime = try c.decodeIfPresent(Date.self, forKey: .syncedMtime)
            syncedSize = try c.decodeIfPresent(Int64.self, forKey: .syncedSize)
        }
    }

    private let fileURL: URL

    public init(workspace: Workspace) {
        let dir = workspace.baseURL.appendingPathComponent(WorkspaceWatcher.metadataFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tracked.json")
    }

    public func loadAll() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    public func record(
        bucket: String, key: String, baseETag: String,
        syncedMtime: Date? = nil, syncedSize: Int64? = nil
    ) {
        var all = loadAll().filter { !($0.bucket == bucket && $0.key == key) }
        all.append(Entry(
            bucket: bucket, key: key, baseETag: baseETag,
            syncedMtime: syncedMtime, syncedSize: syncedSize
        ))
        save(all)
    }

    public func remove(bucket: String, key: String) {
        save(loadAll().filter { !($0.bucket == bucket && $0.key == key) })
    }

    public func removeAll() {
        save([])
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

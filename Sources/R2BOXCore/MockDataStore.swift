import Foundation

/// Mock 远端对象的真实数据。actor 保证线程安全。
public actor MockDataStore {
    public final class Entry {
        public var data: Data
        public var etag: String
        public var lastModified: Date
        init(data: Data, etag: String, lastModified: Date) {
            self.data = data
            self.etag = etag
            self.lastModified = lastModified
        }
    }

    /// 跨 actor 边界传递的只读快照（Entry 本体不可 Sendable）
    public struct Snapshot: Sendable {
        public let data: Data
        public let etag: String
        public let lastModified: Date
    }

    public static let shared = MockDataStore()

    public static let demoBucketNames = ["app-config", "static-assets", "media-archive"]

    private var buckets: [String: [String: Entry]] = [:]
    private var seededBuckets: Set<String> = []

    static func makeEtag() -> String {
        // 与真实服务一致：全系统 ETag 统一【不带引号】（见 S3XML.normalizeETag）
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public init() {}

    // MARK: - Seed

    func seedIfNeeded(_ bucket: String) {
        guard seededBuckets.insert(bucket).inserted else { return }
        var store: [String: Entry] = [:]
        let now = Date()
        for (key, text) in Self.textFiles {
            store[key] = Entry(
                data: Data(text.utf8),
                etag: Self.makeEtag(),
                lastModified: now.addingTimeInterval(-Double.random(in: 3600...2_592_000))
            )
        }
        if bucket == "media-archive" {
            for (key, megabytes) in Self.bigFiles {
                store[key] = Entry(
                    data: Data(count: megabytes * 1_048_576),
                    etag: Self.makeEtag(),
                    lastModified: now.addingTimeInterval(-Double.random(in: 3600...2_592_000))
                )
            }
        }
        buckets[bucket] = store
    }

    private static let textFiles: [(String, String)] = [
        ("config.yaml", """
        # R2BOX 演示用主配置
        # 用编辑器打开并保存 (⌘S) 后，会自动上传回 Bucket。

        app:
          name: r2box-demo
          version: 0.1.0
          environment: production

        storage:
          driver: s3
          endpoint: https://demo.r2.cloudflarestorage.com
          region: auto
          bucket: media-archive
          path_style: true
          presign_expiry: 15m

        cache:
          driver: redis
          url: redis://cache.internal:6379/0
          ttl: 300s

        logging:
          level: info
          format: json

        features:
          quick_look: true
          auto_sync: true
          conflict_prompt: true
        """),
        ("config.json", """
        {
          "name": "r2box-demo",
          "version": "0.1.0",
          "features": {
            "auto_sync": true,
            "quick_look": true,
            "max_concurrent_transfers": 4
          },
          "retry": {
            "max_attempts": 5,
            "backoff_seconds": 2
          }
        }
        """),
        ("settings.toml", """
        [server]
        host = "0.0.0.0"
        port = 8080
        read_timeout = "30s"

        [transfer]
        chunk_size = "256KiB"
        verify_etag = true
        """),
        ("README.md", """
        # app-config

        这是 R2BOX 的演示 Bucket。

        ## 建议体验顺序

        1. 双击 `config.yaml`，文件会下载到本地工作区并用默认编辑器打开
        2. 随便改一行，⌘S 保存 —— R2BOX 会自动上传，状态栏出现 ✓
        3. 菜单「调试 → 在远程修改选中文件（模拟冲突）」，然后再改一次本地文件并保存，
           就会看到冲突对话框（覆盖 / 重新加载 / 保留本地）
        4. 菜单「调试 → 模拟网络中断」，再保存一次：本地修改会保留，恢复网络后自动续传
        """),
        ("envs/prod.yaml", """
        environment: production
        replicas: 6
        storage_bucket: media-archive
        logging:
          level: warn
        """),
        ("envs/staging.yaml", """
        environment: staging
        replicas: 2
        storage_bucket: media-archive
        logging:
          level: debug
        """),
        ("envs/dev.yaml", """
        environment: development
        replicas: 1
        storage_bucket: media-archive
        logging:
          level: debug
        """),
        ("services/api/config.yaml", """
        service: api
        port: 8081
        timeout: 15s
        rate_limit:
          per_minute: 600
        """),
        ("services/worker/config.yaml", """
        service: worker
        concurrency: 8
        poll_interval: 5s
        """),
    ]

    private static let bigFiles: [(String, Int)] = [
        ("raw/clip-01.mov", 18),
        ("exports/render-final.mov", 6),
    ]

    // MARK: - 操作

    func entry(bucket: String, key: String) -> Entry? {
        seedIfNeeded(bucket)
        return buckets[bucket]?[key]
    }

    func snapshot(bucket: String, key: String) -> Snapshot? {
        guard let entry = entry(bucket: bucket, key: key) else { return nil }
        return Snapshot(data: entry.data, etag: entry.etag, lastModified: entry.lastModified)
    }

    func keys(bucket: String) -> [String] {
        seedIfNeeded(bucket)
        let store = buckets[bucket] ?? [:]
        return Array(store.keys).sorted()
    }

    @discardableResult
    func put(bucket: String, key: String, data: Data) -> String {
        seedIfNeeded(bucket)
        let etag = Self.makeEtag()
        buckets[bucket, default: [:]][key] = Entry(data: data, etag: etag, lastModified: Date())
        return etag
    }

    func remove(bucket: String, key: String, isFolder: Bool) {
        seedIfNeeded(bucket)
        guard var store = buckets[bucket] else { return }
        if isFolder {
            let prefix = key.hasSuffix("/") ? key : key + "/"
            for k in store.keys where k.hasPrefix(prefix) { store[k] = nil }
        } else {
            store[key] = nil
        }
        buckets[bucket] = store
    }

    func movePrefix(bucket: String, oldKey: String, newKey: String) {
        seedIfNeeded(bucket)
        guard var store = buckets[bucket] else { return }
        if oldKey.hasSuffix("/") {
            let prefix = oldKey
            for k in store.keys where k.hasPrefix(prefix) {
                let newFullKey = newKey + k.dropFirst(prefix.count)
                store[newFullKey] = store[k]
                store[k] = nil
            }
        } else if let entry = store[oldKey] {
            store[newKey] = entry
            store[oldKey] = nil
        }
        buckets[bucket] = store
    }

    func createFolder(bucket: String, prefix: String) {
        seedIfNeeded(bucket)
        let key = prefix.hasSuffix("/") ? prefix : prefix + "/"
        buckets[bucket, default: [:]][key] = Entry(data: Data(), etag: Self.makeEtag(), lastModified: Date())
    }

    /// 调试：模拟他人修改远程文件（文本文件追加一行，并生成新 ETag）
    @discardableResult
    func simulateRemoteModify(bucket: String, key: String) -> Bool {
        guard let entry = entry(bucket: bucket, key: key), !key.hasSuffix("/") else { return false }
        if let text = String(data: entry.data, encoding: .utf8) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            entry.data = Data((text + "\n# [模拟] 远程在 \(stamp) 被他人修改\n").utf8)
        } else {
            entry.data.append(UInt8.random(in: 0...255))
        }
        entry.etag = Self.makeEtag()
        entry.lastModified = Date()
        return true
    }
}

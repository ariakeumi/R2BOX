import Foundation

/// Phase 1 的 S3 实现：内存数据 + 模拟网络延迟 + 分块流式传输 + 断网模拟。
public actor MockS3Service: S3Service {
    public let serviceName = "MockS3"

    private let data: MockDataStore
    private var outage = false

    public init(data: MockDataStore = .shared) {
        self.data = data
    }

    // MARK: - 调试控制

    public func setOutage(_ on: Bool) {
        outage = on
    }

    public var isOutage: Bool { outage }

    private func ensureOnline() throws {
        if outage { throw S3Error.network }
    }

    private func jitter(_ ms: ClosedRange<Int> = 80...220) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(Int.random(in: ms)))
    }

    // MARK: - S3Service

    public func listBuckets() async throws -> [BucketInfo] {
        try ensureOnline()
        try await jitter(120...320)
        return MockDataStore.demoBucketNames.map {
            BucketInfo(name: $0, creationDate: Date().addingTimeInterval(-Double.random(in: 86_400...31_536_000)))
        }
    }

    public func listObjects(bucket: String, prefix: String) async throws -> (folders: [String], objects: [ObjectEntry]) {
        try ensureOnline()
        try await jitter(80...260)
        let all = await data.keys(bucket: bucket)
        let normalizedPrefix = prefix.isEmpty ? "" : (prefix.hasSuffix("/") ? prefix : prefix + "/")

        var folders = Set<String>()
        var objects: [ObjectEntry] = []
        for key in all where key.hasPrefix(normalizedPrefix) {
            let rest = String(key.dropFirst(normalizedPrefix.count))
            if rest.isEmpty { continue }
            if let slash = rest.firstIndex(of: "/") {
                let folderPrefix = normalizedPrefix + String(rest[...slash])
                // 纯占位对象 "dir/"（零字节）也归入文件夹
                folders.insert(folderPrefix)
            } else {
                guard let entry = await data.snapshot(bucket: bucket, key: key) else { continue }
                // "name/" 零字节文件夹标记不作为文件列出
                if rest.hasSuffix("/") && entry.data.isEmpty { continue }
                objects.append(ObjectEntry(
                    key: key,
                    size: Int64(entry.data.count),
                    lastModified: entry.lastModified,
                    etag: entry.etag
                ))
            }
        }
        return (folders.sorted(), objects.sorted { $0.key < $1.key })
    }

    public func headObject(bucket: String, key: String) async throws -> ObjectEntry? {
        try ensureOnline()
        try await jitter(50...140)
        guard let entry = await data.snapshot(bucket: bucket, key: key) else { return nil }
        return ObjectEntry(key: key, size: Int64(entry.data.count), lastModified: entry.lastModified, etag: entry.etag)
    }

    public func download(bucket: String, key: String, destination: URL, progress: ProgressHandler?) async throws -> String {
        try ensureOnline()
        try await jitter(80...200)
        guard let entry = await data.snapshot(bucket: bucket, key: key) else { throw S3Error.notFound }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 写到元数据目录下的临时文件，完成后原子 rename —— 避免目标路径出现"空文件窗口"
        // 被 FSEvents 抓到后误上传空内容。
        let tempDir = destination.deletingLastPathComponent()
            .appendingPathComponent(".__r2box_tmp", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".part")
        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw S3Error.unknown("无法创建临时文件 \(tempURL.path)")
        }
        defer { try? fm.removeItem(at: tempURL) }
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        // 流式分块写入，模拟真实网络的渐进传输
        let total = entry.data.count
        let chunkSize = 256 * 1024
        let chunks = max(1, (total + chunkSize - 1) / chunkSize)
        let chunkDelay: Duration = total > 1_048_576 ? .milliseconds(45) : .milliseconds(12)
        for i in 0..<chunks {
            try Task.checkCancellation()
            let start = i * chunkSize
            let end = min(total, start + chunkSize)
            try handle.write(contentsOf: entry.data[start..<end])
            progress?(Double(i + 1) / Double(chunks))
            try await Task.sleep(for: chunkDelay)
        }
        try ensureOnline() // 传输途中断网

        try handle.close()
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        return entry.etag
    }

    public func upload(bucket: String, key: String, source: URL, ifMatch: String?, progress: ProgressHandler?) async throws -> String {
        try ensureOnline()
        try await jitter(80...200)

        // 流式分块读取本地文件
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let total = Int64((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
        let chunkSize = 256 * 1024
        let chunkSizeI64 = Int64(chunkSize)
        let chunks = max(1, Int((total + chunkSizeI64 - 1) / chunkSizeI64))
        var buffer = Data(); buffer.reserveCapacity(Int(total))
        let chunkDelay: Duration = total > 1_048_576 ? .milliseconds(45) : .milliseconds(12)
        for i in 0..<chunks {
            try Task.checkCancellation()
            if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                buffer.append(chunk)
            }
            progress?(Double(i + 1) / Double(chunks))
            try await Task.sleep(for: chunkDelay)
        }
        try ensureOnline()
        return try await data.put(bucket: bucket, key: key, data: buffer, ifMatch: ifMatch)
    }

    public func delete(bucket: String, key: String, isFolder: Bool) async throws {
        try ensureOnline()
        try await jitter()
        await data.remove(bucket: bucket, key: key, isFolder: isFolder)
    }

    public func move(bucket: String, key: String, isFolder: Bool, newKeyName: String) async throws {
        try ensureOnline()
        try await jitter()
        let dir = parentPrefix(of: key)
        let newKey = isFolder ? dir + newKeyName + "/" : dir + newKeyName
        await data.movePrefix(bucket: bucket, oldKey: key, newKey: newKey)
    }

    public func createFolder(bucket: String, prefix: String) async throws {
        try ensureOnline()
        try await jitter()
        await data.createFolder(bucket: bucket, prefix: prefix)
    }

    // MARK: - 调试

    @discardableResult
    public func simulateRemoteModify(bucket: String, key: String) async throws -> Bool {
        try ensureOnline()
        return await data.simulateRemoteModify(bucket: bucket, key: key)
    }

    private func parentPrefix(of key: String) -> String {
        guard let lastSlash = key.lastIndex(of: "/") else { return "" }
        return String(key[...lastSlash])
    }
}

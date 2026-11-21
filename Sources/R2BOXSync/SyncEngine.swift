import Darwin
import Foundation
import Network
import R2BOXCore

/// 一个需要同步的本地文件（bucket + key 的组合）。
public struct TrackedFile: Hashable, Sendable {
    public let bucket: String
    public let key: String
    public init(bucket: String, key: String) {
        self.bucket = bucket
        self.key = key
    }
}

/// 同步事件，UI 据此更新状态栏 / 传输列表 / 冲突弹窗。
public enum SyncEvent: Sendable {
    case uploadStarted(TrackedFile)
    case uploadProgress(TrackedFile, fraction: Double)
    case uploadDone(TrackedFile, etag: String)
    case uploadFailed(TrackedFile, reason: String)
    case conflictDetected(TrackedFile, localETagBase: String, remote: ObjectEntry)
    case outageChanged(Bool)
}

public enum ConflictChoice: Sendable {
    case overwriteRemote   // 用本地覆盖远程
    case reloadRemote      // 放弃本地修改，重新下载
    case keepLocalOnly     // 保留本地副本，不上传
}

/// 单个文件的同步状态（UI 显示用）
public enum FileSyncStatus: Hashable, Sendable {
    case remoteOnly
    case synced
    case dirty
    case uploading(Double)
    case failed(String)
    case conflict
}

/// 同步引擎。
///
/// 职责：
/// - 监听 workspace 内文件变化（FSEvents），自动上传（actor 串行化 + per-file 防抖）
/// - 上传携带 baseETag 条件写入（If-Match），远程被他人修改 → 冲突，不覆盖，交给 UI 决策
/// - 网络失败保留本地修改并进入重试队列，恢复网络后续传
public actor SyncEngine {
    public struct TrackedInfo: Sendable {
        public var baseETag: String   // 下载/上次上传成功时的远程 ETag，条件写入用
        public var dirty = false
        public var failedReason: String?
        /// 上次确认"与远程一致"时的本地文件指纹：下载完成/上传成功后记录。
        /// FSEvents 事件到达时若指纹未变（下载落盘过程中的事件、重复事件），跳过上传。
        public var syncedMtime: Date?
        public var syncedSize: Int64?
    }

    private let workspace: Workspace
    /// 引擎所用的 S3 服务句柄（自检/诊断用）
    public nonisolated let service: S3Service
    private let metadata: MetadataStore

    private var tracked: [TrackedFile: TrackedInfo] = [:]
    private var restored = false
    private var retryQueue: Set<TrackedFile> = []
    private enum Operation { case uploading, downloading, invalidated }
    private var operations: [TrackedFile: Operation] = [:]
    private var conflictPending: Set<TrackedFile> = []
    private var keptLocal: [TrackedFile: Fingerprint] = [:]
    private var outage = false
    private var debouncers: [TrackedFile: Debouncer] = [:]
    private var retryTask: Task<Void, Never>?
    private let retryDelay: Duration
    private var pathMonitor: NWPathMonitor?

    /// 冲突决策（UI 提供，弹窗等待用户选择）
    public nonisolated(unsafe) var conflictHandler: @Sendable (TrackedFile, String, ObjectEntry) async -> ConflictChoice

    /// 事件回调（UI 提供；在任意线程调用，UI 需自行跳主线程）
    public nonisolated(unsafe) var eventHandler: @Sendable (SyncEvent) -> Void

    public init(workspace: Workspace, service: S3Service, retryDelay: Duration = .seconds(4)) {
        self.workspace = workspace
        self.service = service
        self.metadata = MetadataStore(workspace: workspace)
        self.conflictHandler = { _, _, _ in .keepLocalOnly }
        self.eventHandler = { _ in }
        self.retryDelay = retryDelay
    }

    private func id(_ f: TrackedFile) -> String { "\(f.bucket)/\(f.key)" }

    private func emit(_ event: SyncEvent) {
        eventHandler(event)
    }

    // MARK: - 跟踪管理

    /// 下载完成后登记跟踪（baseETag = 下载时的远程 ETag）。
    /// 同时记录本地文件指纹（mtime+size），后续 FSEvents 指纹未变则不上传。
    public func track(bucket: String, key: String, baseETag: String) {
        guard !key.hasPrefix("\(bucket)/") else {
            // 防御：拒绝 key 自带 bucket 前缀的坏记录（历史上会写出双层路径）
            return
        }
        let file = TrackedFile(bucket: bucket, key: key)
        if operations[file] != nil { operations[file] = .invalidated }
        recordSync(file, etag: baseETag, fingerprint: localFingerprint(file))
    }

    private func recordSync(_ file: TrackedFile, etag: String, fingerprint: Fingerprint?, dirty: Bool = false) {
        tracked[file] = TrackedInfo(
            baseETag: etag,
            dirty: dirty,
            syncedMtime: fingerprint?.mtime,
            syncedSize: fingerprint?.size
        )
        metadata.record(
            bucket: file.bucket, key: file.key, baseETag: etag,
            syncedMtime: fingerprint?.mtime, syncedSize: fingerprint?.size
        )
        retryQueue.remove(file)
        keptLocal.removeValue(forKey: file)
    }

    private struct Fingerprint: Equatable {
        var mtime: Date
        var size: Int64
        var fileNumber: UInt64?
    }

    private func localURL(_ file: TrackedFile) -> URL {
        workspace.localURL(bucket: file.bucket, key: file.key)
    }

    private func localFingerprint(_ file: TrackedFile) -> Fingerprint? {
        fingerprint(at: localURL(file).resolvingSymlinksInPath())
    }

    private func fingerprint(at url: URL) -> Fingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Fingerprint(
            mtime: attrs[.modificationDate] as? Date ?? Date.distantPast,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    public func untrack(bucket: String, key: String) {
        let file = TrackedFile(bucket: bucket, key: key)
        if operations[file] != nil { operations[file] = .invalidated }
        tracked[file] = nil
        retryQueue.remove(file)
        conflictPending.remove(file)
        keptLocal.removeValue(forKey: file)
        if let debouncer = debouncers.removeValue(forKey: file) {
            Task { await debouncer.cancel() }
        }
        metadata.remove(bucket: bucket, key: key)
    }

    public func isTracked(bucket: String, key: String) -> Bool {
        tracked[TrackedFile(bucket: bucket, key: key)] != nil
    }

    public func trackedInfo(bucket: String, key: String) -> TrackedInfo? {
        tracked[TrackedFile(bucket: bucket, key: key)]
    }

    public func failedFiles() -> [TrackedFile] {
        Array(retryQueue)
    }

    public var hasOutage: Bool { outage }

    /// UI 查询某文件当前的同步状态
    public func status(bucket: String, key: String) -> FileSyncStatus {
        status(of: TrackedFile(bucket: bucket, key: key))
    }

    /// 一次性导出全部跟踪文件的同步状态（key: "bucket/key"），用于 UI 状态镜像
    public func allStatuses() -> [String: FileSyncStatus] {
        var out: [String: FileSyncStatus] = [:]
        for file in tracked.keys {
            out[id(file)] = status(of: file)
        }
        return out
    }

    private func status(of file: TrackedFile) -> FileSyncStatus {
        guard let info = tracked[file] else { return .remoteOnly }
        if conflictPending.contains(file) { return .conflict }
        if operations[file] == .uploading { return .uploading(0) }
        if let reason = info.failedReason { return .failed(reason) }
        if info.dirty { return .dirty }
        return .synced
    }

    /// 从磁盘恢复同步基线，并识别应用关闭期间留下的修改。
    public func restoreFromDisk() {
        guard !restored else { return }
        restored = true
        for entry in metadata.loadAll() {
            let file = TrackedFile(bucket: entry.bucket, key: entry.key)
            guard tracked[file] == nil else { continue }
            let fingerprint = localFingerprint(file)
            let dirty: Bool
            if let mtime = entry.syncedMtime, let size = entry.syncedSize, let fingerprint {
                dirty = fingerprint.mtime != mtime || fingerprint.size != size
            } else {
                dirty = false
            }
            tracked[file] = TrackedInfo(
                baseETag: entry.baseETag, dirty: dirty,
                syncedMtime: entry.syncedMtime, syncedSize: entry.syncedSize
            )
        }
    }

    /// 编辑和预览共用同一套打开规则。下载期间发生的新修改会保留。
    public func prepareLocalCopy(
        bucket: String, entry: ObjectEntry, progress: ProgressHandler?
    ) async throws -> (url: URL, downloaded: Bool)? {
        restoreFromDisk()
        let file = TrackedFile(bucket: bucket, key: entry.key)
        let url = localURL(file)
        let fingerprint = localFingerprint(file)
        let info = tracked[file]
        if let operation = operations[file] {
            guard operation == .uploading else { return nil }
            return fingerprint.map { _ in (url, false) }
        }
        let plan = OpenDecision.plan(
            localExists: fingerprint != nil, remoteSize: entry.size,
            trackedBaseETag: info?.baseETag, currentETag: entry.etag,
            syncedMtime: info?.syncedMtime, syncedSize: info?.syncedSize,
            localMtime: fingerprint?.mtime, localSize: fingerprint?.size,
            localDirty: info?.dirty ?? false
        )
        guard plan == .downloadRemote else { return (url, false) }

        operations[file] = .downloading
        defer { operations[file] = nil }
        do {
            _ = try await downloadAndTrack(file, replacing: fingerprint, progress: progress)
            return (url, true)
        } catch is CancellationError {
            return nil
        }
    }

    /// 用户显式要求重新下载（放弃当前本地修改）。
    public func reloadFromRemote(bucket: String, key: String) async throws -> String {
        let file = TrackedFile(bucket: bucket, key: key)
        guard operations[file] == nil else { throw S3Error.unknown("文件正在同步") }
        operations[file] = .downloading
        defer { operations[file] = nil }
        return try await downloadAndTrack(file, replacing: localFingerprint(file), progress: nil)
    }

    private enum LocalChange: LocalizedError {
        case duringUpload
        case duringDownload

        var errorDescription: String? {
            switch self {
            case .duringUpload: "读取上传副本时本地文件发生变化"
            case .duringDownload: "下载期间本地文件发生变化，已保留本地修改"
            }
        }
    }

    private func temporaryURL() -> URL {
        workspace.baseURL.appendingPathComponent(WorkspaceWatcher.metadataFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
    }

    private func downloadAndTrack(
        _ file: TrackedFile, replacing fingerprint: Fingerprint?, progress: ProgressHandler?
    ) async throws -> String {
        let staging = temporaryURL()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        progress?(0)
        let etag = try await service.download(
            bucket: file.bucket, key: file.key, destination: staging, progress: progress
        )
        guard operations[file] != .invalidated else { throw CancellationError() }
        guard !etag.isEmpty else { throw S3Error.unknown("下载响应缺少 ETag，已保留本地文件") }
        let destination = localURL(file)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let downloadedFingerprint = self.fingerprint(at: staging)
        guard fingerprint == localFingerprint(file) else {
            tracked[file]?.dirty = true
            throw LocalChange.duringDownload
        }
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        recordSync(file, etag: etag, fingerprint: downloadedFingerprint)
        return etag
    }

    /// ⌘S / 菜单跳过防抖，沿用原来的写入基线。
    public func forceUpload(bucket: String, key: String) async {
        restoreFromDisk()
        await performUpload(TrackedFile(bucket: bucket, key: key), manual: true)
    }

    // MARK: - FSEvents 入口

    public func handleWorkspaceChanges(_ relativePaths: [String]) {
        var affected = Set<TrackedFile>()
        for path in relativePaths {
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, parts[0] != WorkspaceWatcher.metadataFolderName else { continue }
            let key = String(parts[1])
            let components = key.split(separator: "/")
            guard !components.contains(where: { $0 == WorkspaceWatcher.tempFolderName }),
                  components.last != ".DS_Store", !key.hasSuffix("/") else { continue }
            let file = TrackedFile(bucket: String(parts[0]), key: key)
            if tracked[file] != nil { affected.insert(file) }
        }
        for file in affected {
            let debouncer = debouncers[file] ?? Debouncer(delay: .milliseconds(600))
            debouncers[file] = debouncer
            let upload: @Sendable () async -> Void = { [weak self] in
                await self?.performUpload(file)
            }
            Task { await debouncer.fire(upload) }
        }
    }

    // MARK: - 上传

    private func performUpload(_ file: TrackedFile, manual: Bool = false) async {
        guard tracked[file] != nil, operations[file] == nil else { return }
        operations[file] = .uploading
        defer { operations[file] = nil }
        retryQueue.remove(file)
        var confirmedETag: String?
        while operations[file] == .uploading, let info = tracked[file] {
            guard let fingerprint = localFingerprint(file) else {
                untrack(bucket: file.bucket, key: file.key)
                return
            }
            if !manual && keptLocal[file] == fingerprint { return }
            if !info.dirty && fingerprint.mtime == info.syncedMtime && fingerprint.size == info.syncedSize {
                return
            }

            let ifMatch = confirmedETag ?? info.baseETag
            guard !ifMatch.isEmpty else {
                reportFailure(file, reason: "缺少远端 ETag，已保留本地修改")
                return
            }

            tracked[file]?.dirty = true
            do {
                let etag = try await uploadSnapshot(file, fingerprint: fingerprint, ifMatch: ifMatch)
                guard operations[file] == .uploading else { return }
                updateOutage(false)
                guard !etag.isEmpty else {
                    reportFailure(file, reason: "上传响应缺少 ETag，无法确认同步版本")
                    return
                }
                let dirty = localFingerprint(file) != fingerprint
                recordSync(file, etag: etag, fingerprint: fingerprint, dirty: dirty)
                if dirty {
                    confirmedETag = nil
                    continue
                }
                emit(.uploadDone(file, etag: etag))
                return
            } catch S3Error.preconditionFailed {
                guard operations[file] == .uploading else { return }
                guard let etag = await resolveConflict(file, baseETag: info.baseETag) else { return }
                confirmedETag = etag
            } catch {
                guard operations[file] == .uploading else { return }
                handleFailure(file, error: error, operation: "上传")
                return
            }
        }
    }

    private func uploadSnapshot(_ file: TrackedFile, fingerprint: Fingerprint, ifMatch: String) async throws -> String {
        let snapshot = temporaryURL()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: snapshot) }
        let source = localURL(file).resolvingSymlinksInPath()
        if clonefile(source.path, snapshot.path, 0) != 0 {
            try fm.copyItem(at: source, to: snapshot)
        }
        guard fingerprint == localFingerprint(file) else { throw LocalChange.duringUpload }
        emit(.uploadStarted(file))
        return try await service.upload(
            bucket: file.bucket, key: file.key, source: snapshot, ifMatch: ifMatch
        ) { [eventHandler] fraction in
            eventHandler(.uploadProgress(file, fraction: fraction))
        }
    }

    private func reportFailure(_ file: TrackedFile, reason: String, retry: Bool = false) {
        tracked[file]?.failedReason = reason
        if retry {
            retryQueue.insert(file)
            scheduleRetry()
        }
        emit(.uploadFailed(file, reason: reason))
    }

    private func handleFailure(_ file: TrackedFile, error: Error, operation: String, retry: Bool = true) {
        switch error as? S3Error {
        case .notFound:
            updateOutage(false)
            reportFailure(file, reason: "远程对象已不存在，本地修改已保留")
        case .accessDenied:
            reportFailure(file, reason: "\(operation)失败：访问被拒绝，本地修改已保留")
        case .unknown(let reason):
            reportFailure(file, reason: "\(operation)失败：\(reason)", retry: retry)
        default:
            if (error as? S3Error) == .network || error is URLError {
                updateOutage(true)
                reportFailure(file, reason: "\(operation)时网络不可用，本地修改已保留", retry: retry)
            } else {
                reportFailure(file, reason: "\(operation)失败：\(error.localizedDescription)", retry: retry)
            }
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self, retryDelay] in
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            await self?.retryAfterDelay()
        }
    }

    private func retryAfterDelay() async {
        retryTask = nil
        await retryFailed()
    }

    public func retryFailed() async {
        let files = retryQueue.filter { operations[$0] == nil }
        await withTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask { await self.performUpload(file) }
            }
        }
    }

    /// 断网模拟开关。
    public func setOutage(_ on: Bool) async {
        if let mock = service as? MockS3Service {
            await mock.setOutage(on)
        }
        updateOutage(on)
        if !on { await retryFailed() }
    }

    private func updateOutage(_ on: Bool) {
        guard outage != on else { return }
        outage = on
        emit(.outageChanged(on))
    }

    public func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.networkRecovered() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.r2box.syncpath"))
        pathMonitor = monitor
    }

    deinit {
        pathMonitor?.cancel()
        retryTask?.cancel()
    }

    private func networkRecovered() async {
        updateOutage(false)
        await retryFailed()
    }

    // MARK: - 冲突

    private func resolveConflict(_ file: TrackedFile, baseETag: String) async -> String? {
        conflictPending.insert(file)
        defer { conflictPending.remove(file) }
        let remote: ObjectEntry
        do {
            guard let entry = try await service.headObject(bucket: file.bucket, key: file.key) else {
                throw S3Error.notFound
            }
            remote = entry
        } catch {
            if operations[file] == .uploading { handleFailure(file, error: error, operation: "查询远端版本") }
            return nil
        }
        guard operations[file] == .uploading else { return nil }
        updateOutage(false)
        emit(.conflictDetected(file, localETagBase: baseETag, remote: remote))
        let choice = await conflictHandler(file, baseETag, remote)
        guard operations[file] == .uploading else { return nil }
        switch choice {
        case .overwriteRemote:
            return remote.etag
        case .reloadRemote:
            operations[file] = .downloading
            do {
                let etag = try await downloadAndTrack(file, replacing: localFingerprint(file), progress: nil)
                emit(.uploadDone(file, etag: etag))
            } catch {
                if operations[file] == .downloading {
                    handleFailure(file, error: error, operation: "重新下载", retry: false)
                }
            }
        case .keepLocalOnly:
            keptLocal[file] = localFingerprint(file)
            reportFailure(file, reason: "已保留本地副本（未上传）")
        }
        return nil
    }
}

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
    public let service: S3Service
    private let metadata: MetadataStore

    /// key: "bucket/key"（key 已 URL 编码，无歧义）
    private var tracked: [String: TrackedInfo] = [:]
    private var retryQueue: Set<String> = []
    private var uploading: Set<String> = []
    private var uploadProgressMap: [String: Double] = [:]
    private var conflictPending: Set<String> = []
    private var outage = false
    private var debouncers: [String: Debouncer] = [:]
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
        let fileID = id(TrackedFile(bucket: bucket, key: key))
        let fingerprint = localFingerprint(bucket: bucket, key: key)
        tracked[fileID] = tracked[fileID].map { info in
            var i = info
            i.baseETag = baseETag
            i.dirty = false
            i.failedReason = nil
            i.syncedMtime = fingerprint?.mtime
            i.syncedSize = fingerprint?.size
            return i
        } ?? TrackedInfo(
            baseETag: baseETag,
            syncedMtime: fingerprint?.mtime,
            syncedSize: fingerprint?.size
        )
        metadata.record(
            bucket: bucket, key: key, baseETag: baseETag,
            syncedMtime: fingerprint?.mtime, syncedSize: fingerprint?.size
        )
        retryQueue.remove(fileID)
        conflictPending.remove(fileID)
    }

    private struct Fingerprint {
        var mtime: Date
        var size: Int64
    }

    private func localFingerprint(bucket: String, key: String) -> Fingerprint? {
        let url = workspace.localURL(bucket: bucket, key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Fingerprint(
            mtime: attrs[.modificationDate] as? Date ?? Date.distantPast,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    public func untrack(bucket: String, key: String) {
        let key = id(TrackedFile(bucket: bucket, key: key))
        tracked[key] = nil
        retryQueue.remove(key)
        debouncers[key] = nil
        metadata.remove(bucket: bucket, key: key)
    }

    public func isTracked(bucket: String, key: String) -> Bool {
        tracked[id(TrackedFile(bucket: bucket, key: key))] != nil
    }

    public func trackedInfo(bucket: String, key: String) -> TrackedInfo? {
        tracked[id(TrackedFile(bucket: bucket, key: key))]
    }

    public func failedFiles() -> [TrackedFile] {
        retryQueue.compactMap { id -> TrackedFile? in
            let comps = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard comps.count == 2 else { return nil }
            return TrackedFile(bucket: comps[0], key: comps[1])
        }
    }

    public var hasOutage: Bool { outage }

    /// UI 查询某文件当前的同步状态
    public func status(bucket: String, key: String) -> FileSyncStatus {
        statusByID(id(TrackedFile(bucket: bucket, key: key)))
    }

    /// 一次性导出全部跟踪文件的同步状态（key: "bucket/key"），用于 UI 状态镜像
    public func allStatuses() -> [String: FileSyncStatus] {
        var out: [String: FileSyncStatus] = [:]
        for fileID in tracked.keys {
            out[fileID] = statusByID(fileID)
        }
        return out
    }

    private func statusByID(_ fileID: String) -> FileSyncStatus {
        if conflictPending.contains(fileID) { return .conflict }
        if let fraction = uploadProgressMap[fileID] { return .uploading(fraction) }
        guard let info = tracked[fileID] else { return .remoteOnly }
        if let reason = info.failedReason { return .failed(reason) }
        if info.dirty { return .dirty }
        return .synced
    }

    /// 应用启动时从磁盘恢复跟踪清单
    public func restoreFromDisk() {
        for entry in metadata.loadAll() {
            let key = id(TrackedFile(bucket: entry.bucket, key: entry.key))
            if tracked[key] == nil {
                tracked[key] = TrackedInfo(
                    baseETag: entry.baseETag,
                    syncedMtime: entry.syncedMtime,
                    syncedSize: entry.syncedSize
                )
            }
        }
    }

    /// 用户显式要求重新下载（放弃本地修改）
    public func reloadFromRemote(bucket: String, key: String) async throws -> String {
        let url = workspace.localURL(bucket: bucket, key: key)
        let etag = try await service.download(bucket: bucket, key: key, destination: url, progress: nil)
        track(bucket: bucket, key: key, baseETag: etag)
        return etag
    }

    /// ⌘S / 菜单触发的立即同步：先取远程最新 ETag 作为写入基线（最后写入者胜）
    public func forceUpload(bucket: String, key: String) async {
        let fileID = id(TrackedFile(bucket: bucket, key: key))
        guard tracked[fileID] != nil else { return }
        if let remote = try? await service.headObject(bucket: bucket, key: key) {
            tracked[fileID]?.baseETag = remote.etag
        }
        await performUpload(bucket: bucket, key: key)
    }

    // MARK: - FSEvents 入口

    /// WorkspaceWatcher 的回调入口：相对路径 → bucket/key，防抖后调度上传
    public func handleWorkspaceChanges(_ relativePaths: [String]) {
        var affected = Set<String>()
        for path in relativePaths {
            let parts = path.split(separator: "/").map(String.init)
            guard let bucket = parts.first, parts.count >= 2 else { continue }
            if bucket == WorkspaceWatcher.metadataFolderName { continue }
            if parts.contains(WorkspaceWatcher.tempFolderName) { continue }
            if parts.last == ".DS_Store" { continue }
            let key = parts.dropFirst().joined(separator: "/")
            guard !key.isEmpty, !key.hasSuffix("/") else { continue }
            let fileID = "\(bucket)/\(key)"
            guard tracked[fileID] != nil else { continue }  // 只跟踪我们管理的文件
            affected.insert(fileID)
        }
        for fileID in affected {
            let comps = fileID.split(separator: "/", maxSplits: 1).map(String.init)
            guard comps.count == 2 else { continue }
            let debouncer = debouncers[fileID] ?? Debouncer(delay: .milliseconds(600))
            debouncers[fileID] = debouncer
            let bucket = comps[0], key = comps[1]
            Task { await debouncer.fire { await self.performUpload(bucket: bucket, key: key) } }
        }
    }

    // MARK: - 上传

    private func performUpload(bucket: String, key: String) async {
        let file = TrackedFile(bucket: bucket, key: key)
        let fileID = id(file)
        guard var info = tracked[fileID] else { return }

        let url = workspace.localURL(bucket: bucket, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 本地文件被删 —— 不自动删远程，仅停止跟踪
            tracked[fileID] = nil
            metadata.remove(bucket: bucket, key: key)
            return
        }

        // 指纹未变（下载落盘产生的事件 / rename 报的事件 / 重复事件）→ 跳过上传
        if let mtime = info.syncedMtime, let size = info.syncedSize,
           let current = localFingerprint(bucket: bucket, key: key),
           current.mtime == mtime, current.size == size, !info.dirty {
            return
        }

        if uploading.contains(fileID) {
            info.dirty = true
            tracked[fileID] = info
            return  // 正在传；传完后若 dirty 会再触发
        }
        uploading.insert(fileID)
        uploadProgressMap[fileID] = 0
        defer {
            uploading.remove(fileID)
            uploadProgressMap[fileID] = nil
        }

        info.dirty = false
        tracked[fileID] = info

        do {
            emit(.uploadStarted(file))
            let newETag = try await service.upload(
                bucket: bucket, key: key, source: url, ifMatch: info.baseETag
            ) { [eventHandler] fraction in
                eventHandler(.uploadProgress(file, fraction: fraction))
            }
            uploadProgressMap[fileID] = nil
            if var latest = tracked[fileID] {
                latest.baseETag = newETag
                latest.failedReason = nil
                // 上传成功后此刻的文件即与远程一致，记录指纹
                if let current = localFingerprint(bucket: bucket, key: key) {
                    latest.syncedMtime = current.mtime
                    latest.syncedSize = current.size
                }
                tracked[fileID] = latest
            }
            let settledFingerprint = localFingerprint(bucket: bucket, key: key)
            metadata.record(
                bucket: bucket, key: key, baseETag: newETag,
                syncedMtime: settledFingerprint?.mtime, syncedSize: settledFingerprint?.size
            )
            retryQueue.remove(fileID)
            conflictPending.remove(fileID)
            emit(.uploadDone(file, etag: newETag))
        } catch let error as S3Error {
            switch error {
            case .preconditionFailed:
                conflictPending.insert(fileID)
                uploadProgressMap[fileID] = nil
                await resolveConflict(file: file, fileID: fileID)
            case .network:
                info.failedReason = "网络中断，本地修改已保留"
                tracked[fileID] = info
                retryQueue.insert(fileID)
                emit(.uploadFailed(file, reason: info.failedReason!))
                await setOutage(true)
                scheduleRetry()
            default:
                info.failedReason = "上传失败：\(error)"
                tracked[fileID] = info
                retryQueue.insert(fileID)
                emit(.uploadFailed(file, reason: info.failedReason!))
                scheduleRetry()
            }
        } catch {
            info.failedReason = error.localizedDescription
            tracked[fileID] = info
            retryQueue.insert(fileID)
            emit(.uploadFailed(file, reason: error.localizedDescription))
            scheduleRetry()
        }
    }

    /// 上传成功完成后，若期间又有本地修改（dirty），再传一轮
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            await self.retryFailed()
        }
    }

    public func retryFailed() async {
        let ids = retryQueue
        retryQueue.removeAll()
        for fileID in ids {
            let comps = fileID.split(separator: "/", maxSplits: 1).map(String.init)
            guard comps.count == 2 else { continue }
            await performUpload(bucket: comps[0], key: comps[1])
        }
    }

    /// 断网模拟开关（真实实现里由网络监听触发）
    public func setOutage(_ on: Bool) async {
        if outage == on { return }
        outage = on
        if let mock = service as? MockS3Service {
            await mock.setOutage(on)
        }
        emit(.outageChanged(on))
        if !on {
            await retryFailed()  // 恢复网络，立即续传
        }
    }

    /// 启动系统网络监听：NWPath 恢复 satisfied 时自动续传重试队列。
    /// Mock 断网模拟仍走 setOutage；真实服务的瞬时断网由系统监听驱动。
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
    }

    /// 网络恢复：清失败标记并续传
    private func networkRecovered() async {
        var hadFailures = false
        for (fileID, var info) in tracked {
            if info.failedReason != nil {
                info.failedReason = nil
                tracked[fileID] = info
                hadFailures = true
            }
        }
        emit(.outageChanged(false))
        if hadFailures || !retryQueue.isEmpty {
            await retryFailed()
        }
    }

    // MARK: - 冲突

    private func resolveConflict(file: TrackedFile, fileID: String) async {
        let remote = try? await service.headObject(bucket: file.bucket, key: file.key)
        guard let remote else {
            tracked[fileID]?.failedReason = "远程文件已不存在"
            return
        }
        emit(.conflictDetected(file, localETagBase: remote.etag, remote: remote))
        let choice = await conflictHandler(file, remote.etag, remote)
        switch choice {
        case .overwriteRemote:
            do {
                let url = workspace.localURL(bucket: file.bucket, key: file.key)
                let newETag = try await service.upload(
                    bucket: file.bucket, key: file.key, source: url, ifMatch: remote.etag, progress: nil
                )
                if var info = tracked[fileID] {
                    info.baseETag = newETag
                    info.dirty = false
                    info.failedReason = nil
                    if let current = localFingerprint(bucket: file.bucket, key: file.key) {
                        info.syncedMtime = current.mtime
                        info.syncedSize = current.size
                    }
                    tracked[fileID] = info
                }
                let settledFingerprint = localFingerprint(bucket: file.bucket, key: file.key)
                metadata.record(
                    bucket: file.bucket, key: file.key, baseETag: newETag,
                    syncedMtime: settledFingerprint?.mtime, syncedSize: settledFingerprint?.size
                )
                retryQueue.remove(fileID)
                conflictPending.remove(fileID)
                emit(.uploadDone(file, etag: newETag))
            } catch {
                retryQueue.insert(fileID)
                scheduleRetry()
                emit(.uploadFailed(file, reason: "覆盖远程失败：\(error)"))
            }
        case .reloadRemote:
            do {
                let etag = try await reloadFromRemote(bucket: file.bucket, key: file.key)
                conflictPending.remove(fileID)
                retryQueue.remove(fileID)
                emit(.uploadDone(file, etag: etag))
            } catch {
                emit(.uploadFailed(file, reason: "重新下载失败：\(error)"))
            }
        case .keepLocalOnly:
            if var info = tracked[fileID] {
                info.failedReason = "已保留本地副本（未上传）"
                tracked[fileID] = info
                conflictPending.remove(fileID)
            }
        }
    }
}

import SwiftUI
import R2BOXCore
import R2BOXSync

// MARK: - 连接管理

@MainActor
@Observable
final class ConnectionManager {
    static let shared = ConnectionManager()

    var connections: [Connection] = []
    var selectedID: UUID? {
        didSet {
            if let id = selectedID, id != oldValue {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedConnectionID")
            }
        }
    }

    private let store = ConnectionStore.shared

    var selected: Connection? {
        connections.first { $0.id == selectedID }
    }

    private init() {
        var loaded = store.load()
        // 隐藏内置 Demo：过滤掉历史版本预置的演示连接（endpoint 含 demo. 的 Mock 数据）
        if loaded.contains(where: { $0.endpoint.lowercased().contains("demo.") }) {
            loaded.removeAll { $0.endpoint.lowercased().contains("demo.") }
            store.save(loaded)
        }
        connections = loaded
        if let saved = UserDefaults.standard.string(forKey: "selectedConnectionID"),
           let uuid = UUID(uuidString: saved),
           connections.contains(where: { $0.id == uuid }) {
            selectedID = uuid
        } else {
            selectedID = connections.first?.id
        }
    }

    func add(_ connection: Connection, secretKey: String) {
        connections.append(connection)
        try? store.setSecret(secretKey, for: connection.id)
        store.save(connections)
        selectedID = connection.id
    }

    func update(_ connection: Connection, secretKey: String?) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        if let secretKey, !secretKey.isEmpty {
            try? store.setSecret(secretKey, for: connection.id)
        }
        store.save(connections)
    }

    func delete(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        store.deleteSecret(for: connection.id)
        store.save(connections)
        if selectedID == connection.id {
            selectedID = connections.first?.id
        }
    }

    func secret(for connection: Connection) -> String {
        store.secret(for: connection.id) ?? ""
    }
}

// MARK: - 应用状态机

enum BrowsePhase: Equatable {
    case idle                    // 未选择连接 / bucket
    case loading                 // 加载中
    case loaded                  // 正常显示
    case failed(String)          // 加载失败
}

@MainActor
@Observable
final class AppState: Observable {
    // 连接与导航
    var connection: Connection?
    var buckets: [BucketInfo] = []
    var selectedBucket: String?
    var prefix = ""
    var phase: BrowsePhase = .idle

    // 当前目录内容
    var folders: [String] = []
    var objects: [ObjectEntry] = []
    var selection: ObjectEntry?
    var directoryBusy = false

    // 键盘导航（Finder 式，KeyHandler 驱动）
    /// 文件列表当前选中行（"dir:<prefix>" / "obj:<key>"，与 FileListView.Row.id 一致）
    var selectedRowID: String?

    /// 文件列表行 ID（与 FileListView 渲染顺序一致：文件夹在前、文件在后）
    var listRowIDs: [String] {
        folders.map { "dir:" + $0 } + objects.map { "obj:" + $0.key }
    }

    /// 有弹层（表单/冲突/确认/错误提示）时键盘导航不接管
    var keyboardBlocked: Bool {
        conflictDialog != nil || showConnectionSheet || renameTarget != nil ||
            folderTarget != nil || !deleteTargets.isEmpty || errorMessage != nil
    }

    /// ↑↓ 移动选中行（越界钳制；无选中时从头/尾开始）
    func moveSelection(_ delta: Int) {
        let ids = listRowIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedRowID, let index = ids.firstIndex(of: current) else {
            setRowSelection(delta >= 0 ? ids.first : ids.last)
            return
        }
        let next = max(0, min(ids.count - 1, index + delta))
        setRowSelection(ids[next])
    }

    func setRowSelection(_ id: String?) {
        selectedRowID = id
        if let id, id.hasPrefix("obj:") {
            let key = String(id.dropFirst(4))
            selection = objects.first { $0.key == key }
        } else {
            selection = nil
        }
    }

    /// Enter：文件夹进入，文件用默认编辑器打开
    func activateSelectedRow() {
        guard let id = selectedRowID else { return }
        if id.hasPrefix("dir:") {
            enterFolder(String(id.dropFirst(4)))
        } else if let entry = selection {
            Task { await openInEditor(entry) }
        }
    }

    /// 空格：Quick Look 预览选中文件
    func quickLookSelectedRow() {
        guard let entry = selection else { return }
        quickLook(entry)
    }

    // 传输列表
    var transfers: [TransferItem] = []
    var outage = false
    var lastSavedKey: String?
    /// 打开/操作失败的浮出提示（非空时显示横幅，用户关闭后清空）
    var errorMessage: String?
    /// key: "bucket/key" → 文件同步状态（由引擎事件镜像到主线程）
    var syncStates: [String: FileSyncStatus] = [:]

    // 弹窗
    var conflictDialog: ConflictContext?
    var showConnectionSheet = false
    var editingConnection: Connection?
    var newConnectionName = ""
    var newConnectionEndpoint = ""
    var newConnectionRegion = "auto"
    var newConnectionAccessKey = ""
    var newConnectionSecretKey = ""
    var newConnectionPathStyle = true

    var folderTarget: String?   // 新建文件夹
    var renameTarget: ObjectEntry?
    var deleteTargets: [ObjectEntry] = []

    // 依赖
    let workspace: Workspace
    let watcher = WatcherHandle()
    var engine: SyncEngine?
    var service: S3Service?

    /// 正常启动用全局工作区；selftest 传临时工作区避免污染真实数据
    init(workspace: Workspace = Workspace()) {
        self.workspace = workspace
    }

    struct ConflictContext: Identifiable {
        let id = UUID()
        let file: TrackedFile
        let remote: ObjectEntry
    }

    struct TransferItem: Identifiable, Equatable {
        let id: String
        var name: String
        var kind: Kind
        var fraction: Double
        var state: State

        enum Kind: Equatable { case upload, download }
        enum State: Equatable { case active, done, failed, conflict }

        static func == (lhs: TransferItem, rhs: TransferItem) -> Bool {
            lhs.id == rhs.id && lhs.fraction == rhs.fraction && lhs.state == rhs.state
        }
    }

    // MARK: 生命周期

    func connect(to connection: Connection) {
        NSLog("[R2BOX] connect: \(connection.name) bucket=\(connection.bucket)")
        ConnectionManager.shared.selectedID = connection.id
        self.connection = connection
        let service = S3ServiceFactory.service(for: connection)
        self.service = service
        let engine = SyncEngine(workspace: workspace, service: service)
        engine.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        engine.conflictHandler = { [weak self] file, _, remote in
            guard let self else { return .keepLocalOnly }
            return await self.askConflict(file: file, remote: remote)
        }
        self.engine = engine

        // FSEvents 监听
        watcher.start(workspace: workspace) { [engine] paths in
            Task { await engine.handleWorkspaceChanges(paths) }
        }

        Task { await engine.restoreFromDisk() }
        Task { await engine.startNetworkMonitoring() }
        // 恢复上次会话的同步状态镜像
        Task {
            let statuses = await engine.allStatuses()
            for (fileID, status) in statuses {
                syncStates[fileID] = status
            }
        }
        Task { await loadBuckets() }
    }

    func shutdown() {
        watcher.stop()
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .uploadStarted(let file):
            syncStates["\(file.bucket)/\(file.key)"] = .uploading(0)
            upsertTransfer(file: file, kind: .upload, fraction: 0, state: .active)
        case .uploadProgress(let file, let fraction):
            syncStates["\(file.bucket)/\(file.key)"] = .uploading(fraction)
            upsertTransfer(file: file, kind: .upload, fraction: fraction, state: .active)
        case .uploadDone(let file, _):
            syncStates["\(file.bucket)/\(file.key)"] = .synced
            upsertTransfer(file: file, kind: .upload, fraction: 1, state: .done)
            lastSavedKey = file.key
            if file.key == selection?.key, let bucket = selectedBucket, file.bucket == bucket {
                Task { await refreshCurrent(quiet: true) }
            }
            scheduleTransferCleanup(id: "\(file.bucket)/\(file.key)")
        case .uploadFailed(let file, let reason):
            syncStates["\(file.bucket)/\(file.key)"] = .failed(reason)
            upsertTransfer(file: file, kind: .upload, fraction: 1, state: .failed)
            scheduleTransferCleanup(id: "\(file.bucket)/\(file.key)")
        case .conflictDetected(let file, _, let remote):
            syncStates["\(file.bucket)/\(file.key)"] = .conflict
            upsertTransfer(file: file, kind: .upload, fraction: 1, state: .conflict)
            // 同一文件的重复冲突事件不重复弹窗
            if conflictDialog?.file.key != file.key {
                conflictDialog = ConflictContext(file: file, remote: remote)
            }
        case .outageChanged(let on):
            outage = on
        }
    }

    /// UI 查询文件同步状态（"bucket/key" 镜像，主线程可同步读）
    func statusPublic(bucket: String, key: String) -> FileSyncStatus {
        syncStates["\(bucket)/\(key)"] ?? .remoteOnly
    }

    /// ⌘S：立即同步选中的文件
    func syncNowEntry(_ entry: ObjectEntry) async {
        guard let bucket = selectedBucket, let engine else { return }
        await engine.forceUpload(bucket: bucket, key: entry.key)
    }

    /// 冲突弹窗（模态等待用户选择）
    private func askConflict(file: TrackedFile, remote: ObjectEntry) async -> ConflictChoice {
        conflictDialog = ConflictContext(file: file, remote: remote)
        return await withCheckedContinuation { continuation in
            self.pendingConflictResumption = continuation
        }
    }

    private var pendingConflictResumption: CheckedContinuation<ConflictChoice, Never>?

    func resolveConflict(_ choice: ConflictChoice) {
        conflictDialog = nil
        pendingConflictResumption?.resume(returning: choice)
        pendingConflictResumption = nil
    }

    // MARK: 数据加载

    func loadBuckets() async {
        guard let service else { return }
        NSLog("[R2BOX] loadBuckets begin")
        phase = .loading
        // 连接限定了储存桶：跳过 ListBuckets（单桶授权 Token 没有该权限），直接用该桶
        let pinned = connection?.bucket.trimmingCharacters(in: .whitespaces) ?? ""
        if !pinned.isEmpty {
            buckets = [BucketInfo(name: pinned)]
            selectedBucket = pinned
            await loadPrefix(bucket: pinned, prefix: "")
            return
        }
        do {
            buckets = try await service.listBuckets()
            let names = buckets.map { $0.name }
            NSLog("[R2BOX] loadBuckets ok: \(names)")
            if selectedBucket == nil || !buckets.contains(where: { $0.name == selectedBucket }) {
                selectedBucket = buckets.first?.name
            }
            if let bucket = selectedBucket {
                await loadPrefix(bucket: bucket, prefix: "")
            } else {
                phase = .loaded
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func loadPrefix(bucket: String, prefix: String) async {
        guard let service else { return }
        directoryBusy = true
        defer { directoryBusy = false }
        do {
            let (folders, objects) = try await service.listObjects(bucket: bucket, prefix: prefix)
            let folderCount = folders.count, objectCount = objects.count
            NSLog("[R2BOX] loadPrefix \(bucket)/\(prefix): \(folderCount) folders, \(objectCount) objects")
            self.prefix = prefix
            self.folders = folders
            self.objects = objects
            selection = nil
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func refreshCurrent(quiet: Bool = false) async {
        guard let bucket = selectedBucket else { return }
        if !quiet { directoryBusy = true }
        defer { if !quiet { directoryBusy = false } }
        guard let service else { return }
        do {
            let (folders, objects) = try await service.listObjects(bucket: bucket, prefix: prefix)
            self.folders = folders
            self.objects = objects
            if let sel = selection, !objects.contains(where: { $0.key == sel.key }) {
                selection = objects.first { $0.key == sel.key } // 更新 etag/size
                if self.selection?.etag != sel.etag { self.selection = self.selection }
            }
        } catch {
            if !quiet { phase = .failed(String(describing: error)) }
        }
    }

    /// ⌘数字 / 侧栏点击：切换到指定储存桶（回到根目录，清空当前选中）
    func selectBucket(_ name: String) {
        guard buckets.contains(where: { $0.name == name }) else { return }
        selectedBucket = name
        selection = nil
        selectedRowID = nil
        Task { await loadPrefix(bucket: name, prefix: "") }
    }

    func enterFolder(_ folder: String) {
        guard let bucket = selectedBucket else { return }
        selectedRowID = nil
        Task { await loadPrefix(bucket: bucket, prefix: folder) }
    }

    func navigateUp() {
        guard !prefix.isEmpty else { return }
        var comps = prefix.split(separator: "/").map(String.init)
        comps.removeLast()
        let newPrefix = comps.isEmpty ? "" : comps.joined(separator: "/") + "/"
        guard let bucket = selectedBucket else { return }
        selection = nil
        selectedRowID = nil
        Task { await loadPrefix(bucket: bucket, prefix: newPrefix) }
    }

    var breadcrumbParts: [(name: String, prefix: String)] {
        var parts: [(String, String)] = [(selectedBucket ?? "", "")]
        var acc = ""
        for comp in prefix.split(separator: "/") {
            acc += comp + "/"
            parts.append((String(comp), acc))
        }
        return parts
    }

    // MARK: 打开文件（下载 → NSWorkspace 打开）

    func openInEditor(_ entry: ObjectEntry) async {
        guard let bucket = selectedBucket, let service, let engine else { return }
        let url = workspace.localURL(bucket: bucket, key: entry.key)
        do {
            // 决策：直接用本地副本，还是重新下载（本地缺失/0 字节残留/远程已更新且本地无修改）
            let plan = await openPlan(for: entry, bucket: bucket, url: url)
            let etag: String
            switch plan {
            case .useLocal:
                // 本地与远程一致：直接打开。基线维持跟踪记录原值——
                // 列表里的 etag 可能过期（页面未刷新），用它重登会破坏 If-Match 基线
                etag = entry.etag
            case .useLocalExpectConflict:
                // 远程已变且本地可能有未同步修改：打开本地、保留旧基线，
                // 下次保存上传命中 If-Match 失败 → 冲突弹窗（绝不静默覆盖）
                etag = entry.etag
            case .downloadRemote:
                upsertDownload(file: entry, bucket: bucket, fraction: 0, state: .active)
                etag = try await service.download(
                    bucket: bucket, key: entry.key, destination: url
                ) { [weak self] fraction in
                    Task { @MainActor in
                        self?.upsertDownload(file: entry, bucket: bucket, fraction: fraction, state: .active)
                    }
                }
                upsertDownload(file: entry, bucket: bucket, fraction: 1, state: .done)
                scheduleTransferCleanup(id: "\(bucket)/\(entry.key)")
            }
            switch plan {
            case .downloadRemote:
                await engine.track(bucket: bucket, key: entry.key, baseETag: etag)
                syncStates["\(bucket)/\(entry.key)"] = .synced
            case .useLocal:
                // 打开本地副本不动跟踪记录；UI 状态如当前不是失败/冲突则显示已同步
                if case .failed = syncStates["\(bucket)/\(entry.key)"] {} else {
                    syncStates["\(bucket)/\(entry.key)"] = .synced
                }
            case .useLocalExpectConflict:
                break  // 状态维持原样（保留旧基线，等保存触发冲突）
            }
            NSWorkspace.shared.open(url)
        } catch {
            // 打开失败必须浮出：标记失败状态 + 提示条，绝不静默（否则用户以为"已同步"而实际没打开）
            syncStates["\(bucket)/\(entry.key)"] = .failed(Self.describe(error))
            upsertDownload(file: entry, bucket: bucket, fraction: 1, state: .failed)
            scheduleTransferCleanup(id: "\(bucket)/\(entry.key)")
            errorMessage = "无法打开「\(entry.key.components(separatedBy: "/").last ?? entry.key)」：\(Self.describe(error))"
        }
    }

    /// 面向用户的错误描述
    private static func describe(_ error: Error) -> String {
        if let e = error as? S3Error {
            switch e {
            case .network: return "网络不可用"
            case .notFound: return "对象不存在"
            case .accessDenied: return "访问被拒绝（检查 Access Key / Secret Key）"
            case .preconditionFailed: return "远程已被修改"
            case .unknown(let m): return m
            }
        }
        return String(describing: error)
    }

    /// 打开决策：结合跟踪基线 / 本地指纹 / 远程 ETag 判断本地副本是否可直接打开
    private func openPlan(for entry: ObjectEntry, bucket: String, url: URL) async -> OpenPlan {
        let info = await engine?.trackedInfo(bucket: bucket, key: entry.key)
        var localMtime: Date?
        var localSize: Int64?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            localMtime = attrs[.modificationDate] as? Date
            localSize = (attrs[.size] as? NSNumber)?.int64Value
        }
        return OpenDecision.plan(
            localExists: FileManager.default.fileExists(atPath: url.path),
            remoteSize: entry.size,
            trackedBaseETag: info?.baseETag,
            currentETag: entry.etag,
            syncedMtime: info?.syncedMtime,
            syncedSize: info?.syncedSize,
            localMtime: localMtime,
            localSize: localSize
        )
    }

    func quickLook(_ entry: ObjectEntry) {
        guard let bucket = selectedBucket else { return }
        let url = workspace.localURL(bucket: bucket, key: entry.key)
        if FileManager.default.fileExists(atPath: url.path) {
            // 与打开决策同一套新鲜度判断：本地副本陈旧时先走下载
            Task {
                let plan = await openPlan(for: entry, bucket: bucket, url: url)
                if plan == .downloadRemote {
                    // 用下载返回的真实 ETag 登记基线（列表值可能过期）
                    let etag = try? await service?.download(bucket: bucket, key: entry.key, destination: url, progress: nil)
                    if let etag {
                        await engine?.track(bucket: bucket, key: entry.key, baseETag: etag)
                    }
                }
                await MainActor.run { QLPreviewPanelHelper.shared.toggle(url: url) }
            }
        } else {
            Task {
                await openInEditor(entry)   // 下载后打开（Quick Look 场景同样可用）
                await MainActor.run { QLPreviewPanelHelper.shared.toggle(url: url) }
            }
        }
    }

    // MARK: 操作

    func delete(_ entries: [ObjectEntry]) async {
        guard let bucket = selectedBucket, let service else { return }
        for entry in entries {
            let isFolder = entry.key.hasSuffix("/")
            try? await service.delete(bucket: bucket, key: entry.key, isFolder: isFolder)
            if !isFolder {
                await engine?.untrack(bucket: bucket, key: entry.key)
                workspace.removeLocal(bucket: bucket, key: entry.key)
                syncStates["\(bucket)/\(entry.key)"] = nil
            }
        }
        await refreshCurrent()
    }

    func rename(_ entry: ObjectEntry, newName: String) async {
        guard let bucket = selectedBucket, let service else { return }
        let isFolder = entry.key.hasSuffix("/")
        try? await service.move(bucket: bucket, key: entry.key, isFolder: isFolder, newKeyName: newName)
        await refreshCurrent()
    }

    func createFolder(_ name: String) async {
        guard let bucket = selectedBucket, let service else { return }
        try? await service.createFolder(bucket: bucket, prefix: prefix + name + "/")
        await refreshCurrent()
    }

    func uploadFileURLs(_ urls: [URL]) async {
        guard let bucket = selectedBucket, let service else { return }
        for url in urls where !url.hasDirectoryPath {
            let name = url.lastPathComponent
            let destKey = prefix + name
            let tempEntry = ObjectEntry(
                key: destKey, size: 0, lastModified: Date(), etag: ""
            )
            upsertUpload(file: tempEntry, bucket: bucket, fraction: 0, state: .active)
            do {
                let etag = try await service.upload(
                    bucket: bucket, key: destKey, source: url, ifMatch: nil
                ) { [weak self] fraction in
                    Task { @MainActor in
                        self?.upsertUpload(file: tempEntry, bucket: bucket, fraction: fraction, state: .active)
                    }
                }
                upsertUpload(file: tempEntry, bucket: bucket, fraction: 1, state: .done)
                _ = etag
                scheduleTransferCleanup(id: "\(bucket)/\(destKey)")
            } catch {
                upsertUpload(file: tempEntry, bucket: bucket, fraction: 1, state: .failed)
                scheduleTransferCleanup(id: "\(bucket)/\(destKey)")
            }
        }
        await refreshCurrent()
    }

    // MARK: 调试

    func simulateRemoteModify() async {
        guard let entry = selection, let bucket = selectedBucket, let service else { return }
        if let mock = service as? MockS3Service {
            _ = try? await mock.simulateRemoteModify(bucket: bucket, key: entry.key)
        }
        await refreshCurrent(quiet: true)
    }

    func setOutage(_ on: Bool) async {
        await engine?.setOutage(on)
    }

    func syncNow() async {
        guard let entry = selection, let bucket = selectedBucket, let engine else { return }
        await engine.forceUpload(bucket: bucket, key: entry.key)
    }

    // MARK: 传输列表辅助

    private func upsertTransfer(file: TrackedFile, kind: TransferItem.Kind, fraction: Double, state: TransferItem.State) {
        let id = "\(file.bucket)/\(file.key)"
        let item = TransferItem(id: id, name: (file.key as NSString).lastPathComponent, kind: kind, fraction: fraction, state: state)
        upsert(item)
    }

    private func upsertDownload(file: ObjectEntry, bucket: String, fraction: Double, state: TransferItem.State) {
        let item = TransferItem(id: "\(bucket)/\(file.key)", name: file.fileName, kind: .download, fraction: fraction, state: state)
        upsert(item)
    }

    private func upsertUpload(file: ObjectEntry, bucket: String, fraction: Double, state: TransferItem.State) {
        let item = TransferItem(id: "\(bucket)/\(file.key)", name: file.fileName, kind: .upload, fraction: fraction, state: state)
        upsert(item)
    }

    private func upsert(_ item: TransferItem) {
        if let idx = transfers.firstIndex(where: { $0.id == item.id }) {
            // 完成态不回退到进行态
            if transfers[idx].state == .done && item.state == .active { return }
            transfers[idx] = item
        } else {
            transfers.insert(item, at: 0)
        }
    }

    private func scheduleTransferCleanup(id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.transfers.removeAll { $0.id == id && ($0.state == .done) }
        }
    }
}

/// FSEvents 监听的持有者（AppState 重连时复用）
@MainActor
final class WatcherHandle {
    private var watcher: WorkspaceWatcher?

    func start(workspace: Workspace, onChange: @escaping @Sendable ([String]) -> Void) {
        stop()
        let watcher = WorkspaceWatcher(watch: workspace.baseURL) { paths in
            // 过滤元数据目录
            let filtered = paths.filter { !$0.hasPrefix(WorkspaceWatcher.metadataFolderName + "/") }
            onChange(filtered)
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }
}

import Quartz

/// Quick Look 面板辅助
@MainActor
final class QLPreviewPanelHelper: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QLPreviewPanelHelper()
    private var urls: [URL] = []

    func toggle(url: URL) {
        urls = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as QLPreviewItem
    }
}

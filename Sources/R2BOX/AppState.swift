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
    @ObservationIgnored var focusFileTableOnLoad = false

    /// 文件表格当前选中行（"dir:<prefix>" / "obj:<key>"）。
    var selectedRowID: String?

    func setRowSelection(_ id: String?) {
        if let id, id.hasPrefix("dir:") {
            selectedRowID = folders.contains(String(id.dropFirst(4))) ? id : nil
            selection = nil
        } else if let id, let object = objects.first(where: { "obj:" + $0.key == id }) {
            selectedRowID = id
            selection = object
        } else {
            selectedRowID = nil
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
    private(set) var conflictDialog: ConflictContext?
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

    func presentConnectionSheet(editing connection: Connection? = nil) {
        editingConnection = connection
        showConnectionSheet = true
    }

    // 依赖
    let workspaceRoot: Workspace
    private(set) var workspace: Workspace
    let watcher = WatcherHandle()
    var engine: SyncEngine?
    var service: S3Service?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequestID: UUID?
    @ObservationIgnored private var syncEngines: [URL: SyncEngine] = [:]
    @ObservationIgnored private var pendingConflicts: [PendingConflict] = []
    @ObservationIgnored private var dismissingConflict = false

    /// 正常启动用全局工作区；selftest 传临时工作区避免污染真实数据
    init(workspace: Workspace = Workspace()) {
        self.workspaceRoot = workspace
        self.workspace = workspace
    }

    struct ConflictContext: Identifiable {
        let id = UUID()
        let file: TrackedFile
        let remote: ObjectEntry
    }

    private struct PendingConflict {
        let context: ConflictContext
        let continuation: CheckedContinuation<ConflictChoice, Never>
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

    func connect(to connection: Connection, focusFileTable: Bool = false, persistSelection: Bool = true) {
        NSLog("[R2BOX] connect: \(connection.name) bucket=\(connection.bucket)")
        if persistSelection { ConnectionManager.shared.selectedID = connection.id }
        self.connection = connection
        buckets = []
        let pinned = connection.bucket.trimmingCharacters(in: .whitespaces)
        selectedBucket = pinned.isEmpty ? nil : pinned
        let scopedWorkspace = workspaceRoot.forConnection(connection)
        let scope = scopedWorkspace.baseURL
        if workspace.baseURL != scope {
            watcher.stop()
            dismissPendingConflicts()
            syncStates = [:]
            transfers = []
            outage = false
        }
        workspace = scopedWorkspace
        let engine: SyncEngine
        if let existing = syncEngines[scope] {
            engine = existing
        } else {
            let service = S3ServiceFactory.service(for: connection)
            engine = SyncEngine(workspace: scopedWorkspace, service: service)
            engine.eventHandler = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.workspace.baseURL == scope else { return }
                    self.handle(event)
                }
            }
            engine.conflictHandler = { [weak self] file, _, remote in
                guard let self else { return .keepLocalOnly }
                return await self.askConflict(file: file, remote: remote, scope: scope)
            }
            syncEngines[scope] = engine
        }
        self.engine = engine
        let service = engine.service
        self.service = service

        Task {
            await engine.restoreFromDisk()
            let statuses = await engine.allStatuses()
            let hasOutage = await engine.hasOutage
            guard self.engine === engine else { return }
            for (fileID, status) in statuses where syncStates[fileID] == nil {
                syncStates[fileID] = status
            }
            outage = hasOutage
            watcher.start(workspace: scopedWorkspace) { paths in
                Task { await engine.handleWorkspaceChanges(paths) }
            }
            await engine.startNetworkMonitoring()
        }
        beginNavigation(to: "", focusFileTable: focusFileTable) {
            await self.loadBuckets(using: service)
        }
    }

    func shutdown() {
        watcher.stop()
        dismissPendingConflicts()
        navigationTask?.cancel()
        navigationTask = nil
        connection = nil
        service = nil
        engine = nil
        workspace = workspaceRoot
        syncStates = [:]
        transfers = []
        outage = false
        buckets = []
        selectedBucket = nil
        resetDirectory(to: "")
        focusFileTableOnLoad = false
        phase = .idle
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
        case .conflictDetected(let file, _, _):
            syncStates["\(file.bucket)/\(file.key)"] = .conflict
            upsertTransfer(file: file, kind: .upload, fraction: 1, state: .conflict)
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

    private func askConflict(file: TrackedFile, remote: ObjectEntry, scope: URL) async -> ConflictChoice {
        guard workspace.baseURL == scope else { return .keepLocalOnly }
        return await withCheckedContinuation { continuation in
            let context = ConflictContext(file: file, remote: remote)
            pendingConflicts.append(PendingConflict(context: context, continuation: continuation))
            presentNextConflict()
        }
    }

    func presentNextConflict() {
        guard conflictDialog == nil, !dismissingConflict, !showConnectionSheet else { return }
        conflictDialog = pendingConflicts.first?.context
    }

    func resolveConflict(_ choice: ConflictChoice, id: UUID) {
        guard conflictDialog?.id == id, pendingConflicts.first?.context.id == id else { return }
        let pending = pendingConflicts.removeFirst()
        dismissingConflict = true
        conflictDialog = nil
        pending.continuation.resume(returning: choice)
    }

    func conflictDialogDidDismiss() {
        if let id = conflictDialog?.id { resolveConflict(.keepLocalOnly, id: id) }
        dismissingConflict = false
        presentNextConflict()
    }

    private func dismissPendingConflicts() {
        if conflictDialog != nil { dismissingConflict = true }
        conflictDialog = nil
        for pending in pendingConflicts {
            pending.continuation.resume(returning: .keepLocalOnly)
        }
        pendingConflicts = []
    }

    // MARK: 数据加载

    private func loadBuckets(using service: any S3Service) async {
        guard !Task.isCancelled else { return }
        NSLog("[R2BOX] loadBuckets begin")
        // 连接限定了储存桶：跳过 ListBuckets（单桶授权 Token 没有该权限），直接用该桶
        if let pinned = selectedBucket {
            buckets = [BucketInfo(name: pinned)]
            await loadPrefix(bucket: pinned, prefix: "", using: service)
            return
        }
        do {
            let available = try await service.listBuckets()
            try Task.checkCancellation()
            buckets = available
            selectedBucket = available.first?.name
            if let bucket = selectedBucket {
                await loadPrefix(bucket: bucket, prefix: "", using: service)
            } else {
                phase = .loaded
            }
        } catch {
            if !Task.isCancelled { phase = .failed(Self.describe(error)) }
        }
    }

    private func loadPrefix(bucket: String, prefix: String, using service: any S3Service) async {
        guard !Task.isCancelled else { return }
        do {
            let (folders, objects) = try await service.listObjects(bucket: bucket, prefix: prefix)
            try Task.checkCancellation()
            let folderCount = folders.count, objectCount = objects.count
            NSLog("[R2BOX] loadPrefix \(bucket)/\(prefix): \(folderCount) folders, \(objectCount) objects")
            self.folders = folders
            self.objects = objects
            phase = .loaded
        } catch {
            if !Task.isCancelled { phase = .failed(Self.describe(error)) }
        }
    }

    func refreshCurrent(quiet: Bool = false) async {
        guard phase == .loaded, let bucket = selectedBucket, let service else { return }
        let requestID = UUID()
        refreshRequestID = requestID
        directoryBusy = directoryBusy || !quiet
        defer {
            if refreshRequestID == requestID {
                refreshRequestID = nil
                directoryBusy = false
            }
        }
        do {
            let (folders, objects) = try await service.listObjects(bucket: bucket, prefix: prefix)
            guard refreshRequestID == requestID else { return }
            self.folders = folders
            self.objects = objects
            setRowSelection(selectedRowID)
        } catch {
            if refreshRequestID == requestID, !quiet {
                errorMessage = Self.describe(error)
            }
        }
    }

    /// ⌘数字 / 侧栏点击：切换到指定储存桶（回到根目录，清空当前选中）
    func selectBucket(_ name: String) {
        guard buckets.contains(where: { $0.name == name }) else { return }
        selectedBucket = name
        enterFolder("", focusFileTable: false)
    }

    func enterFolder(_ folder: String, focusFileTable: Bool = true) {
        guard let bucket = selectedBucket, let service else { return }
        beginNavigation(to: folder, focusFileTable: focusFileTable) {
            await self.loadPrefix(bucket: bucket, prefix: folder, using: service)
        }
    }

    private func beginNavigation(
        to prefix: String,
        focusFileTable: Bool,
        load: @escaping @MainActor () async -> Void
    ) {
        navigationTask?.cancel()
        resetDirectory(to: prefix)
        focusFileTableOnLoad = focusFileTable
        phase = .loading
        navigationTask = Task { await load() }
    }

    private func resetDirectory(to prefix: String) {
        self.prefix = prefix
        folders = []
        objects = []
        setRowSelection(nil)
        refreshRequestID = nil
        directoryBusy = false
        lastSavedKey = nil
    }

    func retryBrowsing() {
        if selectedBucket != nil {
            enterFolder(prefix)
        } else if let connection {
            connect(to: connection)
        }
    }

    func navigateUp() {
        guard let parent = prefix.dropLast().lastIndex(of: "/") else {
            if !prefix.isEmpty { enterFolder("") }
            return
        }
        enterFolder(String(prefix[...parent]))
    }

    var breadcrumbParts: [(name: String, prefix: String)] {
        var parts: [(String, String)] = [(selectedBucket ?? "", "")]
        guard !prefix.isEmpty else { return parts }
        var acc = ""
        for comp in prefix.dropLast().split(separator: "/", omittingEmptySubsequences: false) {
            acc += comp + "/"
            parts.append((comp.isEmpty ? "/" : String(comp), acc))
        }
        return parts
    }

    // MARK: 打开与预览文件

    func openInEditor(_ entry: ObjectEntry) async {
        if let url = await prepareLocalCopy(of: entry) {
            NSWorkspace.shared.open(url)
        }
    }

    func quickLook(_ entry: ObjectEntry) {
        Task {
            if let url = await prepareLocalCopy(of: entry) {
                QLPreviewPanelHelper.shared.toggle(url: url)
            }
        }
    }

    func prepareLocalCopy(of entry: ObjectEntry) async -> URL? {
        guard let bucket = selectedBucket, let engine else { return nil }
        let fileID = "\(bucket)/\(entry.key)"
        do {
            let local = try await engine.prepareLocalCopy(bucket: bucket, entry: entry) { [weak self, weak engine] fraction in
                Task { @MainActor in
                    guard let self, let engine, self.engine === engine else { return }
                    self.upsertDownload(file: entry, bucket: bucket, fraction: fraction, state: .active)
                }
            }
            guard self.engine === engine, let local else { return nil }
            if local.downloaded {
                upsertDownload(file: entry, bucket: bucket, fraction: 1, state: .done)
                scheduleTransferCleanup(id: fileID)
                syncStates[fileID] = .synced
            }
            return local.url
        } catch {
            guard self.engine === engine else { return nil }
            syncStates[fileID] = .failed(Self.describe(error))
            upsertDownload(file: entry, bucket: bucket, fraction: 1, state: .failed)
            scheduleTransferCleanup(id: fileID)
            errorMessage = "无法读取「\(entry.fileName)」：\(Self.describe(error))"
            return nil
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
        return error.localizedDescription
    }

    // MARK: 操作

    func delete(_ entries: [ObjectEntry]) async {
        guard let bucket = selectedBucket, let service, let engine else { return }
        let workspace = self.workspace
        for entry in entries {
            let isFolder = entry.key.hasSuffix("/")
            do {
                try await service.delete(bucket: bucket, key: entry.key, isFolder: isFolder)
            } catch {
                if self.engine === engine { errorMessage = Self.describe(error) }
                continue
            }
            if !isFolder {
                await engine.untrack(bucket: bucket, key: entry.key)
                workspace.removeLocal(bucket: bucket, key: entry.key)
                if self.engine === engine { syncStates["\(bucket)/\(entry.key)"] = nil }
            }
        }
        if self.engine === engine { await refreshCurrent() }
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
        let destinationPrefix = prefix
        for url in urls where !url.hasDirectoryPath {
            let name = url.lastPathComponent
            let destKey = destinationPrefix + name
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
        let scope = workspace.baseURL
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.workspace.baseURL == scope else { return }
            self.transfers.removeAll { $0.id == id && $0.state == .done }
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

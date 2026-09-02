import Foundation
import R2BOXCore
import R2BOXSync

/// 进程内端到端自检：`R2BOX --selftest`
/// 在真实 App 进程里走完整链路（连接 → 列目录 → 下载 → NSWorkspace 打开 →
/// 本地修改 → FSEvents 触发自动上传 → 远程读回验证 → 冲突），结果写到 stdout 与日志文件。
enum SelfTest {
    /// 自检专用临时工作区（finish 时清理），避免污染真实用户工作区。
    /// 符号链接（/var→/private/var）由 WorkspaceWatcher 在监听侧归一化，这里无需处理。
    private static let tempWorkspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("r2box-selftest-\(UUID().uuidString)", isDirectory: true)

    static func run() {
        Task.detached {
            do {
                try await execute()
                finish("PASS")
            } catch {
                finish("FAIL: \(error)")
            }
        }
    }

    private static func log(_ s: String) {
        let line = "[selftest] \(s)"
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func finish(_ result: String) {
        log("RESULT: \(result)")
        try? FileManager.default.removeItem(at: tempWorkspace)
        // 给缓冲区一点时间
        Thread.sleep(forTimeInterval: 0.5)
        exit(result.hasPrefix("PASS") ? 0 : 1)
    }

    private static func waitUntil(timeout: Double = 15, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw SelfTestError.timeout
    }

    enum SelfTestError: Error { case timeout, assertion(String) }

    private static func execute() async throws {
        // 隔离环境：独立 AppState + 临时工作区 + 显式 Demo 连接（Mock 服务），不触碰真实连接与工作区
        let state = await MainActor.run { AppState(workspace: Workspace(baseURL: tempWorkspace)) }
        let connection = Connection(
            name: "selftest", endpoint: "https://demo.r2.cloudflarestorage.com", region: "auto", accessKeyID: "k", pathStyle: true
        )
        log("connect: \(connection.name) workspace=\(tempWorkspace.path)")
        await MainActor.run { state.connect(to: connection) }

        // 1. 列 Bucket + 根目录
        try await waitUntil { await MainActor.run { !state.buckets.isEmpty } }
        let bucketNames = await MainActor.run { state.buckets.map(\.name) }
        log("buckets: \(bucketNames)")
        guard bucketNames.contains("app-config") else { throw SelfTestError.assertion("缺少 app-config") }

        try await waitUntil { await MainActor.run { !state.objects.isEmpty || !state.folders.isEmpty } }
        let (folders, objects) = await MainActor.run { (state.folders, state.objects) }
        let objectKeys = objects.map { $0.key }
        log("root: folders=\(folders) objects=\(objectKeys)")
        guard objects.contains(where: { $0.key == "config.yaml" }) else { throw SelfTestError.assertion("根目录缺少 config.yaml") }

        // 2. 双击 → 下载 + NSWorkspace 打开
        let entry = objects.first { $0.key == "config.yaml" }!
        log("openInEditor: \(entry.key)")
        await MainActor.run { Task { await state.openInEditor(entry) } }
        let state2 = state
        try await waitUntil {
            let tracked = await MainActor.run { state2.syncStates["app-config/config.yaml"] }
            return tracked == .synced
        }
        let localURL = state.workspace.localURL(bucket: "app-config", key: "config.yaml")
        guard FileManager.default.fileExists(atPath: localURL.path) else { throw SelfTestError.assertion("本地缓存未落盘") }
        log("downloaded + opened via NSWorkspace: \(localURL.path)")

        // 3. 模拟编辑器 ⌘S：修改本地文件 → FSEvents → 自动上传
        let original = try String(contentsOf: localURL, encoding: .utf8)
        try (original + "\n# selftest edit \(Int(Date().timeIntervalSince1970))\n").write(to: localURL, atomically: true, encoding: .utf8)
        log("local edit written, waiting auto-upload (FSEvents)…")

        let service = try await state.engineService()
        var uploadedETag: String?
        try await waitUntil {
            let remote = try? await service.headObject(bucket: "app-config", key: "config.yaml")
            guard let remote else { return false }
            let content = try? await service.downloadText(bucket: "app-config", key: "config.yaml")
            if let content, content.contains("selftest edit") {
                uploadedETag = remote.etag
                return true
            }
            return false
        }
        log("auto-upload verified: remote contains local edit, etag=\(uploadedETag ?? "?")")

        // 静默期：等待 FSEvents 迟到事件 / 防抖尾全部落定
        try await Task.sleep(for: .seconds(2))

        // 4. 冲突：远程被他人修改 → 本地再改 → 引擎应发现 preconditionFailed 并弹冲突（handler 默认保留本地）
        if let mock = service as? MockS3Service {
            _ = try await mock.simulateRemoteModify(bucket: "app-config", key: "config.yaml")
        }
        let current = try String(contentsOf: localURL, encoding: .utf8)
        let conflictMarker = "selftest conflict edit \(Int(Date().timeIntervalSince1970))"
        try (current + "\n# \(conflictMarker)\n").write(to: localURL, atomically: true, encoding: .utf8)
        log("conflict edit written, waiting engine…")
        try await waitUntil {
            let status = await MainActor.run { state2.syncStates["app-config/config.yaml"] }
            if case .conflict = status { return true }
            if case .failed = status { return true }
            return false
        }
        let status = await MainActor.run { state2.syncStates["app-config/config.yaml"] }
        log("conflict detected, status=\(String(describing: status))")

        // 静默期后确认远程始终没有被冲突版本覆盖
        try await Task.sleep(for: .seconds(2))
        let remoteNow = try? await service.downloadText(bucket: "app-config", key: "config.yaml")
        if let remoteNow, remoteNow.contains(conflictMarker) {
            throw SelfTestError.assertion("冲突时本地版本不应被自动覆盖")
        }
        log("remote not overwritten by conflict edit ✓")
    }
}

extension AppState {
    /// 自检用的引擎服务句柄
    func engineService() async throws -> S3Service {
        guard let engine = self.engine else { throw SelfTest.SelfTestError.assertion("engine 未初始化") }
        return await engine.serviceRef()
    }
}

extension SyncEngine {
    func serviceRef() -> S3Service { service }
}

extension S3Service {
    /// 测试辅助：以文本读回远程对象（Mock 存储小文件）
    func downloadText(bucket: String, key: String) async throws -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await download(bucket: bucket, key: key, destination: tmp, progress: nil)
        return try? String(contentsOf: tmp, encoding: .utf8)
    }
}

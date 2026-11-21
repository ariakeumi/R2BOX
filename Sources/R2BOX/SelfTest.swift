import Foundation
import R2BOXCore
import R2BOXSync

/// 进程内端到端自检：`R2BOX --selftest`
/// 在 App 进程中验证连接、下载、FSEvents 自动上传和冲突处理，结果写到 stdout 和 stderr。
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
        await MainActor.run { state.connect(to: connection, persistSelection: false) }

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

        // 2. 走编辑器和 Quick Look 共用的下载入口。
        let entry = objects.first { $0.key == "config.yaml" }!
        guard let localURL = await state.prepareLocalCopy(of: entry) else {
            throw SelfTestError.assertion("无法准备本地副本")
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else { throw SelfTestError.assertion("本地缓存未落盘") }
        log("downloaded: \(localURL.path)")

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

        // 4. 依次处理两个同时等待选择的冲突。
        if let mock = service as? MockS3Service {
            _ = try await mock.simulateRemoteModify(bucket: "app-config", key: "config.yaml")
        }
        let current = try String(contentsOf: localURL, encoding: .utf8)
        let conflictMarker = "selftest conflict edit \(Int(Date().timeIntervalSince1970))"
        try (current + "\n# \(conflictMarker)\n").write(to: localURL, atomically: true, encoding: .utf8)
        log("conflict edit written, waiting engine…")
        try await waitUntil {
            await state.conflictDialog?.file.key == entry.key
        }
        guard let firstID = await state.conflictDialog?.id,
              let second = objects.first(where: { $0.key == "config.json" }),
              let secondURL = await state.prepareLocalCopy(of: second) else {
            throw SelfTestError.assertion("无法准备并发冲突")
        }
        if let mock = service as? MockS3Service {
            _ = try await mock.simulateRemoteModify(bucket: "app-config", key: second.key)
        }
        try "second conflicting edit".write(to: secondURL, atomically: true, encoding: .utf8)
        try await waitUntil {
            await state.statusPublic(bucket: "app-config", key: second.key) == .conflict
        }
        try await MainActor.run {
            guard state.conflictDialog?.id == firstID else {
                throw SelfTestError.assertion("第二个冲突覆盖了第一个")
            }
            state.resolveConflict(.keepLocalOnly, id: firstID)
            state.conflictDialogDidDismiss()
        }
        try await waitUntil {
            await state.conflictDialog?.file.key == second.key
        }
        try await MainActor.run {
            guard let secondID = state.conflictDialog?.id else {
                throw SelfTestError.assertion("第二个冲突未显示")
            }
            state.resolveConflict(.overwriteRemote, id: firstID)
            guard state.conflictDialog?.id == secondID else {
                throw SelfTestError.assertion("过期操作影响了第二个冲突")
            }
            state.resolveConflict(.reloadRemote, id: secondID)
            state.conflictDialogDidDismiss()
        }
        try await waitUntil {
            let firstStatus = await state.statusPublic(bucket: "app-config", key: entry.key)
            let secondStatus = await state.statusPublic(bucket: "app-config", key: second.key)
            return firstStatus == .failed("已保留本地副本（未上传）") && secondStatus == .synced
        }
        guard try String(contentsOf: localURL, encoding: .utf8).contains(conflictMarker),
              try String(contentsOf: secondURL, encoding: .utf8).contains("[模拟] 远程在") else {
            throw SelfTestError.assertion("冲突选择未应用到对应文件")
        }
        log("concurrent conflicts resolved in order")

        // 静默期后确认远程始终没有被冲突版本覆盖
        try await Task.sleep(for: .seconds(2))
        let remoteNow = try? await service.downloadText(bucket: "app-config", key: "config.yaml")
        if let remoteNow, remoteNow.contains(conflictMarker) {
            throw SelfTestError.assertion("冲突时本地版本不应被自动覆盖")
        }
        log("remote not overwritten by conflict edit ✓")
        await state.shutdown()
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

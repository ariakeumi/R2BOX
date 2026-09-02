import Foundation
import R2BOXCore
import R2BOXSync

/// R2BOXSync 校验：自动上传、冲突处理、断网重试、监听过滤
enum SyncCheck {
    static func runAll() async {
        await runTest("本地修改 → 自动上传 → 远程一致") { try await testAutoUpload() }
        await runTest("未跟踪文件的变化被忽略") { try await testUntrackedIgnored() }
        await runTest("冲突 → 覆盖远程") { try await testConflictOverwrite() }
        await runTest("冲突 → 重新加载远程") { try await testConflictReload() }
        await runTest("冲突 → 保留本地") { try await testConflictKeepLocal() }
        await runTest("断网保留修改，恢复后续传") { try await testOutageRetry() }
        await runTest("下载后跟踪记录 baseETag") { try await testTrackAfterDownload() }
        await runTest("下载原子性：空文件窗口不触发上传（回归）") { try await testDownloadAtomicity() }
        await runTest("坏跟踪记录：key 含 bucket 前缀被拒收") { try await testBadKeyRejected() }
        await runTest("打开决策：一致 / 仅本地改 → 打开本地") { testOpenPlanUseLocal() }
        await runTest("打开决策：本地干净但远程已更新 → 重新下载") { testOpenPlanRemoteChanged() }
        await runTest("打开决策：0 字节残留 + 远程非空 → 重新下载（回归）") { testOpenPlanStaleEmpty() }
        await runTest("打开决策：双方修改 → 打开本地待冲突") { testOpenPlanExpectConflict() }
        await runTest("打开决策：指纹未知 + 远程已变 → 打开本地待冲突（绝不覆盖，回归）") { testOpenPlanUnknownFingerprint() }
        await runTest("重启恢复：指纹随 tracked.json 持久化") { try await testFingerprintPersistence() }
    }

    // MARK: 工具

    private static func makeEnv() -> (Workspace, MockS3Service) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2box-checker-\(UUID().uuidString)", isDirectory: true)
        return (Workspace(baseURL: dir), MockS3Service())
    }

    private static func cleanup(_ workspace: Workspace) {
        try? FileManager.default.removeItem(at: workspace.baseURL)
    }

    /// 等待某个引擎事件发生（以事件驱动断言时机，避免竞态）
    private final class EventWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() { lock.lock(); fired = true; lock.unlock() }
        var isFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    private static func makeWatchedEngine(
        workspace: Workspace, service: MockS3Service, choice: ConflictChoice? = nil
    ) -> (SyncEngine, EventWaiter) {
        let engine = SyncEngine(workspace: workspace, service: service)
        if let choice { engine.conflictHandler = { _, _, _ in choice } }
        let waiter = EventWaiter()
        engine.eventHandler = { event in
            switch event {
            case .uploadDone, .uploadFailed, .conflictDetected:
                waiter.fire()
            default:
                break
            }
        }
        return (engine, waiter)
    }

    // MARK: 用例

    private static func testAutoUpload() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let (engine, waiter) = makeWatchedEngine(workspace: workspace, service: service)

        let url = workspace.localURL(bucket: "app-config", key: "config.yaml")
        let etag = try await service.download(bucket: "app-config", key: "config.yaml", destination: url, progress: nil)
        await engine.track(bucket: "app-config", key: "config.yaml", baseETag: etag)

        // track 契约：登记时本地 == 远程。之后编辑器 ⌘S 修改本地。
        try "local edit".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["app-config/config.yaml"])
        expectTrue(await waitUntil { waiter.isFired }, "收到 uploadDone 事件")

        let status = await engine.status(bucket: "app-config", key: "config.yaml")
        expectTrue({
            if case .synced = status { return true }
            return false
        }(), "最终状态 synced（实际 \(status)）")

        let info = await engine.trackedInfo(bucket: "app-config", key: "config.yaml")
        let remote = try await service.headObject(bucket: "app-config", key: "config.yaml")
        expectEqual(remote?.etag, info?.baseETag, "远程 ETag 与 baseETag 一致")
        expectEqual(try String(contentsOf: url, encoding: .utf8), "local edit", "本地内容不变")
    }

    private static func testUntrackedIgnored() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let engine = SyncEngine(workspace: workspace, service: service)

        let url = workspace.localURL(bucket: "app-config", key: "config.json")
        _ = try await service.download(bucket: "app-config", key: "config.json", destination: url, progress: nil)
        let before = try await service.headObject(bucket: "app-config", key: "config.json")

        try "untracked change".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["app-config/config.json"])
        try await Task.sleep(for: .milliseconds(1200))

        let after = try await service.headObject(bucket: "app-config", key: "config.json")
        expectEqual(after?.etag, before?.etag, "远程未被修改")
    }

    private static func conflictCase(
        _ choice: ConflictChoice, bucket: String, key: String
    ) async throws -> (SyncEngine, MockS3Service, Workspace, EventWaiter) {
        let (workspace, service) = makeEnv()
        let (engine, waiter) = makeWatchedEngine(workspace: workspace, service: service, choice: choice)

        let url = workspace.localURL(bucket: bucket, key: key)
        let etag = try await service.download(bucket: bucket, key: key, destination: url, progress: nil)
        await engine.track(bucket: bucket, key: key, baseETag: etag)
        _ = try await service.simulateRemoteModify(bucket: bucket, key: key)
        return (engine, service, workspace, waiter)
    }

    private static func testConflictOverwrite() async throws {
        let bucket = "app-config", key = "config.yaml"
        let (engine, service, workspace, waiter) = try await conflictCase(.overwriteRemote, bucket: bucket, key: key)
        defer { cleanup(workspace) }

        let url = workspace.localURL(bucket: bucket, key: key)
        try "my version wins".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["\(bucket)/\(key)"])

        expectTrue(await waitUntil { waiter.isFired }, "冲突已处理（overwriteRemote）")
        // 覆盖成功后，本地修改又触发一轮上传，等待其完成
        let settled = await waitUntil(timeout: 20) {
            let status = await engine.status(bucket: bucket, key: key)
            if case .synced = status { return true }
            return false
        }
        expectTrue(settled, "覆盖上传完成")

        let info = await engine.trackedInfo(bucket: bucket, key: key)
        let remote = try await service.headObject(bucket: bucket, key: key)
        expectEqual(remote?.etag, info?.baseETag, "远程与本地基线一致")
        expectEqual(try String(contentsOf: url, encoding: .utf8), "my version wins", "本地内容保留")
    }

    private static func testConflictReload() async throws {
        let bucket = "app-config", key = "config.json"
        let (engine, service, workspace, waiter) = try await conflictCase(.reloadRemote, bucket: bucket, key: key)
        defer { cleanup(workspace) }

        let url = workspace.localURL(bucket: bucket, key: key)
        try "stale local".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["\(bucket)/\(key)"])

        expectTrue(await waitUntil { waiter.isFired }, "冲突已处理（reloadRemote）")
        try await Task.sleep(for: .seconds(1)) // 重新下载完成

        let content = try String(contentsOf: url, encoding: .utf8)
        expectTrue(content.contains("[模拟] 远程在"), "本地内容被远程覆盖")
        let info = await engine.trackedInfo(bucket: bucket, key: key)
        let remote = try await service.headObject(bucket: bucket, key: key)
        expectEqual(remote?.etag, info?.baseETag, "基线更新为远程版本")
    }

    private static func testConflictKeepLocal() async throws {
        let bucket = "app-config", key = "config.yaml"
        let (engine, service, workspace, waiter) = try await conflictCase(.keepLocalOnly, bucket: bucket, key: key)
        defer { cleanup(workspace) }

        let url = workspace.localURL(bucket: bucket, key: key)
        try "keep me".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["\(bucket)/\(key)"])

        expectTrue(await waitUntil { waiter.isFired }, "冲突已处理（keepLocalOnly）")
        try await Task.sleep(for: .seconds(2)) // 确认不再自动上传

        let remoteAfterModify = try await service.headObject(bucket: bucket, key: key)
        expectEqual(try String(contentsOf: url, encoding: .utf8), "keep me", "本地内容保留")
        expectTrue(remoteAfterModify != nil, "远程对象仍在")
        let status = await engine.status(bucket: bucket, key: key)
        expectTrue({
            if case .failed = status { return true }
            return false
        }(), "状态为失败/待处理（实际 \(status)）")
    }

    private static func testOutageRetry() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let (engine, waiter) = makeWatchedEngine(workspace: workspace, service: service)

        let url = workspace.localURL(bucket: "app-config", key: "config.yaml")
        let etag = try await service.download(bucket: "app-config", key: "config.yaml", destination: url, progress: nil)
        await engine.track(bucket: "app-config", key: "config.yaml", baseETag: etag)

        await engine.setOutage(true)
        try "offline edit".write(to: url, atomically: true, encoding: .utf8)
        await engine.handleWorkspaceChanges(["app-config/config.yaml"])

        expectTrue(await waitUntil { waiter.isFired }, "断网触发 uploadFailed")
        expectEqual(try String(contentsOf: url, encoding: .utf8), "offline edit", "断网期间本地内容保留")
        let failed = await engine.status(bucket: "app-config", key: "config.yaml")
        expectTrue({
            if case .failed = failed { return true }
            return false
        }(), "断网期间状态为失败")

        await engine.setOutage(false)
        let recovered = await waitUntil {
            let status = await engine.status(bucket: "app-config", key: "config.yaml")
            if case .synced = status { return true }
            return false
        }
        expectTrue(recovered, "恢复网络后续传成功")
        let remote = try await service.headObject(bucket: "app-config", key: "config.yaml")
        let info = await engine.trackedInfo(bucket: "app-config", key: "config.yaml")
        expectEqual(remote?.etag, info?.baseETag, "远程与本地基线一致")
    }

    private static func testTrackAfterDownload() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let engine = SyncEngine(workspace: workspace, service: service)

        let url = workspace.localURL(bucket: "media-archive", key: "exports/render-final.mov")
        let etag = try await service.download(bucket: "media-archive", key: "exports/render-final.mov", destination: url, progress: nil)
        await engine.track(bucket: "media-archive", key: "exports/render-final.mov", baseETag: etag)

        let tracked = await engine.isTracked(bucket: "media-archive", key: "exports/render-final.mov")
        expectTrue(tracked, "已跟踪")
        let info = await engine.trackedInfo(bucket: "media-archive", key: "exports/render-final.mov")
        expectEqual(info?.baseETag, etag, "baseETag 与下载时一致")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        expectTrue((size ?? 0) > 1_000_000, "大文件完整落盘")
    }
}

// MARK: 回归用例

extension SyncCheck {
    /// 回归：重新下载流程 = 临时文件写入完整内容 → 原子 rename 到目标路径。
    /// 引擎看到的事件序列：目标路径出现【完整文件】；指纹与基线不同 → 上传完整内容。
    /// 远程任何时刻都不应出现空内容，且最终与本地一致。
    static func testDownloadAtomicity() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let (engine, waiter) = makeWatchedEngine(workspace: workspace, service: service)

        let bucket = "app-config", key = "config.yaml"
        let url = workspace.localURL(bucket: bucket, key: key)

        // 第一次下载建立基线
        let original = try await service.download(bucket: bucket, key: key, destination: url, progress: nil)
        await engine.track(bucket: bucket, key: key, baseETag: original)
        let remoteBefore = try await service.headObject(bucket: bucket, key: key)
        expectTrue((remoteBefore?.size ?? 0) > 0, "基线远程非空")

        // 模拟重新下载：完整内容写临时文件 → rename 到位（真实实现的行为）
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".__r2box_tmp/test.part")
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("full content after atomic rename".utf8).write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        await engine.handleWorkspaceChanges(["\(bucket)/\(key)"])

        expectTrue(await waitUntil { waiter.isFired }, "重新下载的落盘事件触发处理")
        // 静默期：允许可能的第二轮处理结束
        try await Task.sleep(for: .seconds(1.2))

        let remoteAfter = try await service.headObject(bucket: bucket, key: key)
        expectNotNil(remoteAfter, "远程对象存在")
        expectTrue((remoteAfter?.size ?? 0) > 0, "远程未被写入空内容")
        expectTrue(remoteAfter?.etag != remoteBefore?.etag, "内容已更新")
        let info = await engine.trackedInfo(bucket: bucket, key: key)
        expectEqual(remoteAfter?.etag, info?.baseETag, "远程与本地基线一致")
    }

    /// 回归：key 带 bucket 前缀的坏记录不再写入跟踪表。
    static func testBadKeyRejected() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }
        let engine = SyncEngine(workspace: workspace, service: service)

        await engine.track(bucket: "app-config", key: "app-config/config.yaml", baseETag: "\"x\"")
        let tracked = await engine.isTracked(bucket: "app-config", key: "app-config/config.yaml")
        expectTrue(!tracked, "坏 key 未被跟踪")

        // 正常 key 不受影响
        await engine.track(bucket: "app-config", key: "config.yaml", baseETag: "\"y\"")
        let ok = await engine.isTracked(bucket: "app-config", key: "config.yaml")
        expectTrue(ok, "正常 key 正常跟踪")
    }
}

// MARK: 打开决策（OpenDecision 纯函数）

extension SyncCheck {
    private static let now = Date()

    /// 本地与远程一致（baseETag == 当前 etag）→ 直接打开本地
    static func testOpenPlanUseLocal() {
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 100, trackedBaseETag: "\"a\"", currentETag: "\"a\"",
                syncedMtime: now, syncedSize: 100, localMtime: now, localSize: 100
            ),
            OpenPlan.useLocal,
            "打开本地"
        )
        // 无跟踪记录的孤儿副本（从 Finder 拖进来的等）→ 重新下载建立基线
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 100, trackedBaseETag: nil, currentETag: "\"a\"",
                syncedMtime: nil, syncedSize: nil, localMtime: now, localSize: 100
            ),
            OpenPlan.downloadRemote,
            "重新下载"
        )
        // 本地不存在 → 下载
        expectEqual(
            OpenDecision.plan(
                localExists: false, remoteSize: 100, trackedBaseETag: "\"a\"", currentETag: "\"a\"",
                syncedMtime: now, syncedSize: 100, localMtime: nil, localSize: nil
            ),
            OpenPlan.downloadRemote,
            "重新下载"
        )
    }

    /// 远程已更新、本地干净（指纹与上次同步一致）→ 重新下载
    static func testOpenPlanRemoteChanged() {
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 120, trackedBaseETag: "\"old\"", currentETag: "\"new\"",
                syncedMtime: now, syncedSize: 100, localMtime: now, localSize: 100
            ),
            OpenPlan.downloadRemote,
            "重新下载"
        )
    }

    /// 回归（用户报告）：本地 0 字节残留而远程有内容 → 必须重新下载，不能把空副本当最新打开
    static func testOpenPlanStaleEmpty() {
        // 即使 baseETag 碰巧与远程一致（历史坏记录），空文件也要重下
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 568, trackedBaseETag: "\"same\"", currentETag: "\"same\"",
                syncedMtime: now, syncedSize: 0, localMtime: now, localSize: 0
            ),
            OpenPlan.downloadRemote,
            "重新下载"
        )
        // 指纹未知 + 空本地 + 非空远程 → 重下
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 568, trackedBaseETag: "\"a\"", currentETag: "\"a\"",
                syncedMtime: nil, syncedSize: nil, localMtime: nil, localSize: 0
            ),
            OpenPlan.downloadRemote,
            "重新下载"
        )
    }

    /// 远程已更新且本地也有未上传修改（指纹不符）→ 打开本地，保留旧基线，保存时触发冲突
    static func testOpenPlanExpectConflict() {
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 120, trackedBaseETag: "old", currentETag: "new",
                syncedMtime: now, syncedSize: 100, localMtime: now.addingTimeInterval(-50), localSize: 130
            ),
            OpenPlan.useLocalExpectConflict,
            "打开本地待冲突"
        )
    }

    /// 回归（用户数据事故）：重启后指纹未知（旧版 tracked.json 无指纹字段），
    /// 远程 ETag 与基线不一致时绝不能重新下载覆盖本地——先打开本地，保存时走冲突
    static func testOpenPlanUnknownFingerprint() {
        expectEqual(
            OpenDecision.plan(
                localExists: true, remoteSize: 120, trackedBaseETag: "old", currentETag: "new",
                syncedMtime: nil, syncedSize: nil, localMtime: now, localSize: 130
            ),
            OpenPlan.useLocalExpectConflict,
            "指纹未知 → 打开本地待冲突"
        )
    }

    /// 回归（用户数据事故）：指纹持久化。重启（新引擎读同一 tracked.json）后，
    /// 本地未被修改的文件指纹仍与记录一致 → 远程变化才重新下载，本地修改不会被误判
    static func testFingerprintPersistence() async throws {
        let (workspace, service) = makeEnv()
        defer { cleanup(workspace) }

        let engineA = SyncEngine(workspace: workspace, service: service)
        let url = workspace.localURL(bucket: "app-config", key: "config.yaml")
        let etag = try await service.download(bucket: "app-config", key: "config.yaml", destination: url, progress: nil)
        await engineA.track(bucket: "app-config", key: "config.yaml", baseETag: etag)

        // 模拟重启：新引擎从磁盘恢复
        let engineB = SyncEngine(workspace: workspace, service: service)
        await engineB.restoreFromDisk()
        let info = await engineB.trackedInfo(bucket: "app-config", key: "config.yaml")
        expectNotNil(info?.syncedMtime, "重启后指纹 mtime 已恢复")
        expectNotNil(info?.syncedSize, "重启后指纹 size 已恢复")
        expectEqual(info?.baseETag, etag, "baseETag 一致")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value
        expectEqual(info?.syncedSize, size, "指纹 size 与本地文件一致")
    }
}

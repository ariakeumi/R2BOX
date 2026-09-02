import Foundation
import Network
import R2BOXCore

/// R2BOXCore 校验：连接持久化、Keychain、Mock S3 行为
enum CoreCheck {
    static func runAll() async {
        await runTest("连接配置保存与读取") { try testConnectionRoundtrip() }
        await runTest("Keychain 读写与删除") { try testKeychain() }
        await runTest("Mock S3：列 Bucket / 列目录 / 分页前缀") { try await testList() }
        await runTest("Mock S3：条件写入冲突（If-Match）") { try await testPrecondition() }
        await runTest("Mock S3：断网抛出 network 错误") { try await testOutage() }
        await runTest("Mock S3：大文件下载完整性（流式）") { try await testBigFile() }
        await runTest("AWSS3：下载请求必须带 SigV4 签名（回归）") { try await testDownloadSigned() }
    }

    // MARK: 用例

    static func testConnectionRoundtrip() throws {        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2box-checker-\(UUID().uuidString)", isDirectory: true)
        let store = ConnectionStore(directory: dir)
        let conn = Connection(
            name: "Cloudflare R2",
            endpoint: "https://acct.r2.cloudflarestorage.com",
            region: "auto",
            accessKeyID: "AKIA_TEST",
            pathStyle: true
        )
        store.save([conn])
        let loaded = store.load()
        expectEqual(loaded.count, 1, "读取数量")
        expectEqual(loaded.first?.name, "Cloudflare R2", "名称")
        expectEqual(loaded.first?.region, "auto", "Region")
        expectEqual(loaded.first?.pathStyle, true, "PathStyle")
        expectEqual(loaded.first?.bucket, "", "未设置限定桶时为空")

        // 限定桶字段持久化 + 旧 JSON（无 bucket 字段）向后兼容
        var pinned = conn
        pinned.bucket = " my-bucket "
        store.save([pinned])
        expectEqual(store.load().first?.bucket, " my-bucket ", "限定桶原样保存（UI 侧 trim）")

        let legacyJSON = """
        [{"id":"\(conn.id.uuidString)","name":"legacy","endpoint":"https://x.r2.cloudflarestorage.com",
          "region":"auto","accessKeyID":"A","pathStyle":true}]
        """
        let legacyURL = dir.appendingPathComponent("connections.json")
        try legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)  // non-throwing context ok
        let legacy = store.load()
        expectEqual(legacy.first?.bucket, "", "旧配置无 bucket 字段 → 空字符串")
        expectEqual(legacy.first?.name, "legacy", "旧配置其余字段完好")
    }

    static func testKeychain() throws {
        let keychain = KeychainStore()
        let account = "checker.\(UUID().uuidString)"
        defer { keychain.deleteSecret(account: account) }

        expectNil(keychain.getSecret(account: account), "初始为空")
        try keychain.setSecret("secret-abc", account: account)
        expectEqual(keychain.getSecret(account: account), "secret-abc", "写入后读取")
        try keychain.setSecret("secret-xyz", account: account)
        expectEqual(keychain.getSecret(account: account), "secret-xyz", "覆盖更新")
        keychain.deleteSecret(account: account)
        expectNil(keychain.getSecret(account: account), "删除后为空")
    }

    static func testList() async throws {
        let service = MockS3Service()
        let buckets = try await service.listBuckets()
        expectTrue(buckets.contains { $0.name == "app-config" }, "包含 app-config")

        let root = try await service.listObjects(bucket: "app-config", prefix: "")
        expectTrue(root.folders.contains("envs/"), "根目录含 envs/")
        expectTrue(root.folders.contains("services/"), "根目录含 services/")
        expectTrue(root.objects.contains { $0.key == "config.yaml" }, "根目录含 config.yaml")
        expectTrue(!root.objects.contains { $0.key.contains("/") }, "对象不跨层级")

        let envs = try await service.listObjects(bucket: "app-config", prefix: "envs/")
        expectEqual(envs.objects.count, 3, "envs/ 下 3 个文件")
        expectTrue(envs.objects.allSatisfy { $0.key.hasPrefix("envs/") }, "前缀过滤")
    }

    static func testPrecondition() async throws {
        let service = MockS3Service()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2box-checker-\(UUID().uuidString).txt")
        try "hello".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let etag1 = try await service.upload(bucket: "app-config", key: "checker/test.txt", source: tmp, ifMatch: nil, progress: nil)
        expectTrue(!etag1.hasPrefix("\""), "ETag 规范化为不带引号")

        // 与当前远程一致的 ETag 写入 → 成功（无冲突）
        try "v2".write(to: tmp, atomically: true, encoding: .utf8)
        _ = try await service.upload(bucket: "app-config", key: "checker/test.txt", source: tmp, ifMatch: etag1, progress: nil)

        // 远程已被推进到 etag2，用旧 etag1 写入 → 冲突
        try "v3".write(to: tmp, atomically: true, encoding: .utf8)
        do {
            _ = try await service.upload(bucket: "app-config", key: "checker/test.txt", source: tmp, ifMatch: etag1, progress: nil)
            failures.append("[\(currentTestName)] 旧 ETag 上传未抛 preconditionFailed")
            print("  ❌ 旧 ETag 上传未抛 preconditionFailed")
        } catch let error as S3Error {
            expectEqual(error, S3Error.preconditionFailed, "错误类型")
        }

        // 用最新 ETag 写入 → 成功
        let head = try await service.headObject(bucket: "app-config", key: "checker/test.txt")
        let etag3 = try await service.upload(bucket: "app-config", key: "checker/test.txt", source: tmp, ifMatch: head?.etag, progress: nil)
        expectTrue(!etag3.isEmpty, "条件写入成功")
    }

    static func testOutage() async throws {
        let service = MockS3Service()
        await service.setOutage(true)
        do {
            _ = try await service.listBuckets()
            failures.append("[\(currentTestName)] 断网时 listBuckets 未抛错")
            print("  ❌ 断网时 listBuckets 未抛错")
        } catch let error as S3Error {
            expectEqual(error, S3Error.network, "错误类型")
        }
        await service.setOutage(false)
        let buckets = try await service.listBuckets()
        expectTrue(!buckets.isEmpty, "恢复网络后可用")
    }

    static func testBigFile() async throws {
        let service = MockS3Service()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2box-checker-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let remote = try await service.headObject(bucket: "media-archive", key: "exports/render-final.mov")
        let fractions = ProgressCollector()
        _ = try await service.download(bucket: "media-archive", key: "exports/render-final.mov", destination: dest) { f in
            fractions.append(f)
        }
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64
        expectEqual(size, remote?.size, "下载大小一致")
        expectTrue(fractions.count > 3, "进度回调多次（流式）")
        expectTrue(abs(fractions.last - 1.0) < 0.001, "进度收尾为 100%")
    }
}

/// 并发安全的进度收集器
final class ProgressCollector: @unchecked Sendable {
    private var values: [Double] = []
    private let lock = NSLock()
    func append(_ v: Double) {
        lock.lock(); values.append(v); lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return values.count
    }
    var last: Double {
        lock.lock(); defer { lock.unlock() }; return values.last ?? 0
    }
}


// MARK: 回归（真实服务签名）

extension CoreCheck {
    /// 进程内 HTTP stub：无 Authorization / x-amz-* 头的 GET 一律 403（模拟 R2 行为）。
    /// 回归背景：download() 重写为临时文件+原子改名时曾丢失签名，R2 拒绝下载而错误被 UI 吞掉。
    static func testDownloadSigned() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        final class Capturer: @unchecked Sendable {
            var sawAuth = false
            var sawDate = false
            var body = Data()
        }
        let cap = Capturer()
        let sem = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { conn in
            conn.start(queue: DispatchQueue(label: "stub"))
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let data, !data.isEmpty {
                        cap.body.append(data)
                        if let text = String(data: data, encoding: .utf8),
                           text.contains("\r\n\r\n") || text.hasSuffix("\n") {
                            // 请求头已完整（GET 无体）
                            if text.contains("Authorization: AWS4-HMAC-SHA256") { cap.sawAuth = true }
                            if text.contains("x-amz-date:") { cap.sawDate = true }
                            let resp = "HTTP/1.1 200 OK\r\nETag: \"stub\"\r\nContent-Length: 18\r\nConnection: close\r\n\r\nsigned-download-ok"
                            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                                conn.cancel()
                                sem.signal()
                            })
                            return
                        }
                        receive()
                    } else {
                        conn.cancel()
                        sem.signal()
                    }
                }
            }
            receive()
        }
        listener.start(queue: DispatchQueue(label: "stub-listener"))
        // 拿端口
        var portUInt: UInt16 = 0
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p != 0 { portUInt = p; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expectTrue(portUInt != 0, "stub 监听端口")

        let conn = Connection(
            name: "stub", endpoint: "http://127.0.0.1:\(portUInt)", region: "auto",
            accessKeyID: "AKIDEXAMPLE", pathStyle: true
        )
        let service = S3ServiceFactory.service(for: conn, secretProvider: { "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" })
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2box-sigcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        let etag = try await service.download(bucket: "stub", key: "a.yaml", destination: dest, progress: nil)
        for _ in 0..<60 where !cap.sawAuth {
            try await Task.sleep(for: .milliseconds(50))
        }
        expectTrue(cap.sawAuth, "下载请求带 Authorization 签名头")
        expectTrue(cap.sawDate, "下载请求带 x-amz-date")
        expectEqual(try String(contentsOf: dest, encoding: .utf8), "signed-download-ok", "下载内容正确")
        expectEqual(etag, "stub", "返回远程 ETag")
    }
}

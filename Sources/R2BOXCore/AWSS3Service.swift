import CryptoKit
import Foundation
import Network

/// 真实 S3 / R2 实现：手写 SigV4 + URLSession，流式分块传输。
/// - Path-style 与 virtual-host 风格寻址均支持（R2 用 path-style）。
/// - ListObjectsV2 自动翻页（每页 1000）。
/// - 上传 If-Match 走 CopyObject 条件语义不行，直接 PUT + `If-Match` 头（S3/R2 支持）。
/// - 下载/上传全程按 4MB 块读写文件句柄，不整载内存。
public actor AWSS3Service: S3Service {
    public let serviceName = "AWSS3"

    private let connection: Connection
    private let secretKeyProvider: @Sendable () -> String?
    private let session: URLSession
    private var pathMonitor: NWPathMonitor?
    private var networkUp = true

    /// 大于该阈值时上传/下载显示并执行分块流式（所有请求都流式，此值仅影响进度回调粒度）
    private let chunkSize = 4 * 1024 * 1024

    public init(connection: Connection, secretKeyProvider: @escaping @Sendable () -> String?) {
        self.connection = connection
        self.secretKeyProvider = secretKeyProvider
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    deinit {
        pathMonitor?.cancel()
    }

    // MARK: - 网络状态

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { await self?.networkPathChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.r2box.nwpath"))
        pathMonitor = monitor
    }

    private func networkPathChanged(_ up: Bool) {
        networkUp = up
    }

    private func ensureOnline() throws {
        guard networkUp else { throw S3Error.network }
    }

    // MARK: - URL 构建

    /// Path-style: https://endpoint/bucket/key
    /// Virtual-host: https://bucket.endpoint/key
    private func requestURL(bucket: String, key: String = "", query: [(String, String)] = []) throws -> URL {
        guard var components = URLComponents(string: connection.endpoint) else {
            throw S3Error.unknown("无效的 Endpoint：\(connection.endpoint)")
        }
        components.scheme = components.scheme ?? "https"
        var path = components.path.isEmpty ? "/" : components.path
        if !bucket.isEmpty {
            if connection.pathStyle {
                path = (path.hasSuffix("/") ? path : path + "/") + bucket
            } else {
                components.host = bucket + "." + (components.host ?? "")
            }
        }
        if !key.isEmpty {
            path = (path.hasSuffix("/") ? path : path + "/") + key
        }
        components.path = path
        if !query.isEmpty {
            components.percentEncodedQuery = SigV4.canonicalQuery(query)
        }
        guard let url = components.url else {
            throw S3Error.unknown("无法构建请求 URL")
        }
        return url
    }

    // MARK: - 签名请求

    private struct S3Response {
        let http: HTTPURLResponse
        let data: Data
    }

    /// 给请求附加 SigV4 签名头（GET/HEAD 等无体请求也必须签名，R2 拒绝匿名访问）。
    /// payloadHash 必须与实际请求体一致（无体 = emptyPayloadHash）。
    private func signedURLRequest(
        method: String,
        url: URL,
        extraHeaders: [String: String] = [:],
        payloadHash: String
    ) throws -> URLRequest {
        startPathMonitorIfNeeded()

        guard let secretKey = secretKeyProvider(), !secretKey.isEmpty else {
            throw S3Error.accessDenied
        }
        let amzDate = SigV4.amzDate(from: Date())
        let dateScope = SigV4.dateScope(from: amzDate)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("R2BOX/0.2", forHTTPHeaderField: "User-Agent")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let auth = SigV4.authorization(
            accessKey: connection.accessKeyID,
            secretKey: secretKey,
            region: connection.region.isEmpty ? "auto" : connection.region,
            method: method,
            url: url,
            extraHeaders: extraHeaders,
            payloadHash: payloadHash,
            amzDate: amzDate,
            dateScope: dateScope
        )
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        return request
    }

    private func signedRequest(
        method: String,
        url: URL,
        extraHeaders: [String: String] = [:],
        body: Data? = nil,
        bodyFileURL: URL? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> S3Response {
        try ensureOnline()

        guard let secretKey = secretKeyProvider(), !secretKey.isEmpty else {
            throw S3Error.accessDenied
        }
        let date = Date()
        let amzDate = SigV4.amzDate(from: date)
        let dateScope = SigV4.dateScope(from: amzDate)

        var headers = extraHeaders
        let payloadHash: String
        if let fileURL = bodyFileURL {
            payloadHash = try SigV4.sha256Hex(fileAt: fileURL)
        } else if let body, !body.isEmpty {
            payloadHash = SigV4.sha256Hex(body)
        } else {
            payloadHash = SigV4.emptyPayloadHash
        }

        var request = try signedURLRequest(method: method, url: url, extraHeaders: headers, payloadHash: payloadHash)

        // 文件体走上传任务（磁盘流式，不整载内存）
        if let fileURL = bodyFileURL {
            return try await uploadRequestBody(request: request, fileURL: fileURL, progress: progress)
        }
        if let body {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3Error.network
        }
        try validateStatus(http, data: data)
        return S3Response(http: http, data: data)
    }

    /// 从磁盘流式上传文件体，didSendBodyData 回调报告进度。
    private func uploadRequestBody(request: URLRequest, fileURL: URL, progress: ProgressHandler?) async throws -> S3Response {
        let delegate = UploadProgressDelegate(progress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw S3Error.network }
        try validateStatus(http, data: data)
        progress?(1.0)
        return S3Response(http: http, data: data)
    }

    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let progress: ProgressHandler?
        init(progress: ProgressHandler?) {
            self.progress = progress
            super.init()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard let progress, totalBytesExpectedToSend > 0 else { return }
            progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }

    private func validateStatus(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        let (code, _) = S3XML.parseError(String(data: data, encoding: .utf8) ?? "")
        throw S3XML.mapError(code: code, status: http.statusCode)
    }

    // MARK: - S3Service

    public func listBuckets() async throws -> [BucketInfo] {
        let url = try requestURL(bucket: "", key: "")
        let response = try await signedRequest(method: "GET", url: url)
        return S3XML.parseListBuckets(String(data: response.data, encoding: .utf8) ?? "")
    }

    public func listObjects(bucket: String, prefix: String) async throws -> (folders: [String], objects: [ObjectEntry]) {
        var allObjects: [ObjectEntry] = []
        var folders = Set<String>()
        var continuationToken: String? = nil

        repeat {
            var query: [(String, String)] = [("list-type", "2"), ("max-keys", "1000")]
            if !prefix.isEmpty {
                query.append(("prefix", prefix))
            }
            query.append(("delimiter", "/"))
            if let token = continuationToken {
                query.append(("continuation-token", token))
            }
            let url = try requestURL(bucket: bucket, key: "", query: query)
            let response = try await signedRequest(method: "GET", url: url)
            let result = S3XML.parseListObjectsV2(String(data: response.data, encoding: .utf8) ?? "")
            for object in result.objects {
                // "name/" 零字节占位（有些客户端建文件夹的方式）归入文件夹
                if object.key.hasSuffix("/") && object.size == 0 {
                    folders.insert(object.key)
                } else {
                    allObjects.append(object)
                }
            }
            for prefix in result.commonPrefixes {
                folders.insert(prefix.hasSuffix("/") ? prefix : prefix + "/")
            }
            continuationToken = result.isTruncated ? result.nextContinuationToken : nil
        } while continuationToken != nil

        return (folders.sorted(), allObjects.sorted { $0.key < $1.key })
    }

    public func headObject(bucket: String, key: String) async throws -> ObjectEntry? {
        let url = try requestURL(bucket: bucket, key: key)
        do {
            let response = try await signedRequest(method: "HEAD", url: url)
            let http = response.http
            let size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            let etag = S3XML.normalizeETag(http.value(forHTTPHeaderField: "ETag") ?? "")
            let lastModified = (http.value(forHTTPHeaderField: "Last-Modified"))
                .flatMap { S3XML.parseRFC1123($0) } ?? Date()
            return ObjectEntry(key: key, size: size, lastModified: lastModified, etag: etag)
        } catch let error as S3Error where error == .notFound {
            return nil
        }
    }

    @discardableResult
    public func download(bucket: String, key: String, destination: URL, progress: ProgressHandler?) async throws -> String {
        try ensureOnline()
        let url = try requestURL(bucket: bucket, key: key)

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 临时文件放在元数据目录（watcher 已过滤该目录），写完原子 rename，
        // 避免目标路径的"空文件窗口"被 FSEvents 抓到后误上传空内容。
        let tempDir = destination.deletingLastPathComponent()
            .appendingPathComponent(".__r2box_tmp", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? fm.removeItem(at: tempURL) }

        // 与其他操作一致：GET 必须带 SigV4 签名（私有桶拒绝匿名请求）
        let request = try signedURLRequest(method: "GET", url: url, payloadHash: SigV4.emptyPayloadHash)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.network }
        try validateStatus(http, data: Data())

        let expectedLength = http.expectedContentLength
        var received: Int64 = 0
        let etag = S3XML.normalizeETag(http.value(forHTTPHeaderField: "ETag") ?? "")

        let handle = try FileHandle(forWritingTo: createTempFile(at: tempURL))
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    progress?(Double(received) / Double(expectedLength))
                }
                try ensureOnline()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()
        if expectedLength > 0 {
            progress?(1.0)
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        return etag
    }

    private func createTempFile(at url: URL) -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @discardableResult
    public func upload(bucket: String, key: String, source: URL, ifMatch: String?, progress: ProgressHandler?) async throws -> String {
        let url = try requestURL(bucket: bucket, key: key)
        var headers: [String: String] = [:]
        // 条件写入：S3 PUT If-Match；远程不匹配返回 412 PreconditionFailed
        if let ifMatch, !ifMatch.isEmpty {
            headers["If-Match"] = ifMatch.hasPrefix("\"") ? ifMatch : "\"\(ifMatch)\""
        }
        let response = try await signedRequest(
            method: "PUT", url: url, extraHeaders: headers,
            bodyFileURL: source, progress: progress
        )
        let etag = S3XML.normalizeETag(response.http.value(forHTTPHeaderField: "ETag") ?? "")
        return etag
    }

    public func delete(bucket: String, key: String, isFolder: Bool) async throws {
        if isFolder {
            // 列出前缀下全部对象后批量删除
            var keys: [String] = []
            var token: String? = nil
            repeat {
                var query: [(String, String)] = [("list-type", "2"), ("max-keys", "1000")]
                if !key.isEmpty {
                    query.append(("prefix", key.hasSuffix("/") ? key : key + "/"))
                }
                if let t = token { query.append(("continuation-token", t)) }
                let url = try requestURL(bucket: bucket, key: "", query: query)
                let response = try await signedRequest(method: "GET", url: url)
                let result = S3XML.parseListObjectsV2(String(data: response.data, encoding: .utf8) ?? "")
                keys += result.objects.map(\.key)
                keys += result.commonPrefixes.map { $0 }
                token = result.isTruncated ? result.nextContinuationToken : nil
            } while token != nil

            for batch in stride(from: 0, to: keys.count, by: 900).map({ Array(keys[$0..<min($0 + 900, keys.count)]) }) {
                try await deleteBatch(bucket: bucket, keys: batch)
            }
        } else {
            let url = try requestURL(bucket: bucket, key: key)
            _ = try await signedRequest(method: "DELETE", url: url)
        }
    }

    private func deleteBatch(bucket: String, keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let body = S3XML.batchDeleteBody(keys)
        let query: [(String, String)] = [("delete", "")]
        let url = try requestURL(bucket: bucket, key: "", query: query)
        let response = try await signedRequest(method: "POST", url: url, extraHeaders: ["Content-MD5": md5Base64(body)], body: body)
        let errors = S3XML.parseDeleteErrors(String(data: response.data, encoding: .utf8) ?? "")
        if let first = errors.first {
            throw S3Error.unknown("批量删除失败 \(first.key): \(first.code)")
        }
    }

    public func move(bucket: String, key: String, isFolder: Bool, newKeyName: String) async throws {
        let dir = parentPrefix(of: key)
        let newKey = isFolder ? dir + newKeyName + "/" : dir + newKeyName

        if isFolder {
            // 列出前缀全部对象，逐个 copy + delete
            let prefix = key.hasSuffix("/") ? key : key + "/"
            var token: String? = nil
            repeat {
                var query: [(String, String)] = [("list-type", "2"), ("max-keys", "1000"), ("prefix", prefix)]
                if let t = token { query.append(("continuation-token", t)) }
                let url = try requestURL(bucket: bucket, key: "", query: query)
                let response = try await signedRequest(method: "GET", url: url)
                let result = S3XML.parseListObjectsV2(String(data: response.data, encoding: .utf8) ?? "")
                for object in result.objects {
                    let suffix = String(object.key.dropFirst(prefix.count))
                    try await copyObject(bucket: bucket, from: object.key, to: dir + newKeyName + "/" + suffix)
                    try await delete(bucket: bucket, key: object.key, isFolder: false)
                }
                token = result.isTruncated ? result.nextContinuationToken : nil
            } while token != nil
        } else {
            try await copyObject(bucket: bucket, from: key, to: newKey)
            try await delete(bucket: bucket, key: key, isFolder: false)
        }
    }

    private func copyObject(bucket: String, from: String, to: String) async throws {
        let url = try requestURL(bucket: bucket, key: to)
        let encodedSource = SigV4.uriEncode(bucket + "/" + from, encodeSlash: false)
        let response = try await signedRequest(
            method: "PUT", url: url,
            extraHeaders: ["x-amz-copy-source": encodedSource]
        )
        _ = S3XML.parseCopyResult(String(data: response.data, encoding: .utf8) ?? "")
    }

    public func createFolder(bucket: String, prefix: String) async throws {
        let key = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let url = try requestURL(bucket: bucket, key: key)
        _ = try await signedRequest(method: "PUT", url: url, body: Data())
    }

    // MARK: - 辅助

    private func parentPrefix(of key: String) -> String {
        guard let lastSlash = key.lastIndex(of: "/") else { return "" }
        return String(key[...lastSlash])
    }

    private func md5Base64(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }
}



import Foundation
import R2BOXCore

/// SigV4 签名器 + S3XML 解析 + ServiceFactory 校验
enum CryptoCheck {
    static func runAll() async {
        await runTest("SigV4：uriEncode / canonicalQuery / canonicalURI") { testEncoding() }
        await runTest("SigV4：AWS 官方签名向量（get-vanilla）") { try testAWSVector() }
        await runTest("SigV4：签名密钥推导向量") { testSigningKey() }
        await runTest("S3XML：ListBuckets 解析") { testListBuckets() }
        await runTest("S3XML：ListObjectsV2 解析（分页/前缀/实体转义）") { testListObjectsV2() }
        await runTest("S3XML：错误映射 / 批量删除请求体") { testErrorAndDelete() }
        await runTest("S3XML：时间戳解析") { testDates() }
        await runTest("ServiceFactory：demo→Mock，真实端点→AWSS3") { testFactory() }
    }

    // MARK: SigV4

    static func testEncoding() {
        // AWS 官方 get-vanilla-expect-200-unreserved 的字符集规则
        expectEqual(SigV4.uriEncode("-_.~"), "-_.~", "非保留字符不编码")
        expectEqual(SigV4.uriEncode("abc123"), "abc123", "字母数字不编码")
        expectEqual(SigV4.uriEncode("a b"), "a%20b", "空格编码为 %20")
        expectEqual(SigV4.uriEncode("ü"), "%C3%BC", "UTF-8 多字节")
        expectEqual(SigV4.uriEncode("a+b"), "a%2Bb", "+ 编码")
        expectEqual(SigV4.uriEncode("envs/prod.yaml", encodeSlash: false), "envs/prod.yaml", "path 模式保留 /")
        expectEqual(SigV4.uriEncode("envs/prod.yaml"), "envs%2Fprod.yaml", "query 模式编码 /")

        expectEqual(
            SigV4.canonicalQuery([("list-type", "2"), ("prefix", "envs/中"), ("max-keys", "1000")]),
            "list-type=2&max-keys=1000&prefix=envs%2F%E4%B8%AD",
            "query 排序 + 编码"
        )
        expectEqual(SigV4.canonicalURI(path: "/bucket/envs/prod.yaml"), "/bucket/envs/prod.yaml", "canonicalURI path")
        expectEqual(SigV4.canonicalURI(path: "/bucket/中 文.txt"), "/bucket/%E4%B8%AD%20%E6%96%87.txt", "canonicalURI 中文+空格")
    }

    /// AWS 官方文档 get-vanilla 测试套件的签名（固定密钥/时间/负载）。
    static func testAWSVector() throws {
        // AWS SigV4 测试套件 "get-vanilla"：
        // GET /、Host: example.amazonaws.com、x-amz-date 20150830T123600Z、
        // access key AKIDEXAMPLE / secret wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY / us-east-1
        let accessKey = "AKIDEXAMPLE"
        let secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        let region = "us-east-1"
        let amzDate = "20150830T123600Z"
        let dateScope = SigV4.dateScope(from: amzDate)
        expectEqual(dateScope, "20150830", "dateScope 提取")

        guard let url = URL(string: "https://example.amazonaws.com/") else {
            failures.append("[\(currentTestName)] URL 构建失败")
            return
        }

        let auth = SigV4.authorization(
            accessKey: accessKey,
            secretKey: secretKey,
            region: region,
            method: "GET",
            url: url,
            extraHeaders: [:],
            payloadHash: SigV4.emptyPayloadHash,
            amzDate: amzDate,
            dateScope: dateScope,
            service: "service",          // 测试套件用 "service" 而非 "s3"
            signContentHash: false       // 套件只签 host;x-amz-date
        )
        // 官方 get-vanilla 预期签名（SignedHeaders=host;x-amz-date）
        let expected = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,SignedHeaders=host;x-amz-date,Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        expectEqual(auth, expected, "get-vanilla 签名")

        // S3 语义（默认签 x-amz-content-sha256 三头）—— 与 python 独立实现比对
        let authS3 = SigV4.authorization(
            accessKey: accessKey,
            secretKey: secretKey,
            region: region,
            method: "GET",
            url: url,
            extraHeaders: [:],
            payloadHash: SigV4.emptyPayloadHash,
            amzDate: amzDate,
            dateScope: dateScope,
            service: "service"
        )
        let expectedS3 = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=726c5c4879a6b4ccbbd3b24edbd6b8826d34f87450fbbf4e85546fc7ba9c1642"
        expectEqual(authS3, expectedS3, "S3 三头签名（python 独立交叉验证）")
    }

    struct SelfTestFail: Error {}

    /// 派生密钥向量：AWS 文档 "derive 签名密钥" 示例
    /// secret=wJalr… / 20150830 / us-east-1 / iam → c4afb1…（python 独立复算一致）
    static func testSigningKey() {
        let key = SigV4.signingKey(
            secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            dateScope: "20150830",
            region: "us-east-1",
            service: "iam"
        )
        let hex = key.map { String(format: "%02x", $0) }.joined()
        expectEqual(hex, "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9", "signing key 推导")
    }

    // MARK: S3XML

    static func testListBuckets() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Owner><ID>abc</ID><DisplayName>me</DisplayName></Owner>
            <Buckets>
                <Bucket><Name>app-config</Name><CreationDate>2024-01-02T03:04:05.000Z</CreationDate></Bucket>
                <Bucket><Name>媒体资产</Name><CreationDate>2024-06-01T10:00:00.000Z</CreationDate></Bucket>
            </Buckets>
        </ListAllMyBucketsResult>
        """
        let buckets = S3XML.parseListBuckets(xml)
        expectEqual(buckets.count, 2, "Bucket 数量")
        expectEqual(buckets[0].name, "app-config", "Bucket 名")
        expectEqual(buckets[1].name, "媒体资产", "Bucket 中文")
        expectNotNil(buckets[0].creationDate, "创建时间解析")
    }

    static func testListObjectsV2() {
        let xml = """
        <ListBucketResult>
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
            <Contents>
                <Key>config.yaml</Key><Size>813</Size><ETag>&quot;abc123&quot;</ETag>
                <LastModified>2024-01-02T03:04:05.000Z</LastModified>
            </Contents>
            <Contents>
                <Key>services/api/config.yaml</Key><Size>64</Size><ETag>&quot;def456&quot;</ETag>
                <LastModified>2024-02-03T04:05:06.000Z</LastModified>
            </Contents>
            <Contents>
                <Key>envs/</Key><Size>0</Size><ETag>&quot;d41d8&quot;</ETag>
                <LastModified>2024-02-03T04:05:06.000Z</LastModified>
            </Contents>
            <CommonPrefixes><Prefix>envs/</Prefix></CommonPrefixes>
            <CommonPrefixes><Prefix>services/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let result = S3XML.parseListObjectsV2(xml)
        expectEqual(result.objects.count, 3, "对象数量（含占位）")
        expectEqual(result.objects[0].key, "config.yaml", "Key 解析")
        expectEqual(result.objects[0].size, Int64(813), "Size 解析")
        // S3 XML 里 ETag 自带双引号（&quot;），保留引号语义；上层 Model 存原始值
        expectEqual(result.objects[0].etag, "abc123", "ETag 实体解包并去引号（normalizeETag）")
        expectEqual(result.commonPrefixes.count, 2, "CommonPrefixes 数量")
        expectEqual(result.commonPrefixes[0], "envs/", "前缀")
        expectEqual(result.isTruncated, true, "IsTruncated")
        expectNotNil(result.nextContinuationToken, "ContinuationToken")
        // <Key 不得误配 <KeyCount 等
        let keyCountXML = "<ListBucketResult><KeyCount>3</KeyCount><Contents><Key>real</Key></Contents></ListBucketResult>"
        let r2 = S3XML.parseListObjectsV2(keyCountXML)
        expectEqual(r2.objects.count, 1, "KeyCount 不误配 Key")
        expectEqual(r2.objects[0].key, "real", "Key 值正确")
    }

    static func testErrorAndDelete() {
        expectEqual(S3XML.mapError(code: "NoSuchKey", status: 404), S3Error.notFound, "NoSuchKey")
        expectEqual(S3XML.mapError(code: nil, status: 412), S3Error.preconditionFailed, "412 状态")
        expectEqual(S3XML.mapError(code: "AccessDenied", status: 403), S3Error.accessDenied, "AccessDenied")
        expectEqual(S3XML.mapError(code: "SlowDown", status: 503), S3Error.unknown("SlowDown"), "其他错误")

        let errXML = "<Error><Code>PreconditionFailed</Code><Message>At least one of the pre-conditions did not match</Message></Error>"
        let (code, message) = S3XML.parseError(errXML)
        expectEqual(code, "PreconditionFailed", "错误 Code")
        expectTrue(message.contains("pre-conditions"), "错误 Message")

        let body = String(data: S3XML.batchDeleteBody(["a.yaml", "中/b.txt"]), encoding: .utf8) ?? ""
        expectTrue(body.contains("<Object><Key>a.yaml</Key></Object>"), "批量删除 body 条目")
        expectTrue(body.contains("中/b.txt"), "批量删除 body 中文")
        let errors = S3XML.parseDeleteErrors("<DeleteResult><Error><Key>a.yaml</Key><Code>AccessDenied</Code></Error></DeleteResult>")
        expectEqual(errors.count, 1, "删除错误数量")
        expectEqual(errors[0].code, "AccessDenied", "删除错误码")
    }

    static func testDates() {
        let withFraction = S3XML.parseDate("2024-01-02T03:04:05.123Z")
        expectNotNil(withFraction, "带小数秒")
        let plain = S3XML.parseDate("2024-01-02T03:04:05Z")
        expectNotNil(plain, "无小数秒")
        if let a = withFraction, let b = plain {
            expectTrue(abs(a.timeIntervalSince(b) - 0.123) < 0.001, "毫秒精度")
        }
        let rfc = S3XML.parseRFC1123("Tue, 02 Jan 2024 03:04:05 GMT")
        expectNotNil(rfc, "RFC1123 解析")
        if let rfc {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: rfc)
            expectEqual(comps.year, 2024, "RFC1123 年")
            expectEqual(comps.hour, 3, "RFC1123 时")
        }
        // amzDate 格式
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2024, month: 6, day: 15, hour: 12, minute: 34, second: 56))
        expectEqual(SigV4.amzDate(from: date ?? Date()), "20240615T123456Z", "amzDate 格式")
    }

    // MARK: Factory

    static func testFactory() {
        let demo = Connection(
            name: "demo", endpoint: "https://demo.r2.cloudflarestorage.com",
            region: "auto", accessKeyID: "k", pathStyle: true
        )
        expectTrue(S3ServiceFactory.service(for: demo) is MockS3Service, "demo 端点 → Mock")

        let noKey = Connection(
            name: "nokey", endpoint: "https://real.example.com",
            region: "auto", accessKeyID: "", pathStyle: true
        )
        expectTrue(S3ServiceFactory.service(for: noKey) is MockS3Service, "无 AccessKey → Mock")

        let real = Connection(
            name: "real", endpoint: "https://abc123.r2.cloudflarestorage.com",
            region: "auto", accessKeyID: "AKIA123", pathStyle: true
        )
        expectTrue(S3ServiceFactory.service(for: real, secretProvider: { "sec" }) is AWSS3Service, "真实端点 → AWSS3Service")
    }
}

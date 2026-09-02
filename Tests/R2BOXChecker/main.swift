import Foundation

/// 极简断言框架：CLT-only 环境没有 XCTest / Swift Testing，
/// `swift run R2BOXChecker` 顺序执行所有用例并以退出码报告结果。

nonisolated(unsafe) var currentTestName = ""
nonisolated(unsafe) var failures: [String] = []

func expectNil<T>(_ value: T?, _ label: String) {
    if value != nil {
        failures.append("[\(currentTestName)] \(label)：非 nil")
        print("  ❌ \(label)：非 nil")
    }
}

func expectTrue(_ condition: Bool, _ label: String) {
    if !condition {
        failures.append("[\(currentTestName)] \(label)")
        print("  ❌ \(label)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    if a != b {
        failures.append("[\(currentTestName)] \(label)：\(a) != \(b)")
        print("  ❌ \(label)：\(a) != \(b)")
    }
}

func expectNotNil<T>(_ value: T?, _ label: String) {
    if value == nil {
        failures.append("[\(currentTestName)] \(label)：为 nil")
        print("  ❌ \(label)：为 nil")
    }
}

/// 轮询等待异步条件成立（同步引擎操作有防抖/延迟）
func waitUntil(timeout: Double = 12, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(120))
    }
    return false
}

func runTest(_ name: String, _ body: () async throws -> Void) async {
    currentTestName = name
    print("▶ \(name)")
    do {
        try await body()
    } catch {
        failures.append("[\(name)] 抛出异常：\(error)")
        print("  ❌ 抛出异常：\(error)")
    }
    currentTestName = ""
}

// 顶层入口（该文件是模块中唯一的顶层代码，因此不需要 @main）


print("== R2BOX Checker ==")
await CoreCheck.runAll()
await SyncCheck.runAll()
await CryptoCheck.runAll()
print("== 结果 ==")
if failures.isEmpty {
    print("✅ 全部通过")
    exit(0)
} else {
    print("❌ \(failures.count) 项失败：")
    for failure in failures {
        print("   - \(failure)")
    }
    exit(1)
}

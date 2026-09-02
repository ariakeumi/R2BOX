// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "R2BOX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "R2BOXCore", targets: ["R2BOXCore"]),
        .library(name: "R2BOXSync", targets: ["R2BOXSync"]),
    ],
    targets: [
        // 领域模型 + S3/R2 抽象 + Mock 实现 + Keychain
        .target(name: "R2BOXCore"),
        // 本地工作区、文件监听、同步引擎（上传/冲突/重试）
        .target(name: "R2BOXSync", dependencies: ["R2BOXCore"]),
        // SwiftUI 应用
        .executableTarget(
            name: "R2BOXApp",
            dependencies: ["R2BOXCore", "R2BOXSync"],
            path: "Sources/R2BOX"
        ),
        // 校验器：CLT 环境没有 XCTest / Swift Testing，用可执行目标自行断言
        .executableTarget(
            name: "R2BOXChecker",
            dependencies: ["R2BOXCore", "R2BOXSync"],
            path: "Tests/R2BOXChecker"
        ),
    ]
)

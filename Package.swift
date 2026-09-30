// swift-tools-version: 6.1
// Retriever iOS 传输层（方案 §3；M2）。核心 target 零第三方依赖；gzip 用系统 zlib（linkedLibrary "z"）。
// 适配器是独立 product：只有用到的宿主才会链接 CocoaLumberjack / swift-log。
import PackageDescription

let package = Package(
    name: "Retriever",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Retriever", targets: ["Retriever"]),
        .library(name: "RetrieverCocoaLumberjack", targets: ["RetrieverCocoaLumberjack"]),
        .library(name: "RetrieverSwiftLog", targets: ["RetrieverSwiftLog"]),
    ],
    dependencies: [
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", from: "3.10.0"),
        // log(event:) 与 LogEvent.error 自 swift-log 1.12.0 起才有（主代理简报写的是 1.6.0，见实现报告）
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "Retriever",
            // 隐私清单随包分发（Apple：Swift 包资源默认位置 Sources/<target>/PrivacyInfo.xcprivacy）
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "RetrieverCocoaLumberjack",
            dependencies: [
                "Retriever",
                .product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
            ]
        ),
        .target(
            name: "RetrieverSwiftLog",
            dependencies: [
                "Retriever",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // 只给测试用：写 N 行后 SIGKILL 自己（真杀进程验收 R-1）。
        .executableTarget(
            name: "RetrieverKillHelper",
            dependencies: ["Retriever"]
        ),
        .testTarget(
            name: "RetrieverTests",
            dependencies: ["Retriever", "RetrieverKillHelper"]
        ),
        .testTarget(
            name: "RetrieverAdapterTests",
            dependencies: ["Retriever", "RetrieverCocoaLumberjack", "RetrieverSwiftLog"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

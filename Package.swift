// swift-tools-version: 6.1
// Retriever iOS 传输层（方案 §3；M2）。零第三方依赖；gzip 用系统 zlib（linkedLibrary "z"）。
// 适配器 product（RetrieverCocoaLumberjack / RetrieverSwiftLog）下一切片再加，避免现在拉依赖。
import PackageDescription

let package = Package(
    name: "Retriever",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Retriever", targets: ["Retriever"]),
    ],
    targets: [
        .target(
            name: "Retriever",
            linkerSettings: [.linkedLibrary("z")]
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
    ],
    swiftLanguageModes: [.v6]
)

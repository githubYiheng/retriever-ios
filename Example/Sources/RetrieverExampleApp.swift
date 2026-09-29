import SwiftUI
import Retriever
import RetrieverSwiftLog
import RetrieverCocoaLumberjack
import CocoaLumberjackSwift
import Logging

@main
struct RetrieverExampleApp: App {
    init() {
        ExampleSetup.run()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// 三种接入方式：直接调 `Retriever.log`、swift-log（`RetrieverLogHandler`）、CocoaLumberjack（`RetrieverDDLogger`）。
enum ExampleSetup {
    static var hasKey: Bool { !key.isEmpty }

    static var key: String { (Bundle.main.object(forInfoDictionaryKey: "RetrieverKey") as? String) ?? "" }

    static func run() {
        let base = (Bundle.main.object(forInfoDictionaryKey: "RetrieverBaseURL") as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://logs-staging.revdog.org")!
        // 1. 第一条日志之前 configure（key 为空 = 只写本地不上传）
        Retriever.configure(key: key, baseURL: base, options: Options())
        // 2. swift-log：进程内只能 bootstrap 一次；已有 handler 用 MultiplexLogHandler
        LoggingSystem.bootstrap { label in RetrieverLogHandler(label: label) }
        // 3. CocoaLumberjack：必须关异步分发，否则 R-1 只从 logger 回调起算
        asyncLoggingEnabled = false
        DDLog.add(RetrieverDDLogger(), with: .all)
        Retriever.log(.info, "example app launched", tag: "example")
        ScenarioRunner.runIfRequested()
    }
}

/// 真机验收用：`devicectl device process launch … com.loomalabs.retriever-example -- --scenario <name>`。
/// 无 UI 自动化依赖；每个场景末尾记一条 warn（义务行）作为服务端可见的完成标记。
enum ScenarioRunner {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--scenario"), i + 1 < args.count else { return }
        let name = args[i + 1]
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { run(name) }
    }

    struct ScenarioError: Error, CustomStringConvertible { let description = "scenario failure" }

    static func run(_ name: String) {
        switch name {
        case "error":
            for i in 0..<50 { Retriever.log(.debug, "debug line \(i)", tag: "scenario", attrs: ["i": .number(Double(i))]) }
            for i in 0..<5 { Retriever.log(.info, "info line \(i)", tag: "scenario") }
            Retriever.log(.error, "scenario error", tag: "scenario", attrs: ["code": .number(42), "ok": .bool(false)], error: ScenarioError())
        case "bulk":
            for i in 0..<5000 { Retriever.log(.info, "bulk info line \(i) 中文 emoji 😀 padding padding padding padding padding", tag: "bulk") }
            Retriever.log(.warn, "bulk done", tag: "scenario")
            Retriever.log(.error, "bulk error after 5000 lines", tag: "scenario")
        case "user":
            Retriever.setUser("device-test-user")
            Retriever.log(.info, "after setUser", tag: "scenario")
            Retriever.log(.error, "error as device-test-user", tag: "scenario")
        case "flush":
            Retriever.log(.info, "before flush", tag: "scenario")
            Task {
                let r = await Retriever.flush(includeContext: true)
                Retriever.log(.warn, "flush result: \(r)", tag: "scenario")
            }
        case "crash":
            for i in 0..<200 { Retriever.log(.info, "pre-crash info \(i)", tag: "scenario") }
            Retriever.log(.warn, "about to crash", tag: "scenario")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { fatalError("scenario crash") }
        default:
            Retriever.log(.warn, "unknown scenario \(name)", tag: "scenario")
        }
        if name != "crash" { Retriever.log(.warn, "scenario \(name) done", tag: "scenario") }
    }
}

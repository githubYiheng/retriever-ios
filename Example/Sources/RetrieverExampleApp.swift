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
    }
}

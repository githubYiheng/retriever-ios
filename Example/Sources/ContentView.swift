import SwiftUI
import Retriever
import CocoaLumberjackSwift
import Logging

enum ExampleError: Error {
    case paymentDeclined(code: Int)
}

struct ContentView: View {
    @State private var installId = "—"
    @State private var supportCode = "—"
    @State private var pending = 0
    @State private var uploadLevel = "—"
    @State private var localLevel = "—"
    @State private var user: String?
    @State private var lastAction = ""
    @State private var flushing = false

    private let logger = Logging.Logger(label: "example.swiftlog")

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("installId", value: installId)
                    LabeledContent("supportCode", value: supportCode)
                    LabeledContent("出站箱待传", value: "\(pending)")
                    LabeledContent("上传级别", value: uploadLevel)
                    LabeledContent("本地级别", value: localLevel)
                    LabeledContent("user", value: user ?? "（未登录）")
                    if !ExampleSetup.hasKey {
                        Text("未配置 key：只写本地不上传（运行 Example/gen-local-xcconfig.sh 后重新构建）")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if !lastAction.isEmpty {
                        Text(lastAction).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("写日志") {
                    Button("记 debug×50（Retriever.log）") {
                        for i in 0..<50 { Retriever.log(.debug, "debug line \(i)", tag: "example") }
                        done("写了 50 行 debug（低于上传级别：只随 error 批作 ctx）")
                    }
                    Button("记 info（swift-log）") {
                        logger.info("user opened plan page", metadata: ["plan": "yearly", "ab": ["group": "b"]])
                        done("swift-log info")
                    }
                    Button("记 warn（CocoaLumberjack）") {
                        DDLogWarn("slow response 3.2s", tag: "net")
                        done("DDLogWarn")
                    }
                    Button("记 error（带 attrs 与 error）") {
                        Retriever.log(.error, "purchase failed", tag: "billing",
                                      attrs: ["sku": .string("pro_yearly"), "retry": .bool(false), "ms": .number(3200)],
                                      error: ExampleError.paymentDeclined(code: 7))
                        done("error：2 s 去抖后封段并上传（带 ctx）")
                    }
                    Button("模拟大量日志（5000 行）") {
                        Task.detached {
                            for i in 0..<5000 {
                                Retriever.log(i % 100 == 0 ? .warn : .debug, "bulk \(i) " + String(repeating: "x", count: 80), tag: "bulk")
                            }
                        }
                        done("后台写 5000 行")
                    }
                }
                Section("操作") {
                    Button(flushing ? "上报中…" : "上报问题（flush）") {
                        flushing = true
                        Task {
                            let r = await Retriever.flush()
                            flushing = false
                            done("flush → \(r)")
                        }
                    }
                    .disabled(flushing)
                    Button("setUser 切换") {
                        user = user == nil ? "demo-user-1" : nil
                        Retriever.setUser(user)
                        done("setUser(\(user ?? "nil"))：封段，用户边界 = 批边界")
                    }
                    Button("崩溃（fatalError）", role: .destructive) {
                        Retriever.log(.warn, "about to crash on purpose", tag: "example")
                        fatalError("RetrieverExample: 主动崩溃（下次启动会合成 rtv.unclean_exit 并补传）")
                    }
                }
            }
            .navigationTitle("Retriever 示例")
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func done(_ s: String) {
        lastAction = s
        refresh()
    }

    private func refresh() {
        installId = Retriever.installId ?? "—"
        supportCode = Retriever.supportCode ?? "—"
        uploadLevel = Retriever.uploadLevel.rawValue
        localLevel = Retriever.localLevel.rawValue
        pending = ContentView.outboxPending()
    }

    /// 演示用：直接数出站箱里的 p*.gz（布局见方案 §3.2；宿主 app 不需要这么做）。
    static func outboxPending() -> Int {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier else { return 0 }
        let outbox = base.appendingPathComponent("\(bundle).retriever/outbox")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []
        return names.filter { $0.hasPrefix("p") && $0.hasSuffix(".gz") }.count
    }
}

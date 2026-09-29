import Foundation
#if canImport(os)
import os
#endif

/// 给已经用 `os.Logger` 的项目：方法名与 os.Logger 相同，只换构造即可。
///
/// ```swift
/// // 原来：let log = Logger(subsystem: "com.example.app", category: "billing")
/// let log = RetrieverLogger(subsystem: "com.example.app", category: "billing")
/// log.error("purchase failed", attrs: ["sku": .string("pro")], error: err)
/// ```
///
/// 每条同时写 `os.Logger`（消息 `privacy: .public`）与 `Retriever.log`：tag = category，attrs 合并 `subsystem`；
/// 级别 debug → debug、info / notice → info、warning → warn、error → error、fault → fatal。
/// 低于 `Retriever.localLevel` 的行不进 Retriever（不占 seq），但 os.Logger 照写。
public struct RetrieverLogger: @unchecked Sendable {
    typealias Emit = @Sendable (LogLevel, String, String?, [String: AttrValue]?, (any Error)?) -> Void

    public let subsystem: String
    public let category: String
    #if canImport(os)
    private let osLog: os.Logger
    #endif
    private let emit: Emit
    private let localLevel: @Sendable () -> LogLevel

    public init(subsystem: String, category: String) {
        self.init(subsystem: subsystem, category: category,
                  emit: { level, msg, tag, attrs, error in Retriever.log(level, msg, tag: tag, attrs: attrs, error: error) },
                  localLevel: { Retriever.localLevel })
    }

    /// 测试用：注入落点与本地级别。
    init(subsystem: String, category: String, emit: @escaping Emit, localLevel: @escaping @Sendable () -> LogLevel) {
        self.subsystem = subsystem
        self.category = category
        #if canImport(os)
        self.osLog = os.Logger(subsystem: subsystem, category: category)
        #endif
        self.emit = emit
        self.localLevel = localLevel
    }

    public func debug(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.debug("\(message, privacy: .public)")
        #endif
        forward(.debug, message, attrs, error)
    }

    public func info(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.info("\(message, privacy: .public)")
        #endif
        forward(.info, message, attrs, error)
    }

    public func notice(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.notice("\(message, privacy: .public)")
        #endif
        forward(.info, message, attrs, error)
    }

    public func warning(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.warning("\(message, privacy: .public)")
        #endif
        forward(.warn, message, attrs, error)
    }

    public func error(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.error("\(message, privacy: .public)")
        #endif
        forward(.error, message, attrs, error)
    }

    public func fault(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        #if canImport(os)
        osLog.fault("\(message, privacy: .public)")
        #endif
        forward(.fatal, message, attrs, error)
    }

    private func forward(_ level: LogLevel, _ message: String, _ attrs: [String: AttrValue]?, _ error: (any Error)?) {
        guard level >= localLevel() else { return }
        var merged = attrs ?? [:]
        if merged["subsystem"] == nil { merged["subsystem"] = .string(subsystem) }
        emit(level, message, category, merged, error)
    }
}

import Foundation
import Logging
import Retriever

/// swift-log → Retriever 适配器（方案 §3.10）。
///
/// ```swift
/// LoggingSystem.bootstrap { label in RetrieverLogHandler(label: label) }        // 进程内只能 bootstrap 一次
/// // 已有 handler：LoggingSystem.bootstrap { MultiplexLogHandler([StreamLogHandler.standardOutput(label: $0), RetrieverLogHandler(label: $0)]) }
/// ```
///
/// 映射：trace → debug、notice → info、warning → warn、critical → fatal；`tag` = logger label；
/// metadata（handler 自身 + metadataProvider + 调用处，后者优先）扁平化进 `attrs`：嵌套 dictionary 用 `a.b` 点号键、
/// 数组转 JSON 字符串、stringConvertible 用 description；≤ 32 键 / 4 KB 由 SDK 再截。
/// 默认 `logLevel = .info`；低于 `Retriever.localLevel` 的行在这里就丢弃（不占 seq）。
public struct RetrieverLogHandler: LogHandler {
    typealias Emit = @Sendable (LogLevel, String, String?, [String: AttrValue]?, (any Error)?) -> Void

    public let label: String
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    private let emit: Emit
    private let localLevel: @Sendable () -> LogLevel

    public init(label: String, metadataProvider: Logger.MetadataProvider? = nil) {
        self.init(label: label, metadataProvider: metadataProvider,
                  emit: { level, msg, tag, attrs, error in Retriever.log(level, msg, tag: tag, attrs: attrs, error: error) },
                  localLevel: { Retriever.localLevel })
    }

    /// 测试用：注入落点与本地级别。
    init(label: String, metadataProvider: Logger.MetadataProvider? = nil, emit: @escaping Emit,
         localLevel: @escaping @Sendable () -> LogLevel) {
        self.label = label
        self.metadataProvider = metadataProvider
        self.emit = emit
        self.localLevel = localLevel
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let level = RetrieverLogHandler.level(event.level)
        guard level >= localLevel() else { return }
        var merged = metadata
        if let p = metadataProvider { merged.merge(p.get()) { _, new in new } }
        if let m = event.metadata { merged.merge(m) { _, new in new } }
        let attrs = RetrieverLogHandler.flatten(merged)
        emit(level, event.message.description, label, attrs.isEmpty ? nil : attrs, event.error)
    }

    /// 旧签名（swift-log 1.x 带 source）：与 `log(event:)` 一致。
    @available(*, deprecated, renamed: "log(event:)")
    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String,
                    file: String, function: String, line: UInt) {
        log(event: LogEvent(level: level, message: message, metadata: metadata, source: source,
                            file: file, function: function, line: line))
    }

    /// 旧签名（swift-log 1.0）：与 `log(event:)` 一致。
    @available(*, deprecated, renamed: "log(event:)")
    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
                    file: String, function: String, line: UInt) {
        log(event: LogEvent(level: level, message: message, metadata: metadata, source: nil,
                            file: file, function: function, line: line))
    }

    static func level(_ l: Logger.Level) -> LogLevel {
        switch l {
        case .trace, .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .warn
        case .error: return .error
        case .critical: return .fatal
        }
    }

    /// 扁平化：嵌套 dictionary → `a.b` 点号键；数组 → JSON 字符串；stringConvertible → description。
    static func flatten(_ md: Logger.Metadata) -> [String: AttrValue] {
        var out: [String: AttrValue] = [:]
        func walk(_ key: String, _ v: Logger.Metadata.Value) {
            switch v {
            case .string(let s): out[key] = .string(s)
            case .stringConvertible(let c): out[key] = .string(c.description)
            case .array(let a): out[key] = .string(jsonString(a.map(jsonValue)))
            case .dictionary(let d):
                if d.isEmpty { out[key] = .string("{}") }
                for (k, v2) in d { walk(key.isEmpty ? k : "\(key).\(k)", v2) }
            }
        }
        for (k, v) in md { walk(k, v) }
        return out
    }

    static func jsonValue(_ v: Logger.Metadata.Value) -> Any {
        switch v {
        case .string(let s): return s
        case .stringConvertible(let c): return c.description
        case .array(let a): return a.map(jsonValue)
        case .dictionary(let d): return d.mapValues(jsonValue)
        }
    }

    static func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: v)
        }
        return String(decoding: d, as: UTF8.self)
    }
}

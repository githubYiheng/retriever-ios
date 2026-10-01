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
/// 每条同时写 `os.Logger` 与 `Retriever.log`：tag = category，attrs 合并 `subsystem`；
/// 级别 debug → debug、info / notice → info、warning → warn、error → error、fault → fatal。
/// 低于 `Retriever.localLevel` 的行不进 Retriever（不占 seq），但 os.Logger 照写。
///
/// 系统日志里消息默认 `privacy: .private`（ADR 0020 决定 5：替身的暴露面不超过被替换的 os.Logger 默认值——
/// 那里插值的动态字符串默认遮蔽）；消息都是写死文字、不含个人数据的宿主可用 `publicSystemLog: true` 打开。
/// Retriever 那一路不受影响（照常落盘上传，`redact` 照常作用）。
public struct RetrieverLogger: @unchecked Sendable {
    typealias Emit = @Sendable (LogLevel, String, String?, [String: AttrValue]?, (any Error)?) -> Void
    /// os.Logger 的级别（系统日志那一路）。
    enum SystemLevel: Sendable { case debug, info, notice, warning, error, fault }
    /// 测试用：替换系统日志那一路，收到 (级别, 消息, 是否公开)。
    typealias SystemLog = @Sendable (SystemLevel, String, Bool) -> Void

    public let subsystem: String
    public let category: String
    /// 消息写系统日志时是否 `.public`。
    let publicSystemLog: Bool
    #if canImport(os)
    private let osLog: os.Logger
    #endif
    private let emit: Emit
    private let localLevel: @Sendable () -> LogLevel
    private let systemLog: SystemLog?

    public init(subsystem: String, category: String) {
        self.init(subsystem: subsystem, category: category, publicSystemLog: false)
    }

    /// `publicSystemLog: true`：系统日志（Console.app / sysdiagnose）里消息按 `.public` 显示——只给消息都是写死文字的宿主用。
    public init(subsystem: String, category: String, publicSystemLog: Bool) {
        self.init(subsystem: subsystem, category: category, publicSystemLog: publicSystemLog,
                  emit: { level, msg, tag, attrs, error in Retriever.log(level, msg, tag: tag, attrs: attrs, error: error) },
                  localLevel: { Retriever.localLevel })
    }

    /// 测试用：注入落点、本地级别与系统日志那一路。
    init(subsystem: String, category: String, publicSystemLog: Bool = false, emit: @escaping Emit,
         localLevel: @escaping @Sendable () -> LogLevel, systemLog: SystemLog? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.publicSystemLog = publicSystemLog
        #if canImport(os)
        self.osLog = os.Logger(subsystem: subsystem, category: category)
        #endif
        self.emit = emit
        self.localLevel = localLevel
        self.systemLog = systemLog
    }

    public func debug(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.debug, message)
        forward(.debug, message, attrs, error)
    }

    public func info(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.info, message)
        forward(.info, message, attrs, error)
    }

    public func notice(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.notice, message)
        forward(.info, message, attrs, error)
    }

    public func warning(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.warning, message)
        forward(.warn, message, attrs, error)
    }

    public func error(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.error, message)
        forward(.error, message, attrs, error)
    }

    public func fault(_ message: String, attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        system(.fault, message)
        forward(.fatal, message, attrs, error)
    }

    /// 写系统日志。OSLogPrivacy 必须是编译期常量，所以公开 / 私有各写一支。
    private func system(_ level: SystemLevel, _ message: String) {
        if let systemLog {
            systemLog(level, message, publicSystemLog)
            return
        }
        #if canImport(os)
        if publicSystemLog {
            switch level {
            case .debug: osLog.debug("\(message, privacy: .public)")
            case .info: osLog.info("\(message, privacy: .public)")
            case .notice: osLog.notice("\(message, privacy: .public)")
            case .warning: osLog.warning("\(message, privacy: .public)")
            case .error: osLog.error("\(message, privacy: .public)")
            case .fault: osLog.fault("\(message, privacy: .public)")
            }
        } else {
            switch level {
            case .debug: osLog.debug("\(message, privacy: .private)")
            case .info: osLog.info("\(message, privacy: .private)")
            case .notice: osLog.notice("\(message, privacy: .private)")
            case .warning: osLog.warning("\(message, privacy: .private)")
            case .error: osLog.error("\(message, privacy: .private)")
            case .fault: osLog.fault("\(message, privacy: .private)")
            }
        }
        #endif
    }

    private func forward(_ level: LogLevel, _ message: String, _ attrs: [String: AttrValue]?, _ error: (any Error)?) {
        guard level >= localLevel() else { return }
        var merged = attrs ?? [:]
        if merged["subsystem"] == nil { merged["subsystem"] = .string(subsystem) }
        emit(level, message, category, merged, error)
    }
}

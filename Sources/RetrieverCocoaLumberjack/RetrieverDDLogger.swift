import Foundation
import CocoaLumberjackSwift
import Retriever

/// CocoaLumberjack → Retriever 适配器（方案 §3.10）。
///
/// ```swift
/// asyncLoggingEnabled = false            // CocoaLumberjackSwift 的全局开关，必须关（见下）
/// DDLog.add(RetrieverDDLogger())
/// ```
///
/// **宿主必须关闭异步分发**：CocoaLumberjack 默认把非 error 行异步交给 logger，开着时 R-1（「log 返回前已落盘」）
/// 只从本 logger 的回调起算，DDLog 队列里还没分发的行不在承诺之内（方案 §3.3-7；宪法 §3 登记的例外）。
///
/// 映射：flag error → error、warning → warn、info → info、debug / verbose → debug（CocoaLumberjack 没有 fatal）；
/// `tag` = `representedObject` 的字符串描述，否则文件名；`attrs` = `file` / `function` / `line`。
/// 低于 `Retriever.localLevel` 的行在这里就丢弃（不占 seq）。
public final class RetrieverDDLogger: DDAbstractLogger, @unchecked Sendable {
    typealias Emit = @Sendable (LogLevel, String, String?, [String: AttrValue]?) -> Void

    private let emit: Emit
    private let localLevel: @Sendable () -> LogLevel

    public override init() {
        emit = { level, msg, tag, attrs in Retriever.log(level, msg, tag: tag, attrs: attrs) }
        localLevel = { Retriever.localLevel }
        super.init()
    }

    /// 测试用：注入落点与本地级别。
    init(emit: @escaping Emit, localLevel: @escaping @Sendable () -> LogLevel) {
        self.emit = emit
        self.localLevel = localLevel
        super.init()
    }

    public override var loggerName: DDLoggerName { DDLoggerName("com.loomalabs.retriever") }

    public override func log(message logMessage: DDLogMessage) {
        guard let level = RetrieverDDLogger.level(for: logMessage.flag), level >= localLevel() else { return }
        let tag = logMessage.representedObject.map { String(describing: $0) } ?? logMessage.fileName
        var attrs: [String: AttrValue] = [
            "file": .string(logMessage.fileName),
            "line": .number(Double(logMessage.line)),
        ]
        if let f = logMessage.function { attrs["function"] = .string(f) }
        emit(level, logMessage.message, tag, attrs)
    }

    /// DDLogFlag → LogLevel；取最严重的那一位。
    static func level(for flag: DDLogFlag) -> LogLevel? {
        if flag.contains(.error) { return .error }
        if flag.contains(.warning) { return .warn }
        if flag.contains(.info) { return .info }
        if flag.contains(.debug) || flag.contains(.verbose) { return .debug }
        return nil
    }
}

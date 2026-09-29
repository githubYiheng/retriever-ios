import Foundation

// 宿主 API（方案 §3.10，三端同名）。签名照简报，不加不减。

/// 日志级别；`Comparable` 按 debug < info < warn < error < fatal。
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug, info, warn, error, fatal

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        case .fatal: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// attrs 的值：扁平 string / number / bool（§3.1）。number 用 Double；非有限数在编码时转 string。
public enum AttrValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

/// 异常（§3.1 `exc`）。
public struct LogException: Sendable, Equatable {
    public var type: String
    public var message: String
    public var stack: String?

    public init(type: String, message: String, stack: String? = nil) {
        self.type = type
        self.message = message
        self.stack = stack
    }
}

/// 给 `redact` 钩子看的行（落盘前）。seq / oseq 由 SDK 在落盘时分配，钩子不可改。
public struct LogLine: Sendable {
    public var ts: Int64
    public var level: LogLevel
    public var msg: String
    public var tag: String?
    public var attrs: [String: AttrValue]?
    public var exc: LogException?

    public init(ts: Int64, level: LogLevel, msg: String, tag: String? = nil,
                attrs: [String: AttrValue]? = nil, exc: LogException? = nil) {
        self.ts = ts
        self.level = level
        self.msg = msg
        self.tag = tag
        self.attrs = attrs
        self.exc = exc
    }
}

/// 宿主选项（§3.10；ADR 0004 / 0005）。
public struct Options: Sendable {
    /// 自动上传级别（ADR 0004）：该级别及以上的行是义务行（有 oseq）。远程配置可覆盖。
    public var uploadLevel: LogLevel = .warn
    /// 本地落盘级别（§3.3-9）：以下的行不写、不占 seq。远程配置可覆盖。
    public var localLevel: LogLevel = .debug
    /// 每日包数软上限（ADR 0005）；0 = 不限。远程配置可覆盖（钳制 0–10000）。
    public var dailyBatchCap: Int = 0
    /// 本地总量上限（宿主默认，远程可改，钳制 2–100 MB）。
    public var localCapBytes: Int = 20 * 1024 * 1024
    /// 落盘前同步调用；返回 nil = 丢弃（不占 seq、不记墓碑）。钩子内调 `log()` 视为重入直接忽略。
    public var redact: (@Sendable (LogLine) -> LogLine?)? = nil
    /// 会话目录 `proc-<name>`（§3.2）与信封 `process`。
    public var processName: String = "main"
    /// 可选：App Group 共享容器（扩展场景）。
    public var appGroup: String? = nil
    /// 进 `device.sdk = "retriever-ios/<ver>"` 与 `X-Rtv-Sdk`。
    public var sdkVersion: String = "0.1.0"

    public init() {}
}

/// `flush()` 的结果：`stored` = 出站箱里的 primary 批都已被服务端确认；`pending` 附原因。
public enum FlushResult: Sendable, Equatable {
    case stored
    case pending(String)
}

/// 静态入口：转发到进程内共享实例。`configure` 之前的 `log()` 也落盘（存储层不依赖 key）。
public enum Retriever {
    public static func configure(key: String,
                                 baseURL: URL = URL(string: "https://logs.revdog.org")!,
                                 options: Options = Options()) {
        SharedClient.shared.configure(key: key, baseURL: baseURL, options: options)
    }

    public static func setUser(_ id: String?) {
        SharedClient.shared.client().setUser(id)
    }

    public static func log(_ level: LogLevel, _ msg: String, tag: String? = nil,
                           attrs: [String: AttrValue]? = nil, error: (any Error)? = nil) {
        SharedClient.shared.client().log(level, msg, tag: tag, attrs: attrs, error: error)
    }

    public static func flush(includeContext: Bool = true) async -> FlushResult {
        await SharedClient.shared.client().flush(includeContext: includeContext)
    }

    public static func setEnabled(_ enabled: Bool) {
        SharedClient.shared.client().setEnabled(enabled)
    }

    public static func purgeLocal() {
        SharedClient.shared.client().purgeLocal()
    }

    public static var installId: String? {
        SharedClient.shared.client().installId
    }

    /// install_id 前 8 位 + "-" + session_no。
    public static var supportCode: String? {
        SharedClient.shared.client().supportCode
    }
}

/// 进程内共享实例（惰性创建；configure 前用默认 root 与默认 options）。
final class SharedClient: @unchecked Sendable {
    static let shared = SharedClient()

    private let lock = NSLock()
    private var instance: RetrieverClient?

    func client() -> RetrieverClient {
        lock.lock()
        defer { lock.unlock() }
        if let c = instance { return c }
        let options = Options()
        let c = RetrieverClient(root: RetrieverClient.defaultRoot(appGroup: nil), key: "",
                                baseURL: URL(string: "https://logs.revdog.org")!, options: options,
                                clock: SystemClock(), transport: URLSessionTransport(),
                                platform: SystemPlatform())
        instance = c
        return c
    }

    func configure(key: String, baseURL: URL, options: Options) {
        lock.lock()
        defer { lock.unlock() }
        let root = RetrieverClient.defaultRoot(appGroup: options.appGroup)
        if let c = instance {
            if c.root.standardizedFileURL == root.standardizedFileURL
                && c.processName == RetrieverClient.sanitizeProcessName(options.processName) {
                c.reconfigure(key: key, baseURL: baseURL, options: options)
                return
            }
            // root / 进程名变了（appGroup、processName 应在第一次 log 之前 configure）：
            // 旧实例封段收尾，新实例接管；旧 root 里的会话由下次打开该 root 的实例恢复。
            c.shutdown()
        }
        instance = RetrieverClient(root: root, key: key, baseURL: baseURL, options: options,
                                   clock: SystemClock(), transport: URLSessionTransport(),
                                   platform: SystemPlatform())
    }
}

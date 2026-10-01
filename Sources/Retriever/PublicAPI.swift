import Foundation

// 宿主 API（方案 §3.10，三端同名）。已发布的签名不改不减，只增（0.2.0 增：`isEnabled`、`purgeLocal(completion:)`、
// `AttrValue.int(_:)`、`RetrieverLogger(subsystem:category:publicSystemLog:)`，ADR 0020）。

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
/// 整数（订单号、雪花 id 等）用 `.int(_:)`：超出 Double 能精确表示的范围时按十进制字符串输出，不会被改写成错误的数。
public enum AttrValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

extension AttrValue {
    /// 整数型 attrs（ADR 0020 决定 3）：|v| ≤ 2^53 − 1 → `.number`（JSON 数字，逐字节同以前）；否则 → `.string`（十进制串）。
    /// 值没丢、只是换了类型，所以不打 `truncated`。是静态工厂不是新 case：宿主对 `AttrValue` 的穷举 switch 不受影响。
    public static func int(_ v: Int64) -> AttrValue {
        let maxSafe: Int64 = 9_007_199_254_740_991
        return (-maxSafe...maxSafe).contains(v) ? .number(Double(v)) : .string(String(v))
    }
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

/// SDK 版本号（唯一来源）：进 `device.sdk = "retriever-ios/<ver>"` 与 `X-Rtv-Sdk`。
/// 发布门禁（`scripts/sdk-ios-release.sh`）要求它 == 发布版本号。
public enum RetrieverVersion {
    public static let current = "0.2.0"
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
    /// 可选：App Group 共享容器（扩展场景）。**暂不支持生产**：挂起时会持有组容器里的文件锁，可能被系统以 0xdead10cc 终止。
    public var appGroup: String? = nil
    /// 进 `device.sdk = "retriever-ios/<ver>"` 与 `X-Rtv-Sdk`。
    public var sdkVersion: String = RetrieverVersion.current

    public init() {}
}

/// `flush()` 的结果：`stored` = flush 产生的批 15 s 内已被服务端确认；`pending` 附原因（offline / backoff / paused / timeout）。
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

    /// 用户同意 / 撤回。`false`：不写不传、不拉配置，落盘为 root 同级的标记文件，跨重启有效（直到 `setEnabled(true)`）。
    /// 在 `configure` 之前调用也生效（作为初值并落盘）。
    public static func setEnabled(_ enabled: Bool) {
        SharedClient.shared.client().setEnabled(enabled)
    }

    /// 本进程当前是否启用（启动时从盘上的禁用标记初始化）。
    public static var isEnabled: Bool {
        SharedClient.shared.client().isEnabled
    }

    /// 清空本地（新 install_id）。不阻塞调用线程：返回时清空尚未完成，需要新 `installId` 用 `purgeLocal(completion:)`。
    /// `purgeLocal()` 返回到清空完成之间写的行会随旧状态一起删除。
    public static func purgeLocal() {
        SharedClient.shared.client().purgeLocal()
    }

    /// 同 `purgeLocal()`；清空与重建完成后在后台线程回调（此时 `installId` 已是新值）。
    public static func purgeLocal(completion: @escaping @Sendable () -> Void) {
        SharedClient.shared.client().purgeLocal(completion: completion)
    }

    /// 生效的自动上传级别（远程配置钳制后；full_dump 期间为 debug）。未 configure 时 = Options 默认。
    public static var uploadLevel: LogLevel {
        SharedClient.shared.client().effectiveLevels.upload
    }

    /// 生效的本地落盘级别（远程配置钳制后）。适配器用它早过滤。未 configure 时 = Options 默认。
    public static var localLevel: LogLevel {
        SharedClient.shared.client().effectiveLevels.local
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
    /// 建实例：(root, key, baseURL, options, 带过来的宿主显式开关；nil = 按盘上标记)。
    typealias Make = @Sendable (URL, String, URL, Options, Bool?) -> RetrieverClient

    static let shared = SharedClient()

    private let lock = NSLock()
    private var instance: RetrieverClient?
    private let rootFor: @Sendable (String?) -> URL
    private let make: Make

    /// 测试注入 root 与实例工厂；生产用默认值。
    init(rootFor: @escaping @Sendable (String?) -> URL = { RetrieverClient.defaultRoot(appGroup: $0) },
         make: @escaping Make = { root, key, baseURL, options, enabled in
             RetrieverClient(root: root, key: key, baseURL: baseURL, options: options, clock: SystemClock(),
                             transport: URLSessionTransport(), platform: SystemPlatform(), enabled: enabled)
         }) {
        self.rootFor = rootFor
        self.make = make
    }

    func client() -> RetrieverClient {
        lock.lock()
        defer { lock.unlock() }
        if let c = instance { return c }
        let c = make(rootFor(nil), "", URL(string: "https://logs.revdog.org")!, Options(), nil)
        instance = c
        return c
    }

    func configure(key: String, baseURL: URL, options: Options) {
        lock.lock()
        defer { lock.unlock() }
        let root = rootFor(options.appGroup)
        var enabled: Bool?
        if let c = instance {
            if c.root.standardizedFileURL == root.standardizedFileURL
                && c.processName == RetrieverClient.sanitizeProcessName(options.processName) {
                c.reconfigure(key: key, baseURL: baseURL, options: options)
                return
            }
            // root / 进程名变了（appGroup、processName 应在第一次 log 之前 configure）：
            // 旧实例只投递封段收尾、不等待（锁内不做任何等待，ADR 0020 决定 1），新实例接管；
            // 旧 root 里的会话由下次打开该 root 的实例恢复。宿主显式的 setEnabled（configure 之前的调用）带到新实例、落盘到新 root 旁。
            c.shutdown()
            enabled = c.explicitEnabled
        }
        instance = make(root, key, baseURL, options, enabled)
    }
}

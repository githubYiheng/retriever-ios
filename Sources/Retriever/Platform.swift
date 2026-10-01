import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(UIKit)
import UIKit
#endif

// 可注入的平台边界：时钟、传输、生命周期 / 后台任务 / 网络 / 磁盘。测试用假实现替换。

/// 时钟：墙钟（行 ts、created_ms）与单调时钟（退避、暂停、配置 ttl、去抖）。
@_spi(RetrieverTesting)
public protocol Clock: Sendable {
    func wallMs() -> Int64
    func monoMs() -> Int64
    /// 流程内的短等待（flush 等待相邻请求间隔）。
    func sleep(ms: Int64) async
    /// 调度器的定时唤醒；被取消时抛错。离线 / 退避期间就是一次真正的睡眠，不空转。
    func timerSleep(ms: Int64) async throws
}

@_spi(RetrieverTesting)
public struct SystemClock: Clock {
    public init() {}

    public func wallMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    public func monoMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    public func sleep(ms: Int64) async {
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }

    public func timerSleep(ms: Int64) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }
}

@_spi(RetrieverTesting)
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

@_spi(RetrieverTesting)
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// 传输：专用 HTTP 客户端（不走宿主的 session，避免宿主拦截器把上传请求再记成日志，§3.3-6）。
@_spi(RetrieverTesting)
public protocol Transport: Sendable {
    /// 网络错误（超时、TLS、离线、被取消）返回 nil。
    func send(_ request: HTTPRequest) async -> HTTPResponse?
    /// 取消在途请求（后台任务过期）。
    func cancelAll()
}

/// 专用 URLSession：ephemeral、waitsForConnectivity 关、请求超时 30 s、不存 cookie、不跟随重定向（服务端不回 3xx）。
@_spi(RetrieverTesting)
public final class URLSessionTransport: NSObject, Transport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public override init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = ClientConstants.requestTimeoutS
        cfg.timeoutIntervalForResource = ClientConstants.requestTimeoutS * 2
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 1
        let delegate = NoRedirectDelegate()
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    public func send(_ request: HTTPRequest) async -> HTTPResponse? {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String { headers[ks.lowercased()] = vs }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            return nil
        }
    }

    public func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// 设备快照（进 meta.json 与信封 device；每个字段 ≤ 128 B）。
struct Device: Sendable, Equatable {
    var os: String
    var osVersion: String
    var model: String
    var appVersion: String
    var build: String
    var locale: String
    var sdk: String

    func sanitized() -> Device {
        func t(_ s: String) -> String { Text.truncate(s, maxBytes: Limits.deviceFieldBytes).0 }
        return Device(os: t(os), osVersion: t(osVersion), model: t(model), appVersion: t(appVersion),
                      build: t(build), locale: t(locale), sdk: t(sdk))
    }

    func encode(into o: inout JSONOut) {
        o.raw("{\"os\":"); o.string(os)
        o.raw(",\"os_version\":"); o.string(osVersion)
        o.raw(",\"model\":"); o.string(model)
        o.raw(",\"app_version\":"); o.string(appVersion)
        o.raw(",\"build\":"); o.string(build)
        o.raw(",\"locale\":"); o.string(locale)
        o.raw(",\"sdk\":"); o.string(sdk)
        o.raw("}")
    }

    static func decode(_ v: Any?) -> Device? {
        guard let d = v as? [String: Any] else { return nil }
        func s(_ k: String) -> String? { d[k] as? String }
        guard let os = s("os"), let ov = s("os_version"), let m = s("model"), let av = s("app_version"),
              let b = s("build"), let l = s("locale"), let sdk = s("sdk") else { return nil }
        return Device(os: os, osVersion: ov, model: m, appVersion: av, build: b, locale: l, sdk: sdk)
    }
}

@_spi(RetrieverTesting)
public enum PlatformEvent: Sendable {
    case didEnterBackground
    case willEnterForeground
    case protectedDataWillBecomeUnavailable
    case protectedDataDidBecomeAvailable
    case networkRestored
    /// 进程级 tracker 读到（或补读到）真实前后台状态：只更新会话的 last_state，不封段、不排空（ADR 0023 决定 6）。
    case foregroundStateChanged(Bool)
}

/// 生命周期事件接收方（RetrieverClient）。
@_spi(RetrieverTesting)
public protocol PlatformEventSink: AnyObject, Sendable {
    func platformEvent(_ event: PlatformEvent)
}

/// 平台钩子（§3.9）：iOS 用 UIKit / NWPathMonitor；macOS 与测试下生命周期为 no-op。
@_spi(RetrieverTesting)
public protocol PlatformHooks: Sendable {
    /// 设备快照字段（不含 sdk）。
    func deviceFields() -> [String: String]
    /// 当前是否在前台（新会话的初始 last_state）；nil = 未知或无前后台概念（app 扩展）→ last_state 留空，退出判 unknown。
    /// 任意线程可调（读进程级 tracker 的缓存值，不碰 UIKit）。
    func isForeground() -> Bool?
    /// `beginBackgroundTask`；返回令牌（nil = 平台不支持 / 拿不到）。
    func beginBackgroundTask(name: String, onExpire: @escaping @Sendable () -> Void) -> Int?
    func endBackgroundTask(_ token: Int)
    /// 开始把生命周期与网络恢复事件送给 sink。
    func startObserving(_ sink: any PlatformEventSink)
    /// 可用磁盘空间（nil = 未知，不按空间收缩上限）。
    func availableBytes(at url: URL) -> Int64?
}

@_spi(RetrieverTesting)
public final class SystemPlatform: PlatformHooks, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    private var lastSatisfied = true
    #endif

    public init() {}

    /// 首次触达 SDK 时装进程级前后台 tracker（ADR 0023 决定 6）。
    public static func installTracker() { ForegroundTracker.shared.install() }

    public func deviceFields() -> [String: String] {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<n], as: UTF8.self)
        }
        var model = machine
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { model = sim }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        #if os(iOS)
        let os = "ios"
        #elseif os(macOS)
        let os = "macos"
        #else
        let os = "unknown"
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "os": os,
            "os_version": osVersion,
            "model": model,
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "locale": Locale.current.identifier,
        ]
    }

    public func isForeground() -> Bool? {
        #if canImport(UIKit) && !os(watchOS)
        ForegroundTracker.shared.install()
        return ForegroundTracker.shared.state
        #else
        return true
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// 扩展安全地取 UIApplication.shared（扩展里不可用 → nil）。
    static func sharedApplication() -> UIApplication? {
        if Bundle.main.bundlePath.hasSuffix(".appex") { return nil }
        let sel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sel) else { return nil }
        return UIApplication.perform(sel)?.takeUnretainedValue() as? UIApplication
    }
    #endif

    public func beginBackgroundTask(name: String, onExpire: @escaping @Sendable () -> Void) -> Int? {
        #if canImport(UIKit) && !os(watchOS)
        let work: @MainActor () -> Int? = {
            guard let app = SystemPlatform.sharedApplication() else { return nil }
            let id = app.beginBackgroundTask(withName: name) { onExpire() }
            return id == .invalid ? nil : id.rawValue
        }
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
        #else
        return nil
        #endif
    }

    public func endBackgroundTask(_ token: Int) {
        #if canImport(UIKit) && !os(watchOS)
        let work: @MainActor () -> Void = {
            SystemPlatform.sharedApplication()?.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
        if Thread.isMainThread { MainActor.assumeIsolated { work() } } else { DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }
        #endif
    }

    public func startObserving(_ sink: any PlatformEventSink) {
        let post: @Sendable (PlatformEvent) -> Void = { [weak sink] e in sink?.platformEvent(e) }
        #if canImport(UIKit) && !os(watchOS)
        // 前后台事件由进程级 tracker 转发（它从首次触达 SDK 起就在记，不依赖实例何时建成）
        ForegroundTracker.shared.install()
        ForegroundTracker.shared.subscribe(sink)
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, PlatformEvent)] = [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, .protectedDataWillBecomeUnavailable),
            (UIApplication.protectedDataDidBecomeAvailableNotification, .protectedDataDidBecomeAvailable),
        ]
        var tokens: [NSObjectProtocol] = []
        for (name, ev) in pairs {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in post(ev) })
        }
        lock.lock()
        observers.append(contentsOf: tokens)
        lock.unlock()
        #endif
        #if canImport(Network)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let was = self.lastSatisfied
            self.lastSatisfied = path.status == .satisfied
            self.lock.unlock()
            // 只用于提前唤醒，不做可达性预检。
            if !was && path.status == .satisfied { post(.networkRestored) }
        }
        m.start(queue: DispatchQueue(label: "retriever.path"))
        lock.lock()
        monitor = m
        lock.unlock()
        #endif
    }

    public func availableBytes(at url: URL) -> Int64? { FS.availableBytes(url) }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        #if canImport(Network)
        monitor?.cancel()
        #endif
    }
}

/// tracker 的平台边界（可注入，测试用假实现驱动状态机；UIKit 的真实行为留给模拟器验收）。
protocol ForegroundSource: AnyObject, Sendable {
    /// 有前后台概念（扩展里没有 → tracker 不装，状态恒为 nil）。
    var available: Bool { get }
    var isMainThread: Bool { get }
    /// 在主线程上调：读真实状态（UIApplication 还没建好 → nil，保持原值）。
    func readForeground() -> Bool?
    func onMain(_ f: @escaping @Sendable () -> Void)
    /// 开始把前后台通知送给 handler（在主线程上调 handler）。
    func observe(_ handler: @escaping @Sendable (ForegroundNote) -> Void)
}

enum ForegroundNote: Sendable { case didEnterBackground, willEnterForeground, didBecomeActive, willResignActive }

/// 进程级前后台 tracker（ADR 0023 决定 6；简报 §1.4）：首次触达 SDK 时安装，不依赖实例。
/// - 初值只在主线程上读：主线程触达 → 当场读；非主线程 → 先记 unknown（不是前台），切到主线程补读；
/// - didEnterBackground / willEnterForeground 是明确的状态；didBecomeActive / willResignActive 时在主线程上重读真实状态；
/// - 扩展里（没有 UIApplication）不装：状态恒为 nil（无前后台概念）。
/// 实例订阅它：新会话的 last_state 取当前值；状态变化转成 `PlatformEvent` 送给实例。
final class ForegroundTracker: @unchecked Sendable {
    static let shared = ForegroundTracker(source: ForegroundTracker.systemSource())

    private let source: any ForegroundSource
    private let lock = NSLock()
    private var installed = false
    private var current: Bool?
    private var sinks: [WeakSink] = []

    private struct WeakSink { weak var sink: (any PlatformEventSink)? }

    init(source: any ForegroundSource) { self.source = source }

    var state: Bool? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func subscribe(_ sink: any PlatformEventSink) {
        lock.lock()
        sinks.removeAll { $0.sink == nil }
        sinks.append(WeakSink(sink: sink))
        lock.unlock()
    }

    private func post(_ e: PlatformEvent) {
        lock.lock()
        let targets = sinks.compactMap(\.sink)
        lock.unlock()
        for t in targets { t.platformEvent(e) }
    }

    /// 设状态；变了（含 unknown → 已知）返回 true。
    private func set(_ fg: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = current != fg
        current = fg
        return changed
    }

    func install() {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()
        guard source.available else { return }
        source.observe { [weak self] note in self?.handle(note) }
        if source.isMainThread {
            resync()
        } else {
            source.onMain { [weak self] in self?.resync() }
        }
    }

    func handle(_ note: ForegroundNote) {
        switch note {
        case .didEnterBackground:
            _ = set(false)
            post(.didEnterBackground)
        case .willEnterForeground:
            _ = set(true)
            post(.willEnterForeground)
        case .didBecomeActive, .willResignActive:
            resync()
        }
    }

    /// 主线程：重读真实状态（读不到时保持原值，等下一次通知）。
    private func resync() {
        guard let fg = source.readForeground() else { return }
        if set(fg) { post(.foregroundStateChanged(fg)) }
    }

    static func systemSource() -> any ForegroundSource {
        #if canImport(UIKit) && !os(watchOS)
        return UIKitForegroundSource()
        #else
        return NoForegroundSource()
        #endif
    }
}

/// 没有前后台概念的平台（macOS 包测试、watchOS）。
final class NoForegroundSource: ForegroundSource, @unchecked Sendable {
    var available: Bool { false }
    var isMainThread: Bool { Thread.isMainThread }
    func readForeground() -> Bool? { nil }
    func onMain(_ f: @escaping @Sendable () -> Void) {}
    func observe(_ handler: @escaping @Sendable (ForegroundNote) -> Void) {}
}

#if canImport(UIKit) && !os(watchOS)
final class UIKitForegroundSource: ForegroundSource, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    var available: Bool { !Bundle.main.bundlePath.hasSuffix(".appex") }
    var isMainThread: Bool { Thread.isMainThread }

    func readForeground() -> Bool? {
        guard let app = SystemPlatform.sharedApplication() else { return nil }
        return MainActor.assumeIsolated { app.applicationState != .background }
    }

    func onMain(_ f: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: f) }

    func observe(_ handler: @escaping @Sendable (ForegroundNote) -> Void) {
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, ForegroundNote)] = [
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.willResignActiveNotification, .willResignActive),
        ]
        var tokens: [NSObjectProtocol] = []
        for (name, note) in pairs {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in handler(note) })
        }
        lock.lock()
        observers = tokens
        lock.unlock()
    }
}
#endif

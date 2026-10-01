import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 进程内共享入口（静态 `Retriever.*` 的实现，ADR 0023）：
/// - **configure 之前没有实例**：不建 client / 引擎线程 / 平台监听 / 定时器；`log()` 只把行追加到 pre 文件（`PreLog`）；
/// - 首次 `configure` 建实例（真 Options / processName / root），把暂存的用户、开关与本进程 pre 文件交给它收编；
/// - 之后的 `configure` 走同一实例：processName / appGroup 只认首次（`rtv.reconfigure_ignored`），同参数只更新 redact。
@_spi(RetrieverTesting)
public final class SharedClient: @unchecked Sendable {
    /// 生产单例：首次触达 SDK 时装进程级前后台 tracker（ADR 0023 决定 6）。
    static let shared: SharedClient = {
        SystemPlatform.installTracker()
        return SharedClient()
    }()

    private let lock = NSLock()
    private var instance: RetrieverClient?
    private let rootFor: @Sendable (String?) -> URL
    private let clock: any Clock
    private let platform: any PlatformHooks
    private let makeTransport: @Sendable () -> any Transport
    let counter = DropCounter()
    let defaultRoot: URL
    let pre: PreLog

    /// 测试注入 root、时钟、平台与传输；生产用默认值。
    public init(rootFor: @escaping @Sendable (String?) -> URL = { RetrieverClient.defaultRoot(appGroup: $0) },
                clock: any Clock = SystemClock(),
                platform: any PlatformHooks = SystemPlatform(),
                transport: @escaping @Sendable () -> any Transport = { URLSessionTransport() }) {
        self.rootFor = rootFor
        self.clock = clock
        self.platform = platform
        self.makeTransport = transport
        let root = rootFor(nil)
        self.defaultRoot = root
        self.pre = PreLog(root: root, clock: clock, platform: platform, counter: counter)
    }

    private func current() -> RetrieverClient? {
        lock.lock()
        defer { lock.unlock() }
        return instance
    }

    /// 测试：configure 之后的实例（之前为 nil）。
    public var instanceForTesting: RetrieverClient? { current() }

    // MARK: 宿主 API

    /// key 先修剪（ADR 0025），先于首次 / 再次 configure 两条路径：之后指纹、请求头、同参数判定都用修剪后的值。
    /// 配置诊断在共享锁之外出（出口不在持 SDK 锁时调；禁用时照常出）。
    public func configure(key rawKey: String, baseURL: URL, options: Options) {
        let key = ConfigCheck.trim(rawKey)
        apply(key: key, baseURL: baseURL, options: options)
        let fp = ConfigRules.keyFingerprint(key)
        for d in ConfigCheck.check(rawKey: rawKey, key: key, baseURL: baseURL) {
            ConfigDiagnostics.emit(d, keyFp: fp, baseURL: baseURL.absoluteString)
        }
    }

    private func apply(key: String, baseURL: URL, options: Options) {
        lock.lock()
        defer { lock.unlock() }
        let root = rootFor(options.appGroup)
        if let c = instance {
            c.configureAgain(key: key, baseURL: baseURL, options: options, root: root)
            return
        }
        // 交接：此后 pre 路径不再写（竞态里的行转给实例，照常过 redact / local_level）
        let h = pre.handOff()
        let seed = InstanceSeed(root: root, key: key, baseURL: baseURL, options: options, enabled: h.enabled, user: h.user,
                                pre: h.file, preDir: pre.dir,
                                adoptsOrphans: root.standardizedFileURL.path == defaultRoot.standardizedFileURL.path,
                                counter: counter)
        instance = RetrieverClient(seed: seed, clock: clock, transport: makeTransport(), platform: platform)
    }

    public func log(_ level: LogLevel, _ msg: String, tag: String? = nil, attrs: [String: AttrValue]? = nil,
                    error: (any Error)? = nil) {
        if Reentrancy.active { return }
        if let c = current() {
            c.log(level, msg, tag: tag, attrs: attrs, error: error)
            return
        }
        switch pre.accepting() {
        case .none:
            // 刚交接：实例已建好（或正被 configure 建，current() 等到它）
            current()?.log(level, msg, tag: tag, attrs: attrs, error: error)
            return
        case .some(false):
            return   // 禁用（含标记判定未知）：不写、不计数
        case .some(true):
            break
        }
        // configure 之前：编码（同 LineEncoder，含截断）、一次 write(2) 追加到 pre 文件。级别不过滤，不判义务。
        // 错误描述是宿主代码：在任何 SDK 锁之外、重入保护之内取
        Reentrancy.active = true
        defer { Reentrancy.active = false }
        let line = LogLine(ts: clock.wallMs(), level: level, msg: msg, tag: tag, attrs: attrs, exc: error.map(LineEncoder.exception))
        let enc = LineEncoder.encode(line)
        if pre.append(level: level, ts: line.ts, body: enc.body) == .handedOff, let c = current() {
            c.emitPrebuilt(line)
        }
    }

    public func setUser(_ id: String?) {
        if let c = current() {
            c.setUser(id)
            return
        }
        if pre.setUser(Text.sanitizeUserId(id)) == .handedOff { current()?.setUser(id) }
    }

    /// configure 之前：`.pending("paused")`（不新增公开原因值）。
    public func flush(includeContext: Bool = true) async -> FlushResult {
        guard let c = current() else { return .pending("paused") }
        return await c.flush(includeContext: includeContext)
    }

    public func setEnabled(_ enabled: Bool) {
        if let c = current() {
            c.setEnabled(enabled)
            return
        }
        if pre.setEnabled(enabled) == .handedOff { current()?.setEnabled(enabled) }
    }

    public var isEnabled: Bool {
        if let c = current() { return c.isEnabled }
        if let v = pre.isEnabled() { return v }
        return current()?.isEnabled ?? false
    }

    /// configure 之前：删本进程 pre 文件、清零计数，按「改名再删」清默认 root（与实例的 purge 共用 `FS.moveAside`）。
    /// 删 pre 文件与改名在 PreLog 的锁内一步完成（共享锁也持着：随后的 configure 不会在将被改名的 root 里建实例；这期间进来的 log
    /// 等到改名之后、写进新 root 的新 pre 文件）；删除与回调在后台线程。改名失败时的逐项删除也在后台（删完再回调），
    /// 不删 pre 目录里本进程此后新建的 pre 文件。
    public func purgeLocal(completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        if let c = instance {
            lock.unlock()
            if let completion { c.purgeLocal(completion: completion) } else { c.purgeLocal() }
            return
        }
        let (moved, renamed) = pre.purgeAndMoveAside()
        lock.unlock()
        let root = defaultRoot
        let pre = self.pre
        DispatchQueue.global(qos: .utility).async {
            if let moved { FS.remove(moved) }
            if !renamed {
                for name in FS.list(root) where name != "pre" { FS.remove(root.appendingPathComponent(name)) }
                let dir = root.appendingPathComponent("pre")
                for name in FS.list(dir) where name != pre.currentName { FS.remove(dir.appendingPathComponent(name)) }
            }
            completion?()
        }
    }

    /// configure 之前 = warn（不建任何东西）。
    public var uploadLevel: LogLevel { current()?.effectiveLevels.upload ?? .warn }
    /// configure 之前 = debug（适配器早过滤按全收）。
    public var localLevel: LogLevel { current()?.effectiveLevels.local ?? .debug }
    /// configure 之前 nil。
    public var installId: String? { current()?.installId }
    public var supportCode: String? { current()?.supportCode }

    /// 测试：configure 之前的计数器。
    public var droppedCountForTesting: Int64 { counter.snapshot.count }
}

/// configure 之前的状态（ADR 0023；简报 §1.1）：本进程的 pre 文件、暂存的用户与显式开关。
/// 一把静态小锁串行化（与实例无关）；首次 configure 交接后不再写。
final class PreLog: @unchecked Sendable {
    enum Result { case done, handedOff }

    private let lock = NSLock()
    let root: URL
    let dir: URL
    let marker: URL
    private let clock: any Clock
    private let platform: any PlatformHooks
    private let counter: DropCounter
    private var file: PreFile?
    private var handedOff = false
    private var explicitEnabled: Bool?
    private var user: String?

    /// 头记录里的进程名：iOS 没有自动进程名，取 `Options` 的默认值（扩展要在 configure 里给自己的 processName）。
    static let process = "main"

    init(root: URL, clock: any Clock, platform: any PlatformHooks, counter: DropCounter) {
        self.root = root
        self.dir = root.appendingPathComponent("pre", isDirectory: true)
        self.marker = Engine.sibling(of: root, suffix: ".disabled")
        self.clock = clock
        self.platform = platform
        self.counter = counter
    }

    /// 写开关：宿主显式值 ?? 标记三态（未知 = 禁用，ADR 0024 决定 6）。持锁调用。
    private func enabledLocked() -> Bool {
        explicitEnabled ?? (FS.markerState(marker) == .absent)
    }

    /// nil = 已交接。
    func accepting() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return handedOff ? nil : enabledLocked()
    }

    func isEnabled() -> Bool? { accepting() }

    /// 追加一行（`r` = 0）。没处可写（建不了目录 / 文件、首次解锁前）、写失败、超 1 MB → 计数（不重试、不缓存）。禁用 → 不写不计。
    func append(level: LogLevel, ts: Int64, body: [UInt8]) -> Result {
        lock.lock()
        defer { lock.unlock() }
        if handedOff { return .handedOff }
        guard enabledLocked() else { return .done }
        if file == nil {
            if FS.ensureDir(root) { FS.excludeFromBackup(root) }
            trimStalePreFiles()
            let device = Engine.deviceSnapshot(platform, sdkVersion: RetrieverVersion.current)
            // started_ms = 触发建文件的那一行的 ts（会话开始不晚于它的第一行）
            guard let f = PreFile.create(dir: dir, header: PreFile.header(startedMs: ts, process: PreLog.process,
                                                                          device: device)) else {
                counter.add(level: level, ts: ts)
                return .done
            }
            file = f
            // 「或随后创建」：文件建在 setUser 之后时补一条用户切换记录，收编时用户边界才对；写不成 → 标满（之后的行计数）
            if let u = user, !f.appendUser(u, capped: true) { f.markFull() }
        }
        if let f = file, f.appendLine(redacted: false, body: body) { return .done }
        counter.add(level: level, ts: ts)
        return .done
    }

    /// 清洗后的用户记内存；pre 文件已存在则追加一条用户切换记录。
    func setUser(_ u: String?) -> Result {
        lock.lock()
        defer { lock.unlock() }
        if handedOff { return .handedOff }
        guard u != user else { return .done }
        user = u
        // 用户切换记录写不成：标满（粘滞），之后 configure 之前的行计数——免得它们挂到错的用户名下
        // （提交时的用户对齐只修正最终值，修不了中间的行）
        if let f = file, !f.appendUser(u, capped: true) { f.markFull() }
        return .done
    }

    /// 从不 configure 的宿主（R-5）：进程内首次建 pre 文件之前，没有活持有者（flock 可得）的旧 pre 文件总量超过 4 MB 或
    /// 个数超过 8 个时，从 mtime 最旧的删起直到满足（不计数）。别的活进程的 pre 文件不算、不碰。持锁调用。
    private func trimStalePreFiles() {
        var stale: [(url: URL, size: Int64, mtime: Int64)] = []
        for name in FS.list(dir) where PreName.isValid(name) {
            let url = dir.appendingPathComponent(name)
            guard FS.withFreeFileLock(url) else { continue }
            stale.append((url, FS.size(url) ?? 0, FS.mtimeMs(url) ?? 0))
        }
        var total = stale.reduce(Int64(0)) { $0 + $1.size }
        var count = stale.count
        for f in stale.sorted(by: { ($0.mtime, $0.url.lastPathComponent) < ($1.mtime, $1.url.lastPathComponent) }) {
            guard total > ClientConstants.preDirMaxBytes || count > ClientConstants.preDirMaxFiles else { break }
            if FS.withFreeFileLock(f.url, { _ = unlink(f.url.path) }) {
                total -= f.size
                count -= 1
            }
        }
    }

    /// 立即落盘 / 删除标记（文件级），并记内存值。true 而删不掉 → 不改（仍按标记 = 禁用）；false 而写不成 → 内存照样禁用，
    /// configure 后实例接着重试（显式值随交接带过去）。
    func setEnabled(_ v: Bool) -> Result {
        lock.lock()
        defer { lock.unlock() }
        if handedOff { return .handedOff }
        if v {
            guard FS.unlinkIfPresent(marker) else { return .done }
            explicitEnabled = true
        } else {
            explicitEnabled = false
            // 只建缺失的父目录，不给它们打标（Application Support 本身不能被排除备份）
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FS.writeAtomic(marker, [])
        }
        return .done
    }

    struct Handoff {
        var file: PreFile?
        var user: String?
        var enabled: Bool?
    }

    func handOff() -> Handoff {
        lock.lock()
        defer { lock.unlock() }
        handedOff = true
        let h = Handoff(file: file, user: user, enabled: explicitEnabled)
        file = nil
        return h
    }

    /// configure 之前的 purge：锁内删本进程 pre 文件（放锁）、清零计数、把默认 root 改名移走（一次 rename）。
    func purgeAndMoveAside() -> (moved: URL?, renamed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let f = file {
            unlink(f.url.path)
            f.close()
            file = nil
        }
        counter.reset()
        let r = FS.moveAside(root)
        return (r.moved, r.ok)
    }

    /// 本进程当前 pre 文件名（purge 退回逐项删除时不删它）。
    var currentName: String? {
        lock.lock()
        defer { lock.unlock() }
        return file?.name
    }

    /// 测试：本进程 pre 文件。
    var fileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return file?.url
    }
}

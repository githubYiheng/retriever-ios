import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 建实例的全部输入（首次 configure 时由共享入口给出；直接建实例的测试 / KillHelper 用默认值）。
struct InstanceSeed {
    var root: URL
    var key: String
    var baseURL: URL
    var options: Options
    /// configure 之前宿主显式的 setEnabled（nil = 按盘上标记判定）。
    var enabled: Bool? = nil
    /// configure 之前暂存的用户（已清洗）。
    var user: String? = nil
    /// 本进程 configure 之前写的 pre 文件（有则进入收编中）。
    var pre: PreFile? = nil
    /// pre 文件目录（`<默认 root>/pre`）。
    var preDir: URL
    /// 本实例用默认 root：负责孤儿 pre 文件的收编与 7 天驱逐。
    var adoptsOrphans: Bool
    var counter: DropCounter
}

/// 实例（静态 API 转发到进程内共享实例；测试直接建实例：临时目录 + 假 transport + 假时钟）。
///
/// 并发模型：
/// - 热路径 `log()` 只碰 `Writer`（NSLock，锁内一次 write(2)），不排队、不等待任何后台工作；
/// - 其余一切磁盘状态（封段、物化、出站箱、驱逐、恢复、收编、配置、队列决策）在串行 `work` 队列上；
/// - 网络请求在队列外（async），发送前后各回队列一次做决策与落盘；
/// - 宿主线程永不等待 `work` 队列（ADR 0020 决定 1）：fatal、purgeLocal 一律投递后立即返回；
/// - 任何时候不在持 SDK 锁时调宿主代码（redact、错误描述、回调）。
@_spi(RetrieverTesting)
public final class RetrieverClient: PlatformEventSink, @unchecked Sendable {
    public let root: URL
    let processName: String
    let clock: any Clock
    let transport: any Transport
    let platform: any PlatformHooks
    let writer: Writer
    let engine: Engine
    let work = DispatchQueue(label: "retriever.work", qos: .utility)
    private let workKey = DispatchSpecificKey<Bool>()
    private let ctl = Control()
    /// 串行化「内存开关 + 盘上禁用标记」的变更（setEnabled 在宿主线程，补写标记在 work 队列）；锁内只有一次 unlink / 读写标志。
    private let enabledLock = NSLock()
    /// 禁用标记还没写成（写失败每次调度 tick 重试）。受 enabledLock 保护。
    private var markerPending = false
    /// 宿主在本实例上最后一次显式 setEnabled 的值（含 configure 之前交接过来的；nil = 没调过，按标记判定）。受 enabledLock 保护。
    private var requestedEnabled: Bool?
    /// 上一次标记判定是「未知」（按禁用处理，每次调度唤醒重判）。受 enabledLock 保护。
    private var markerUnknown = false
    /// flush 合并（判定 + 追加标记行）串行化。
    private let flushLock = NSLock()

    /// 「同参数重复 configure」的比较对象（ADR 0023 决定 5）。
    struct Params: Equatable {
        var key: String
        var baseURL: String
        var host: HostDefaults
        var sdkVersion: String
    }

    /// 锁保护的调度 / 排空 / 后台任务状态。
    final class Control: @unchecked Sendable {
        let lock = NSLock()
        var redact: (@Sendable (LogLine) -> LogLine?)?
        var params: Params?
        var installId: String?
        var sessionNo: Int64 = 0
        var bootstrapped = false
        /// startup 的一次性部分（恢复旧会话、孤儿收编……）已跑过。
        var startedUp = false
        var nextBootstrapMono: Int64 = 0
        var draining = false
        var rekick = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        var lastStop: (reason: String, wake: Int64?) = ("", nil)
        var stopRequested = false
        var timerTask: Task<Void, Never>?
        var timerTarget: Int64?
        var configFetching = false
        /// 拉配置在途时又有新请求（身份变了等）：在途结束后再拉一次。
        var configRefetch = false
        /// 进行中的 purgeLocal 个数：> 0 时排空每次取批前退出、不拉配置。
        var purging = 0
        var bgToken: Int?
        var tombstoneScheduled = false
        var closed = false
        /// 会话目录消失后的重新 bootstrap 已投递。
        var vanishScheduled = false
        /// `rtv.root_vanished` 还没写成（等有可写会话）。
        var vanishNotice = false
        /// SDK 自己取消在途请求（purge、后台到期）的代数：请求前后不同 = 被 SDK 取消（不计毒批失败）。
        var cancelEpoch = 0
        /// 等待中的 flush（合并用）。
        var flushGroup: FlushGroup?
        /// flush 等待窗口（测试可调小）。
        var flushWindowMs: Int64 = RetrieverClient.flushWindowMs

        func with<T>(_ body: (Control) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    /// 直接建实例（测试 / KillHelper）：没有 configure 之前的状态；pre 目录 = `<root>/pre`。
    @_spi(RetrieverTesting)
    public convenience init(root: URL, key: String, baseURL: URL, options: Options, clock: any Clock,
                            transport: any Transport, platform: any PlatformHooks) {
        self.init(seed: InstanceSeed(root: root, key: key, baseURL: baseURL, options: options,
                                     preDir: root.appendingPathComponent("pre"), adoptsOrphans: true, counter: DropCounter()),
                  clock: clock, transport: transport, platform: platform)
    }

    init(seed: InstanceSeed, clock: any Clock, transport: any Transport, platform: any PlatformHooks) {
        self.root = seed.root
        self.processName = RetrieverClient.sanitizeProcessName(seed.options.processName)
        self.clock = clock
        self.transport = transport
        self.platform = platform
        self.writer = Writer(clock: clock, host: HostDefaults(seed.options), counter: seed.counter)
        self.engine = Engine(root: seed.root, processName: processName, key: seed.key, baseURL: seed.baseURL,
                             sdkVersion: seed.options.sdkVersion, clock: clock, platform: platform, writer: writer,
                             preDir: seed.preDir, adoptsOrphans: seed.adoptsOrphans)
        work.setSpecific(key: workKey, value: true)
        ctl.redact = seed.options.redact
        ctl.params = Params(key: seed.key, baseURL: seed.baseURL.absoluteString, host: HostDefaults(seed.options),
                            sdkVersion: seed.options.sdkVersion)
        // 写入开关 = 宿主显式值 ?? 标记三态判定（未知 = 禁用，ADR 0024 决定 6），在同步 bootstrap 之前定好。
        // 显式值照 setEnabled 的规则落盘（true 删标记、删不掉保持禁用；false 稍后写标记）
        let state = FS.markerState(engine.disabledMarkerURL)
        var on = state == .absent
        if let e = seed.enabled {
            on = e && FS.unlinkIfPresent(engine.disabledMarkerURL)
            markerPending = !e
        }
        requestedEnabled = seed.enabled
        markerUnknown = seed.enabled == nil && state == .unknown
        writer.setEnabled(on)
        engine.enabled = on
        // configure 之前的用户与 pre 文件：有 pre 文件 → 收编中（会话从 user = nil 起，用户切换按 pre 文件里的记录重放）
        if let p = seed.pre {
            writer.beginAdopting(p, hostUser: seed.user)
            engine.pendingAdoption = PendingAdoption(file: p)
        } else {
            writer.setInitialUser(seed.user)
        }
        // 同步建会话：init 返回后 log() 立即落盘（收编中则进 pre 文件）
        let ok = engine.bootstrap()
        ctl.with { c in
            c.bootstrapped = ok
            c.installId = engine.install?.installId
            c.sessionNo = engine.current?.meta.sessionNo ?? 0
        }
        if ok { engine.reportDropped() }
        platform.startObserving(self)
        work.async { [self] in startup() }
    }

    deinit {
        ctl.with { c in
            c.timerTask?.cancel()
            c.timerTask = nil
        }
    }

    static func sanitizeProcessName(_ s: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var out = String(s.map { allowed.contains($0) ? $0 : "_" })
        out = Text.truncate(out, maxBytes: Limits.processBytes).0
        return out.isEmpty ? "main" : out
    }

    /// `Library/Application Support/<bundle-id>.retriever/`；appGroup 非空则用 App Group 容器里同样位置的
    /// `<appGroup>.retriever/`（主 app 与扩展共享同一个 root，所以用组 id 而非各自的 bundle id 命名）。
    public static func defaultRoot(appGroup: String?) -> URL {
        let bundle = Bundle.main.bundleIdentifier ?? "retriever"
        if let g = appGroup, !g.isEmpty,
           let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
            return c.appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("\(g).retriever", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("\(bundle).retriever", isDirectory: true)
    }

    // MARK: 启动（work 队列）

    /// 收编（若有）先做；收编没提交（读不出 pre 文件、提交失败）也照常往下走（与 Android 同口径）：当前会话靠
    /// `pendingAdoption` 的闸门保护（processSeals / flushTombstones / 驱逐物化 / flush 标记），提交前不物化、不上传、不参与驱逐；
    /// 收编由定时器重试，提交后再处理当前会话的封段。之后的一次性部分：清残留、扫出站箱、孤儿 pre 文件、恢复旧会话、排空、拉配置。
    /// 一次性部分在旧会话恢复完成之前不驱逐（`engine.evictionAllowed`，盲审 🔴1）：当前会话的封段处理也排在恢复之后统一做。
    /// 恢复拿不到 root 目录锁（本次不恢复）→ 一次性部分不算完成，定时器重试（各步可重入）。
    private func startup() {
        persistDisabledMarker()
        guard ctl.with({ $0.bootstrapped }) else { return }
        _ = adoptOwnIfPending()
        guard !ctl.with({ $0.startedUp }) else {
            reschedule()
            return
        }
        engine.removePurgeLeftovers()
        engine.scanOutboxAtStartup()
        engine.adoptPreFilesAtStartup(redact: { [ctl] in ctl.with { $0.redact } })
        guard engine.recoverOldSessions() else {
            reschedule()
            return
        }
        ctl.with { $0.startedUp = true }
        engine.evictionAllowed = true
        if let prev = engine.previousAppVersion, prev != engine.device.appVersion {
            engine.releaseQuarantine(force: true)
        } else {
            engine.releaseQuarantine(force: false)
        }
        engine.flushTombstones()
        // 当前会话（含收编出的段）的封段处理：物化 + 驱逐，此时旧会话已在 others 里，驱逐它们的段会先记墓碑
        _ = processSeals()
        engine.evictIfNeeded()
        kickDrain()
        fetchConfig()
        reschedule()
    }

    /// 收编本进程的 pre 文件（引擎线程）。逐条读 → 经 writer 正常追加路径写进会话 → 追到文件尾后在 writer 锁内处理剩余记录、
    /// 切正常态、unlink（提交点）→ 清 meta.pre → 照常封段物化。返回 true = 已提交（或本来就没有）。
    private func adoptOwnIfPending() -> Bool {
        guard let pa = engine.pendingAdoption else { return true }
        guard let cur = engine.current else { return false }
        if pa.reader == nil {
            let fd = pa.file.dupForReading()
            guard fd >= 0 else { return false }
            pa.reader = PreReader(fd: fd)
        }
        guard let reader = pa.reader else { return false }
        // 每条记录现取钩子：收编途中 reconfigure 换了 redact 立即生效
        let redact: RedactProvider = { [ctl] in ctl.with { $0.redact } }
        RetrieverTestHooks.adoption("adopt_begin")
        var out = Writer.Outcome()
        var first = true
        while true {
            guard let recs = reader.readAvailable() else { return false }
            if recs.isEmpty { break }
            out.merge(engine.adopt(recs, into: writer, redact: redact, hookFirst: first))
            first = false
            if out.vanished || writer.hasVanished { break }
        }
        RetrieverTestHooks.adoption("adopt_before_commit")
        commit: while true {
            if out.vanished || writer.hasVanished {
                // 收编中会话目录 / root 消失：不提交；重新 bootstrap 后从偏移 0 把 pre 文件全部重放进新会话（不计数、不丢）
                rebootstrapAfterVanish()
                return false
            }
            switch writer.commitAdoption(reader) {
            case .committed(let o):
                out.merge(o)
                break commit
            case .again(let recs):
                out.merge(engine.adopt(recs, into: writer, redact: redact))
            case .vanished:
                out.vanished = true
            case .failed:
                return false
            }
        }
        reader.close()
        engine.pendingAdoption = nil
        RetrieverTestHooks.adoption("adopt_after_commit")
        engine.clearMetaPre(dir: cur.dir, meta: cur.meta)
        cur.meta.pre = nil
        if out.tombstone { engine.flushTombstones() }
        // 封段处理（物化 + 驱逐）：startup 还没走完一次性部分 → 留给它在恢复旧会话之后统一做（盲审 🔴1）；
        // 已走完（收编是之后重试成功的）→ 现在做
        if ctl.with({ $0.startedUp }) { afterSeal() }
        engine.reportDropped()
        return true
    }

    // MARK: 宿主 API

    public func log(_ level: LogLevel, _ msg: String, tag: String? = nil, attrs: [String: AttrValue]? = nil,
                    error: (any Error)? = nil) {
        if Reentrancy.active { return }
        Reentrancy.active = true
        defer { Reentrancy.active = false }
        guard writer.accepts(level) else { return }
        let line = LogLine(ts: clock.wallMs(), level: level, msg: msg, tag: tag, attrs: attrs,
                           exc: error.map(LineEncoder.exception))
        emit(line)
    }

    /// 共享入口在 configure 竞态里转交的行（已在重入保护内、exc 已取好）：照常过开关 / local_level / redact。
    func emitPrebuilt(_ line: LogLine) {
        guard writer.accepts(line.level) else { return }
        emit(line)
    }

    /// redact → 编码 → 落盘（调用方已在重入保护内）。
    private func emit(_ line0: LogLine) {
        var line = line0
        if !ctl.with({ $0.bootstrapped }) { retryBootstrap() }
        if let r = ctl.with({ $0.redact }) {
            guard var l = r(line) else { return }
            // redact 不能改 ts（ADR 0024 决定 10）：取回原值
            l.ts = line0.ts
            line = l
            guard writer.accepts(line.level) else { return }
        }
        let enc = LineEncoder.encode(line)
        handle(writer.append(level: line.level, ts: line.ts, body: enc.body))
    }

    /// 写入结果的后续：封段 / 计时 / 墓碑 / 会话目录消失，一律投递到后台、不等待。
    private func handle(_ out: Writer.Outcome) {
        if out.vanished { scheduleVanish() }
        if out.fatal {
            // fatal：行已在返回前交给内核（R-1）、段已换；封段与物化投递到后台、不等待（ADR 0020 决定 1）。
            // 进程随后死掉也不丢：下次启动的恢复从孤儿段物化出同一个确定性 batch_id。只落盘不尝试上传
            work.async(qos: .userInitiated, flags: .enforceQoS) { [self] in _ = processSeals() }
            return
        }
        if out.rotated {
            work.async { [self] in afterSeal() }
        } else if out.deadlineChanged {
            work.async { [self] in reschedule() }
        }
        if out.tombstone {
            let schedule = ctl.with { c -> Bool in
                if c.tombstoneScheduled { return false }
                c.tombstoneScheduled = true
                return true
            }
            if schedule {
                work.asyncAfter(deadline: .now() + 1) { [self] in
                    ctl.with { $0.tombstoneScheduled = false }
                    engine.flushTombstones()
                }
            }
        }
    }

    public func setUser(_ id: String?) {
        let r = writer.setUser(Text.sanitizeUserId(id))
        guard r.changed else { return }
        // 身份变了（与是否封段无关）：配置缓存按过期处理（放大型字段立即回落），并立即按新身份拉配置；
        // 有在途请求则在途结束后再拉一次（ADR 0019 决定 12）
        work.async { [self] in
            engine.expireConfigForNewIdentity()
            if r.rotated { afterSeal() } else { reschedule() }
        }
        fetchConfig()
    }

    /// 「上报问题」：向当前段追加合成行（error / tag rtv.flush / synthetic，一定是义务行），立即封段并排空。
    /// 该批 15 s 内被 2xx 确认 → `.stored`；否则 `.pending(offline | backoff | paused | disabled | timeout)`；
    /// `setEnabled(false)` 时（含等待中被禁用）`.pending("disabled")`。`includeContext == false` 时该批不带 ctx。
    /// 已有一个在等待中的 flush 且其标记行之后没有新写入的义务行：挂到同一个等待上，不追加标记行、不换段（ADR 0024 决定 8）。
    /// 兜底计时器先于一切等待排上（盲审 🟠5）：等收编、等封段都在计时器之后；窗口到了就回 `.pending("timeout")`。
    public func flush(includeContext: Bool = true) async -> FlushResult {
        guard writer.isEnabled else { return .pending("disabled") }
        let window = ctl.with { $0.flushWindowMs }
        return await withCheckedContinuation { (c: CheckedContinuation<FlushResult, Never>) in
            let once = FlushOnce(c)
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(window) * 1_000_000)
                once.resume(.pending("timeout"))
            }
            once.onResume = { timer.cancel() }
            Task.detached { [self] in
                once.resume(await flushBody(includeContext: includeContext, window: window, once: once))
            }
        }
    }

    private func flushBody(includeContext: Bool, window: Int64, once: FlushOnce) async -> FlushResult {
        // 收编中：标记行要进会话，先让引擎线程把收编跑完
        if writer.isAdopting { await onWork {} }
        guard let (g, mine) = joinOrStartFlush(includeContext: includeContext) else { return .pending("timeout") }
        guard mine else { return await g.wait() }
        await onWork { [self] in _ = processSeals() }
        let r = await flushWait(sessionId: g.sessionId, marker: g.marker, window: window, once: once)
        g.finish(r)
        return r
    }

    /// 合并判定 + 追加标记行（同步、flushLock 内）：已有等待中的 flush 且其标记行之后没有新的义务行（oseq 没动）→ 挂上去；
    /// 否则追加标记行、立即封段，开一个新的等待。返回 (等待, 是否自己开的)；标记行写不成 nil。
    private func joinOrStartFlush(includeContext: Bool) -> (FlushGroup, Bool)? {
        flushLock.lock()
        defer { flushLock.unlock() }
        if let g = ctl.with({ $0.flushGroup }), !g.isDone, writer.currentSessionId == g.sessionId, writer.snapshot.oseq == g.marker {
            return (g, false)
        }
        let ts = clock.wallMs()
        let enc = LineEncoder.encode(LogLine(ts: ts, level: .error, msg: "flush", tag: "rtv.flush"), synthetic: true)
        let sid = writer.currentSessionId
        guard let marker = writer.appendFlushMarker(ts: ts, body: enc.body, noCtx: !includeContext) else { return nil }
        let g = FlushGroup(sessionId: sid, marker: marker)
        ctl.with { $0.flushGroup = g }
        return (g, true)
    }

    private func flushWait(sessionId sid: String, marker: Int64, window: Int64, once: FlushOnce) async -> FlushResult {
        let deadline = clock.monoMs() + window
        while !once.done {
            if !writer.isEnabled { return .pending("disabled") }
            await drainNow()
            if await onWork({ [self] in engine.isAcked(sessionId: sid, oseq: marker) }) { return .stored }
            if !writer.isEnabled { return .pending("disabled") }
            let stop = ctl.with { $0.lastStop }
            let now = clock.monoMs()
            if now < deadline, ["spacing", "backoff", "offline"].contains(stop.reason), let w = stop.wake, w <= deadline,
               !ctl.with({ $0.stopRequested || $0.closed }) {
                await clock.sleep(ms: max(0, w - now))
                continue
            }
            return .pending(RetrieverClient.flushReason(stop.reason))
        }
        return .pending("timeout")
    }

    static let flushWindowMs: Int64 = 15_000

    /// 只 resume 一次（flush 的等待与超时兜底谁先到用谁）。
    final class FlushOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<FlushResult, Never>?
        var onResume: (@Sendable () -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onResume }
            set { lock.lock(); _onResume = newValue; lock.unlock() }
        }
        private var _onResume: (@Sendable () -> Void)?

        init(_ c: CheckedContinuation<FlushResult, Never>) { cont = c }

        var done: Bool {
            lock.lock(); defer { lock.unlock() }
            return cont == nil
        }

        func resume(_ r: FlushResult) {
            lock.lock()
            let c = cont
            cont = nil
            let hook = _onResume
            lock.unlock()
            guard let c else { return }
            hook?()
            c.resume(returning: r)
        }
    }

    /// 一个等待中的 flush 及挂在它上面的调用（同一结果回给各自的调用）。
    final class FlushGroup: @unchecked Sendable {
        let sessionId: String
        let marker: Int64
        private let lock = NSLock()
        private var result: FlushResult?
        private var waiters: [CheckedContinuation<FlushResult, Never>] = []

        init(sessionId: String, marker: Int64) {
            self.sessionId = sessionId
            self.marker = marker
        }

        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return result != nil
        }

        func wait() async -> FlushResult {
            await withCheckedContinuation { (c: CheckedContinuation<FlushResult, Never>) in
                lock.lock()
                if let r = result {
                    lock.unlock()
                    c.resume(returning: r)
                    return
                }
                waiters.append(c)
                lock.unlock()
            }
        }

        func finish(_ r: FlushResult) {
            lock.lock()
            result = r
            let w = waiters
            waiters = []
            lock.unlock()
            for c in w { c.resume(returning: r) }
        }
    }

    static func flushReason(_ stop: String) -> String {
        switch stop {
        case "offline": return "offline"
        case "backoff": return "backoff"
        case "disabled": return "disabled"
        case "paused", "upload_disabled", "not_configured", "locked": return "paused"
        default: return "timeout"
        }
    }

    /// 生效的上传 / 本地级别（远程配置钳制后；适配器早过滤用）。
    public var effectiveLevels: (upload: LogLevel, local: LogLevel) { writer.levels }

    /// 用户同意 / 撤回（ADR 0020 决定 2）：落盘为 root 同级的空标记文件 `<root>.disabled`，跨重启有效。
    /// - false：先改内存（写入立即停），再在后台写标记；此后上传与拉配置都停（在途的那一个请求不取消）。
    ///   标记写失败时内存照样禁用，每次调度 tick 重试。
    /// - true：先删标记（调用线程上一次 unlink），删除失败 → 保持禁用；成功后排空、拉配置。
    public func setEnabled(_ enabled: Bool) {
        enabledLock.lock()
        requestedEnabled = enabled
        markerUnknown = false
        if enabled {
            guard FS.unlinkIfPresent(engine.disabledMarkerURL) else {
                enabledLock.unlock()
                return
            }
            markerPending = false
            writer.setEnabled(true)
        } else {
            writer.setEnabled(false)
            markerPending = true
        }
        enabledLock.unlock()
        work.async { [self] in
            engine.enabled = writer.isEnabled
            if engine.enabled {
                kickDrain()
                fetchConfig()
            } else {
                persistDisabledMarker()
            }
            reschedule()
        }
    }

    /// 本进程的开关（内存；启动时 = 显式值 ?? 标记判定）。
    public var isEnabled: Bool { writer.isEnabled }

    /// work 队列：把禁用写成标记（空文件，tmp → fsync → rename）。写的过程不持锁，写完按内存开关再对齐一次：
    /// 其间宿主又 setEnabled(true) 的话，它的 unlink 可能早于这里的 rename。
    func persistDisabledMarker() {
        enabledLock.lock()
        let want = markerPending && !writer.isEnabled
        enabledLock.unlock()
        guard want else { return }
        let ok = FS.writeAtomic(engine.disabledMarkerURL, [])
        enabledLock.lock()
        if writer.isEnabled {
            _ = FS.unlinkIfPresent(engine.disabledMarkerURL)
        } else if ok {
            markerPending = false
        }
        enabledLock.unlock()
    }

    /// 没有显式值时按标记重判写入开关（每次 bootstrap 成功后；判定未知时每次调度唤醒，ADR 0024 决定 6）。work 队列。
    private func rejudgeEnabled() {
        enabledLock.lock()
        if requestedEnabled == nil {
            let st = FS.markerState(engine.disabledMarkerURL)
            markerUnknown = st == .unknown
            writer.setEnabled(st == .absent)
        }
        enabledLock.unlock()
        engine.enabled = writer.isEnabled
    }

    /// 清空本地：删 root 下全部内容并重建 install.json（新 install_id）与新会话（ADR 0019 决定 9 / ADR 0020 决定 1）。
    /// 调用线程只取消在途请求并置「清空中」（排空每次取批前检查并退出），删除与重建投递到后台、立即返回——
    /// 返回时清空尚未完成，`installId` 在完成回调里才是新值。`purgeLocal()` 返回到清空完成之间写的行会随旧状态一起删除。
    /// 禁用标记在 root 外面，不受影响；禁用时清空后不拉配置。不清用户（撤回同意的完整组合见 README）。
    public func purgeLocal() {
        purge(completion: nil)
    }

    /// 同 `purgeLocal()`；清空与重建完成后在后台线程回调。
    public func purgeLocal(completion: @escaping @Sendable () -> Void) {
        purge(completion: completion)
    }

    private func purge(completion: (@Sendable () -> Void)?) {
        ctl.with { c in
            c.purging += 1
            c.cancelEpoch += 1
        }
        transport.cancelAll()
        work.async { [self] in
            engine.releaseUploadLock()
            engine.releaseSessionLock()
            // 收编中的 pre 文件也是本地数据：一并删
            if let pa = engine.pendingAdoption {
                if let p = writer.abortAdoption() {
                    unlink(p.url.path)
                    p.close()
                }
                pa.reader?.close()
                engine.pendingAdoption = nil
            }
            // 先改名再删：一步原子，中途被杀也不会新旧状态混用。任何删除都发生在替代物（新 root、新 install、新会话）提交之后：
            // 改名到 bootstrap 之间宿主 log() 的行照常写进旧会话（占 seq、绝不返回空结果），随旧状态一起删除；
            // bootstrap 里的 startSession 把写入侧切到新 root（并关旧 fd）。
            let (moved, renamed) = FS.moveAside(root)
            if !renamed {
                // 改名失败（极少见，如 root 所在目录只读）：退回逐项删除——宁可失去原子性也要把本地数据清掉。
                // 没有替代物可先提交：写入侧先放下当前会话（此间 log() 计数），删完再 bootstrap
                writer.abandonSession()
                for name in FS.list(root) { FS.remove(root.appendingPathComponent(name)) }
            }
            engine.counter.reset()
            resetEngineState()
            let ok = engine.bootstrap()
            // 新 root 没建成：不再往旧会话写（同未 bootstrap 的状态：行计数，由 retryBootstrap 重试），旧状态照删
            if !ok { writer.abandonSession() }
            if let moved { FS.remove(moved) }
            ctl.with { c in
                c.bootstrapped = ok
                c.installId = engine.install?.installId
                c.sessionNo = engine.current?.meta.sessionNo ?? 0
                c.purging -= 1
            }
            if ok {
                afterBootstrap()
                if !ctl.with({ $0.startedUp }) { startup() }
            }
            fetchConfig()
            reschedule()
            if let completion { DispatchQueue.global(qos: .utility).async(execute: completion) }
        }
    }

    /// 放下全部引擎内存状态（purge、root 在运行中消失）。work 队列。
    private func resetEngineState() {
        engine.metas = [:]
        engine.embeddedDrops = []
        engine.embeddedClosed = []
        engine.pendingMapping = nil
        engine.mapping = nil
        engine.others = [:]
        engine.fails = [:]
        engine.inFlight = nil
        engine.backoff = BackoffState()
        engine.ackedRanges = []
        engine.backfilledSegs = []
        engine.configCache = nil
        engine.lastConfigFetchMono = nil
        engine.install = nil
        engine.current = nil
        engine.vanishDetected = false
    }

    public var installId: String? { ctl.with { $0.installId } }

    public var supportCode: String? {
        ctl.with { c in c.installId.map { String($0.prefix(8)) + "-" + String(c.sessionNo) } }
    }

    // MARK: 再次 configure（实例身份在首次 configure 定死，ADR 0023 决定 5）

    static let reconfigureIgnoredTag = "rtv.reconfigure_ignored"
    static let reconfigureIgnoredMsg = "identity field change ignored after first configure"

    /// 共享入口在宿主线程（共享锁内）调：processName / appGroup（即 root）与首次不同 → 忽略这两项、各留一条合成 warn
    /// `rtv.reconfigure_ignored`（attrs field = process_name | app_group）；其余参数照常生效。
    /// key、baseURL、宿主默认、sdkVersion 与上次都相同 → 只更新 redact，不拉配置、不做别的。
    func configureAgain(key: String, baseURL: URL, options: Options, root newRoot: URL) {
        var ignored: [String] = []
        if RetrieverClient.sanitizeProcessName(options.processName) != processName { ignored.append("process_name") }
        if newRoot.standardizedFileURL.path != root.standardizedFileURL.path { ignored.append("app_group") }
        for field in ignored {
            let now = clock.wallMs()
            let enc = LineEncoder.encode(LogLine(ts: now, level: .warn, msg: RetrieverClient.reconfigureIgnoredMsg,
                                                 tag: RetrieverClient.reconfigureIgnoredTag, attrs: ["field": .string(field)]),
                                         synthetic: true)
            handle(writer.append(level: .warn, ts: now, body: enc.body))
        }
        let p = Params(key: key, baseURL: baseURL.absoluteString, host: HostDefaults(options), sdkVersion: options.sdkVersion)
        let same = ctl.with { c -> Bool in
            c.redact = options.redact
            return c.params == p
        }
        guard !same else { return }
        reconfigure(key: key, baseURL: baseURL, options: options)
    }

    /// 改参数：redact 与宿主默认在调用线程上同步生效（写入侧锁内重算生效级别：返回后写的行立即按新级别判定，引擎被堵住也一样）；
    /// key / baseURL / 排空 / 拉配置在引擎线程。上传目标（key 指纹或 baseURL）变了：清鉴权暂停与退避、映射标为未确认、
    /// 配置缓存按身份过期并立即重拉（ADR 0024 决定 7）。
    func reconfigure(key: String, baseURL: URL, options: Options) {
        let host = HostDefaults(options)
        ctl.with { c in
            c.redact = options.redact
            c.params = Params(key: key, baseURL: baseURL.absoluteString, host: host, sdkVersion: options.sdkVersion)
        }
        writer.setHost(host)
        work.async { [self] in
            let changed = engine.setTarget(key: key, baseURL: baseURL)
            engine.sdkVersion = options.sdkVersion
            if changed { engine.resetForNewTarget() }
            engine.applyEffective()
            engine.lastConfigFetchMono = nil
            kickDrain()
            fetchConfig()
            reschedule()
        }
    }

    private func retryBootstrap() {
        let now = clock.monoMs()
        let go = ctl.with { c -> Bool in
            if c.bootstrapped || now < c.nextBootstrapMono { return false }
            c.nextBootstrapMono = now + 5000
            return true
        }
        guard go else { return }
        work.async { [self] in
            guard !ctl.with({ $0.bootstrapped }) else { return }
            let ok = engine.bootstrap()
            ctl.with { c in
                c.bootstrapped = ok
                c.installId = engine.install?.installId
                c.sessionNo = engine.current?.meta.sessionNo ?? 0
            }
            guard ok else { return }
            afterBootstrap()
            if ctl.with({ $0.startedUp }) {
                fetchConfig()
                reschedule()
            } else {
                startup()
            }
        }
    }

    /// bootstrap 成功之后（retryBootstrap / purge / 会话目录消失后重建）：重判开关、补写合成行。work 队列。
    private func afterBootstrap() {
        rejudgeEnabled()
        if ctl.with({ $0.vanishNotice }) {
            if engine.appendSynthetic(now: clock.wallMs(), tag: RetrieverClient.rootVanishedTag, msg: RetrieverClient.rootVanishedMsg) {
                ctl.with { $0.vanishNotice = false }
            }
        }
        engine.reportDropped()
    }

    // MARK: 会话目录 / root 在运行中消失（ADR 0024 决定 4）

    static let rootVanishedTag = "rtv.root_vanished"
    static let rootVanishedMsg = "session directory vanished; new session started"

    private func scheduleVanish() {
        let go = ctl.with { c -> Bool in
            if c.vanishScheduled || c.closed { return false }
            c.vanishScheduled = true
            return true
        }
        if go { work.async { [self] in rebootstrapAfterVanish() } }
    }

    /// work 队列：放下消失的会话（写进被删 inode 的段按行计数）→ root 也没了则放下全部内存状态（新 install）→ 重新 bootstrap →
    /// 写合成 warn `rtv.root_vanished` 与计数行。重建失败交给 retryBootstrap（期间的行计数）。
    private func rebootstrapAfterVanish() {
        ctl.with { $0.vanishScheduled = false }
        guard engine.vanishDetected || writer.hasVanished else { return }
        engine.vanishDetected = false
        let lost = writer.abandonVanished()
        if let pa = engine.pendingAdoption {
            // 收编未提交：消失的会话里只有收编出的行（收编中宿主的行都进 pre 文件），pre 文件在提交前完整 →
            // 从偏移 0 全部重放进新会话；随目录消失的那部分不计数（会在新会话里重现）
            pa.reader?.close()
            pa.reader = nil
            writer.resetUserForReplay()
        } else {
            for info in lost { engine.counter.add(segment: info) }
        }
        engine.releaseSessionLock()
        engine.releaseUploadLock()
        if !FS.exists(engine.installURL) { resetEngineState() }
        engine.current = nil
        let ok = engine.bootstrap()
        ctl.with { c in
            c.bootstrapped = ok
            c.installId = engine.install?.installId
            c.sessionNo = engine.current?.meta.sessionNo ?? 0
            c.vanishNotice = true
            if !ok { c.nextBootstrapMono = 0 }
        }
        if ok {
            afterBootstrap()
            if engine.pendingAdoption != nil {
                work.async { [self] in
                    if ctl.with({ $0.bootstrapped }) { _ = adoptOwnIfPending() }
                }
            }
        }
        fetchConfig()
        reschedule()
    }

    // MARK: 生命周期（§3.9）

    public func platformEvent(_ event: PlatformEvent) {
        switch event {
        case .didEnterBackground:
            enterBackground()
        case .willEnterForeground:
            ctl.with { $0.stopRequested = false }
            work.async { [self] in
                engine.setLastState("fg")
                engine.applyEffective()
                if engine.effective.expired || engine.configPollDue(nowMono: clock.monoMs()) { fetchConfig() }
                kickDrain()
                reschedule()
            }
        case .foregroundStateChanged(let fg):
            work.async { [self] in engine.setLastState(fg ? "fg" : "bg") }
        case .protectedDataWillBecomeUnavailable:
            // 只记标志；此后写失败走 write_failed 墓碑
            writer.setProtectedDataUnavailable(true)
        case .protectedDataDidBecomeAvailable:
            writer.setProtectedDataUnavailable(false)
            work.async { [self] in engine.flushTombstones() }
            retryBootstrap()
        case .networkRestored:
            // 只用于提前唤醒（不做可达性预检）：清掉退避等待，暂停（401 / 429）不动
            work.async { [self] in
                engine.backoff.nextAtMonoMs = 0
                engine.backoff.nextAtWallMs = 0
                kickDrain()
            }
        }
    }

    /// 进后台：封段（段内有义务行）+ 排空包在 beginBackgroundTask 里；过期回调取消在途请求并 endBackgroundTask。
    private func enterBackground() {
        let token = platform.beginBackgroundTask(name: "retriever.drain") { [weak self] in
            self?.backgroundExpired()
        }
        let previous = ctl.with { c -> Int? in
            let p = c.bgToken
            c.bgToken = token
            c.stopRequested = false
            return p
        }
        if let p = previous { platform.endBackgroundTask(p) }
        writer.rotate(.background, onlyIfObligation: true)
        work.async { [self] in
            engine.setLastState("bg")
            _ = processSeals()
        }
        Task.detached { [self] in
            // 后台时间有限（系统不给秒数）：尽力排空，过期回调会先取消在途请求并 end
            await drainPatiently(budgetMs: 25_000)
            await onWork { [self] in engine.releaseUploadLock() }
            endBackgroundTask(token)
        }
    }

    private func backgroundExpired() {
        let token = ctl.with { c -> Int? in
            c.stopRequested = true
            c.cancelEpoch += 1
            return c.bgToken
        }
        transport.cancelAll()
        work.async { [self] in engine.releaseUploadLock() }
        endBackgroundTask(token)
    }

    /// 每个令牌只 end 一次。
    private func endBackgroundTask(_ token: Int?) {
        guard let t = token else { return }
        let mine = ctl.with { c -> Bool in
            if c.bgToken == t { c.bgToken = nil; return true }
            return false
        }
        if mine { platform.endBackgroundTask(t) }
    }

    // MARK: 排空

    /// work 队列：处理封段；发现会话目录已消失则重新 bootstrap。
    @discardableResult
    func processSeals() -> Bool {
        let produced = engine.processSeals()
        if engine.vanishDetected || writer.hasVanished { rebootstrapAfterVanish() }
        return produced
    }

    func afterSeal() {
        if processSeals() { kickDrain() }
        reschedule()
    }

    func kickDrain() {
        let start = ctl.with { c -> Bool in
            if c.closed { return false }
            if c.draining { c.rekick = true; return false }
            c.draining = true
            return true
        }
        if start { Task.detached { [self] in await drainLoop() } }
    }

    /// 触发一次排空并等它结束（已在排空则等下一轮结束）。
    func drainNow() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            enum Action { case closed, start, wait }
            let action = ctl.with { s -> Action in
                if s.closed { return .closed }
                s.drainWaiters.append(c)
                if s.draining { s.rekick = true; return .wait }
                s.draining = true
                return .start
            }
            switch action {
            case .closed: c.resume()
            case .start: Task.detached { [self] in await drainLoop() }
            case .wait: break
            }
        }
    }

    /// 排空直到出站箱无可发的批、或被暂停 / 退避 / 过期挡住；相邻请求间隔（2 s）就地等待，最长 budgetMs。
    func drainPatiently(budgetMs: Int64) async {
        let deadline = clock.monoMs() + budgetMs
        while true {
            await drainNow()
            let stop = ctl.with { $0.lastStop }
            guard stop.reason == "spacing", let w = stop.wake, w <= deadline,
                  !ctl.with({ $0.stopRequested || $0.closed }) else { return }
            await clock.sleep(ms: max(0, w - clock.monoMs()))
        }
    }

    private func drainLoop() async {
        while true {
            loop: while true {
                if ctl.with({ $0.stopRequested }) {
                    ctl.with { $0.lastStop = ("background_expired", nil) }
                    break loop
                }
                let step = await onWork { [self] () -> Engine.SendStep in
                    // 清空中：排在前面的排空不再取批（在 work 队列上判断，与清空本身串行）
                    if ctl.with({ $0.purging > 0 }) { return .stop(reason: "purging", wakeMono: nil) }
                    return engine.nextSend()
                }
                switch step {
                case .stop(let reason, let wake):
                    ctl.with { $0.lastStop = (reason, wake) }
                    break loop
                case .send(let name, let req, let fp, let base):
                    if ctl.with({ $0.purging > 0 }) {
                        // 取批之后、发出之前清空开始了：这一批要随 root 一起清掉，不发
                        await onWork { [self] in if engine.inFlight == name { engine.inFlight = nil } }
                        ctl.with { $0.lastStop = ("purging", nil) }
                        break loop
                    }
                    let epoch = ctl.with { $0.cancelEpoch }
                    let resp = await transport.send(req)
                    // SDK 自己取消的（purge、后台到期）不计毒批失败（ADR 0024 决定 10）
                    let cancelled = resp == nil && ctl.with { $0.cancelEpoch } != epoch
                    let eff = await onWork { [self] in
                        engine.handleResponse(name: name, response: resp, keyFp: fp, baseURL: base, sdkCancelled: cancelled)
                    }
                    // 配置诊断在 work 队列与任何 SDK 锁之外出（ADR 0025）
                    if let d = eff.keyRejected { ConfigDiagnostics.emit(d, keyFp: fp, baseURL: base) }
                    if eff.fetchConfig { fetchConfig() }
                }
            }
            await onWork { [self] in
                engine.releaseUploadLock()
                reschedule()
            }
            let (again, waiters) = ctl.with { c -> (Bool, [CheckedContinuation<Void, Never>]) in
                if c.rekick && !c.stopRequested && c.purging == 0 {
                    c.rekick = false
                    return (true, [])
                }
                c.rekick = false
                c.draining = false
                let w = c.drainWaiters
                c.drainWaiters = []
                return (false, w)
            }
            if !again {
                for w in waiters { w.resume() }
                return
            }
        }
    }

    // MARK: 配置

    /// 拉配置：同一时刻最多一个在途；在途时再来的请求置「待重拉」，在途结束后再拉一次（身份变化不被在途请求吞掉）。
    /// 响应属于旧身份（install / user / 宿主默认 / key 指纹 / baseURL 任一变了，已丢弃）时同样重拉。
    func fetchConfig() {
        let go = ctl.with { c -> Bool in
            if c.closed || c.purging > 0 { return false }
            if c.configFetching {
                c.configRefetch = true
                return false
            }
            c.configFetching = true
            return true
        }
        guard go else { return }
        Task.detached { [self] in
            while true {
                var stale = false
                if let (req, identity) = await onWork({ [self] in engine.configRequest() }) {
                    let resp = await transport.send(req)
                    let eff = await onWork { [self] in engine.applyConfigResponse(resp, requestedFor: identity) }
                    if eff.sealed { kickDrain() }
                    stale = eff.stale
                } else {
                    await onWork { [self] in engine.lastConfigFetchMono = clock.monoMs() }
                }
                let again = ctl.with { c -> Bool in
                    let more = (stale || c.configRefetch) && !c.closed && c.purging == 0
                    c.configRefetch = false
                    if !more { c.configFetching = false }
                    return more
                }
                if !again { break }
            }
            await onWork { [self] in reschedule() }
        }
    }

    // MARK: 调度（离线 / 退避时真正睡眠，不空转）

    func reschedule() {
        let nowMono = clock.monoMs()
        let nowWall = clock.wallMs()
        var cands: [Int64] = []
        if let d = writer.nextDeadline { cands.append(d) }
        if let u = engine.uploadWakeMono() { cands.append(u) }
        if !engine.key.isEmpty && engine.enabled {
            cands.append((engine.lastConfigFetchMono ?? nowMono) + Int64(Limits.configPollIntervalS) * 1000)
        }
        enabledLock.lock()
        if markerPending || markerUnknown { cands.append(nowMono + ClientConstants.markerRetryMs) }
        enabledLock.unlock()
        let (boot, started) = ctl.with { ($0.bootstrapped, $0.startedUp) }
        // 没有会话 / 收编没提交：定时重试（不依赖宿主再写一行）
        if !boot || engine.pendingAdoption != nil || !started { cands.append(nowMono + ClientConstants.adoptionRetryMs) }
        if let c = engine.configCache?.nextChangeMono(nowWall: nowWall, nowMono: nowMono) { cands.append(c) }
        if let q = engine.nextQuarantineReleaseMono() { cands.append(q) }
        let next = cands.min()
        ctl.with { c in
            if c.closed { return }
            if c.timerTarget == next && c.timerTask != nil { return }
            c.timerTask?.cancel()
            c.timerTask = nil
            c.timerTarget = next
            guard let next else { return }
            let clock = self.clock
            c.timerTask = Task.detached { [weak self] in
                do { try await clock.timerSleep(ms: RetrieverClient.timerDelayMs(next: next, now: nowMono)) } catch { return }
                guard let self else { return }
                self.work.async { self.tick() }
            }
        }
    }

    /// 定时器睡多久：候选已到期（≤ now）也至少等 schedulerMinDelayMs，任何候选都造不成 0 ms 自旋。
    static func timerDelayMs(next: Int64, now: Int64) -> Int64 {
        max(next - now, ClientConstants.schedulerMinDelayMs)
    }

    func tick() {
        ctl.with { c in
            c.timerTask?.cancel()
            c.timerTask = nil
            c.timerTarget = nil
        }
        persistDisabledMarker()
        enabledLock.lock()
        let unknown = markerUnknown
        enabledLock.unlock()
        if unknown { rejudgeEnabled() }
        if engine.vanishDetected || writer.hasVanished { rebootstrapAfterVanish() }
        if !ctl.with({ $0.bootstrapped }) {
            retryBootstrap()
        } else if !ctl.with({ $0.startedUp }) {
            startup()
        } else if engine.pendingAdoption != nil {
            _ = adoptOwnIfPending()
        }
        if writer.checkDeadlines() { _ = processSeals() }
        engine.applyEffective()
        engine.releaseQuarantine(force: false)
        engine.reportDropped()
        if engine.configPollDue(nowMono: clock.monoMs()) { fetchConfig() }
        kickDrain()
        reschedule()
    }

    // MARK: 队列工具

    func onWork<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in work.async { c.resume(returning: body()) } }
    }

    private func onWorkSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: workKey) == true { body() } else { work.sync(execute: body) }
    }

    // MARK: 测试 / 诊断（SPI）

    /// 等后台工作（work 队列、排空、配置拉取）全部落定。
    public func settle() async {
        for _ in 0..<200 {
            await onWork {}
            let busy = ctl.with { $0.draining || $0.configFetching }
            if !busy {
                await onWork {}
                if !ctl.with({ $0.draining || $0.configFetching }) { return }
            }
            if ctl.with({ $0.draining }) { await drainNow() } else { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
    }

    /// 测试：推进假时钟后手动触发一次定时器。
    public func tickNow() async {
        await onWork { [self] in tick() }
        await settle()
    }

    /// 测试：模拟进程死亡（不封段、不收尾；关 fd、放会话目录锁与 pre 文件锁、停调度）。同 root 的新实例会把它当孤儿恢复。
    public func simulateCrash() {
        ctl.with { c in
            c.closed = true
            c.timerTask?.cancel()
            c.timerTask = nil
        }
        onWorkSync { [self] in
            writer.abandonSession()
            writer.abortAdoption()?.close()
            engine.pendingAdoption?.reader?.close()
            engine.releaseUploadLock()
            engine.releaseSessionLock()
        }
    }

    public func setFlushWindowForTesting(_ ms: Int64) { ctl.with { $0.flushWindowMs = ms } }

    /// 最近一轮排空停下的原因（`nextSend` 的 stop reason）。
    public var debugLastStopReason: String { ctl.with { $0.lastStop.reason } }

    public var debugCounters: (seq: Int64, oseq: Int64) {
        let s = writer.snapshot
        return (s.seq, s.oseq)
    }

    public var debugOpenSegmentPath: String? { writer.currentSegmentURL?.path }
}

import Foundation

/// 实例（静态 API 转发到进程内共享实例；测试直接建实例：临时目录 + 假 transport + 假时钟）。
///
/// 并发模型：
/// - 热路径 `log()` 只碰 `Writer`（NSLock，锁内一次 write(2)），不排队、不等待任何后台工作；
/// - 其余一切磁盘状态（封段、物化、出站箱、驱逐、恢复、配置、队列决策）在串行 `work` 队列上；
/// - 网络请求在队列外（async），发送前后各回队列一次做决策与落盘。
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

    /// 锁保护的调度 / 排空 / 后台任务状态。
    final class Control: @unchecked Sendable {
        let lock = NSLock()
        var redact: (@Sendable (LogLine) -> LogLine?)?
        var installId: String?
        var sessionNo: Int64 = 0
        var bootstrapped = false
        var nextBootstrapMono: Int64 = 0
        var draining = false
        var rekick = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        var lastStop: (reason: String, wake: Int64?) = ("", nil)
        var stopRequested = false
        var timerTask: Task<Void, Never>?
        var timerTarget: Int64?
        var configFetching = false
        var bgToken: Int?
        var tombstoneScheduled = false
        var closed = false

        func with<T>(_ body: (Control) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    @_spi(RetrieverTesting)
    public init(root: URL, key: String, baseURL: URL, options: Options, clock: any Clock,
                transport: any Transport, platform: any PlatformHooks) {
        self.root = root
        self.processName = RetrieverClient.sanitizeProcessName(options.processName)
        self.clock = clock
        self.transport = transport
        self.platform = platform
        self.writer = Writer(clock: clock)
        self.engine = Engine(root: root, processName: processName, key: key, baseURL: baseURL, options: options,
                             clock: clock, platform: platform, writer: writer)
        work.setSpecific(key: workKey, value: true)
        ctl.redact = options.redact
        // 同步建会话：init 返回后 log() 立即落盘
        let ok = engine.bootstrap()
        ctl.with { c in
            c.bootstrapped = ok
            c.installId = engine.install?.installId
            c.sessionNo = engine.current?.meta.sessionNo ?? 0
        }
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

    private func startup() {
        guard ctl.with({ $0.bootstrapped }) else { return }
        engine.scanOutboxAtStartup()
        engine.recoverOldSessions()
        if let prev = engine.previousAppVersion, prev != engine.device.appVersion {
            engine.releaseQuarantine(force: true)
        } else {
            engine.releaseQuarantine(force: false)
        }
        engine.flushTombstones()
        engine.evictIfNeeded()
        kickDrain()
        fetchConfig()
        reschedule()
    }

    // MARK: 宿主 API

    public func log(_ level: LogLevel, _ msg: String, tag: String? = nil, attrs: [String: AttrValue]? = nil,
                    error: (any Error)? = nil) {
        if Reentrancy.active { return }
        Reentrancy.active = true
        defer { Reentrancy.active = false }
        guard writer.accepts(level) else { return }
        if !ctl.with({ $0.bootstrapped }) { retryBootstrap() }
        var line = LogLine(ts: clock.wallMs(), level: level, msg: msg, tag: tag, attrs: attrs,
                           exc: error.map(LineEncoder.exception))
        if let r = ctl.with({ $0.redact }) {
            guard let l = r(line) else { return }
            line = l
            guard writer.accepts(line.level) else { return }
        }
        let enc = LineEncoder.encode(line)
        let out = writer.append(level: line.level, body: enc.body)
        if out.fatal {
            // fatal：立即封段并物化，只落盘不尝试上传
            onWorkSync { _ = self.engine.processSeals() }
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
        if writer.setUser(Text.sanitizeUserId(id)) {
            work.async { [self] in afterSeal() }
        }
    }

    /// 「上报问题」：视同一次 error 触发（带 ctx）并尽力排空；primary 批都已确认 → stored，否则 pending(原因)。
    public func flush(includeContext: Bool = true) async -> FlushResult {
        guard writer.isEnabled else { return .pending("disabled") }
        writer.rotate(.flush, forceCtx: includeContext)
        await onWork { [self] in _ = engine.processSeals() }
        await drainPatiently(budgetMs: 60_000)
        let pending = await onWork { [self] in engine.hasPendingPrimary }
        if !pending { return .stored }
        let stop = ctl.with { $0.lastStop }
        return .pending(stop.reason.isEmpty ? "pending" : stop.reason)
    }

    public func setEnabled(_ enabled: Bool) {
        writer.setEnabled(enabled)
        work.async { [self] in
            engine.enabled = enabled
            if enabled { kickDrain() }
        }
    }

    /// 删 root 下全部内容并重建 install.json（新 install_id）与新会话。
    public func purgeLocal() {
        transport.cancelAll()
        onWorkSync { [self] in
            writer.abandonSession()
            engine.releaseUploadLock()
            engine.releaseSessionLock()
            for name in FS.list(root) { FS.remove(root.appendingPathComponent(name)) }
            engine.metas = [:]
            engine.embeddedDrops = []
            engine.embeddedClosed = []
            engine.pendingMapping = nil
            engine.mapping = nil
            engine.others = [:]
            engine.fails = [:]
            engine.inFlight = nil
            engine.backoff = BackoffState()
            engine.configCache = nil
            engine.lastConfigFetchMono = nil
            engine.install = nil
            engine.current = nil
            let ok = engine.bootstrap()
            ctl.with { c in
                c.bootstrapped = ok
                c.installId = engine.install?.installId
                c.sessionNo = engine.current?.meta.sessionNo ?? 0
            }
        }
        fetchConfig()
    }

    public var installId: String? { ctl.with { $0.installId } }

    public var supportCode: String? {
        ctl.with { c in c.installId.map { String($0.prefix(8)) + "-" + String(c.sessionNo) } }
    }

    // MARK: 配置变更（configure 在懒初始化之后）

    func reconfigure(key: String, baseURL: URL, options: Options) {
        ctl.with { $0.redact = options.redact }
        work.async { [self] in
            engine.key = key
            engine.baseURL = baseURL
            engine.host = HostDefaults(options)
            engine.sdkVersion = options.sdkVersion
            engine.applyEffective()
            engine.lastConfigFetchMono = nil
            kickDrain()
            fetchConfig()
            reschedule()
        }
    }

    /// 旧实例收尾（root / 进程名变化时由共享实例替换）。
    func shutdown() {
        writer.rotate(.shutdown)
        onWorkSync { [self] in
            _ = engine.processSeals()
            engine.releaseUploadLock()
        }
        writer.abandonSession()
        ctl.with { c in
            c.closed = true
            c.timerTask?.cancel()
            c.timerTask = nil
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
            if ok { startup() }
        }
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
            _ = engine.processSeals()
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

    func afterSeal() {
        if engine.processSeals() { kickDrain() }
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
                let step = await onWork { [self] in engine.nextSend() }
                switch step {
                case .stop(let reason, let wake):
                    ctl.with { $0.lastStop = (reason, wake) }
                    break loop
                case .send(let name, let req):
                    let resp = await transport.send(req)
                    let eff = await onWork { [self] in engine.handleResponse(name: name, response: resp) }
                    if eff.fetchConfig { fetchConfig() }
                }
            }
            await onWork { [self] in
                engine.releaseUploadLock()
                reschedule()
            }
            let (again, waiters) = ctl.with { c -> (Bool, [CheckedContinuation<Void, Never>]) in
                if c.rekick && !c.stopRequested {
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

    func fetchConfig() {
        let go = ctl.with { c -> Bool in
            if c.configFetching || c.closed { return false }
            c.configFetching = true
            return true
        }
        guard go else { return }
        Task.detached { [self] in
            if let req = await onWork({ [self] in engine.configRequest() }) {
                let resp = await transport.send(req)
                let eff = await onWork { [self] in engine.applyConfigResponse(resp) }
                if eff.sealed { kickDrain() }
            } else {
                await onWork { [self] in engine.lastConfigFetchMono = clock.monoMs() }
            }
            ctl.with { $0.configFetching = false }
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
        if !engine.key.isEmpty {
            cands.append((engine.lastConfigFetchMono ?? nowMono) + Int64(Limits.configPollIntervalS) * 1000)
        }
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
                do { try await clock.timerSleep(ms: max(0, next - nowMono)) } catch { return }
                guard let self else { return }
                self.work.async { self.tick() }
            }
        }
    }

    func tick() {
        ctl.with { c in
            c.timerTask?.cancel()
            c.timerTask = nil
            c.timerTarget = nil
        }
        if writer.checkDeadlines() { _ = engine.processSeals() }
        engine.applyEffective()
        engine.releaseQuarantine(force: false)
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

    /// 测试：模拟进程死亡（不封段、不收尾；关 fd、放会话目录锁、停调度）。同 root 的新实例会把它当孤儿恢复。
    public func simulateCrash() {
        ctl.with { c in
            c.closed = true
            c.timerTask?.cancel()
            c.timerTask = nil
        }
        onWorkSync { [self] in
            writer.abandonSession()
            engine.releaseUploadLock()
            engine.releaseSessionLock()
        }
    }

    public var debugCounters: (seq: Int64, oseq: Int64) {
        let s = writer.snapshot
        return (s.seq, s.oseq)
    }

    public var debugOpenSegmentPath: String? { writer.currentSegmentURL?.path }
}

import Foundation

/// 实例（静态 API 转发到进程内共享实例；测试直接建实例：临时目录 + 假 transport + 假时钟）。
///
/// 并发模型：
/// - 热路径 `log()` 只碰 `Writer`（NSLock，锁内一次 write(2)），不排队、不等待任何后台工作；
/// - 其余一切磁盘状态（封段、物化、出站箱、驱逐、恢复、配置、队列决策）在串行 `work` 队列上；
/// - 网络请求在队列外（async），发送前后各回队列一次做决策与落盘；
/// - 宿主线程永不等待 `work` 队列（ADR 0020 决定 1）：fatal、purgeLocal、换 root 的收尾一律投递后立即返回。
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
    /// 宿主在本实例上最后一次显式 setEnabled 的值（nil = 没调过）；换 root 时带给新实例。受 enabledLock 保护。
    private var requestedEnabled: Bool?

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
        /// 拉配置在途时又有新请求（身份变了等）：在途结束后再拉一次。
        var configRefetch = false
        /// 进行中的 purgeLocal 个数：> 0 时排空每次取批前退出、不拉配置。
        var purging = 0
        var bgToken: Int?
        var tombstoneScheduled = false
        var closed = false
        /// flush 等待窗口（测试可调小）。
        var flushWindowMs: Int64 = RetrieverClient.flushWindowMs

        func with<T>(_ body: (Control) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    @_spi(RetrieverTesting)
    public convenience init(root: URL, key: String, baseURL: URL, options: Options, clock: any Clock,
                            transport: any Transport, platform: any PlatformHooks) {
        self.init(root: root, key: key, baseURL: baseURL, options: options, clock: clock, transport: transport,
                  platform: platform, enabled: nil)
    }

    /// `enabled`：换 root 时从旧实例带过来的宿主显式 setEnabled（configure 之前的调用），作为初值并落盘到新 root 旁
    /// （ADR 0020 决定 2）；nil = 按盘上标记。
    init(root: URL, key: String, baseURL: URL, options: Options, clock: any Clock,
         transport: any Transport, platform: any PlatformHooks, enabled: Bool?) {
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
        // 开关在同步 bootstrap 之前初始化（写入只看这个内存开关；startup 的排空 / 拉配置不会抢在禁用生效之前）：
        // 默认从盘上标记；带过来的显式值照 setEnabled 的规则落盘（true 删标记、删不掉保持禁用；false 稍后写标记）
        var on = !FS.exists(engine.disabledMarkerURL)
        if let e = enabled {
            on = e && FS.unlinkIfPresent(engine.disabledMarkerURL)
            markerPending = !e
        }
        requestedEnabled = enabled
        writer.setEnabled(on)
        engine.enabled = on
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
        persistDisabledMarker()
        guard ctl.with({ $0.bootstrapped }) else { return }
        engine.removePurgeLeftovers()
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
            // fatal：行已在返回前交给内核（R-1）、段已换；封段与物化投递到后台、不等待（ADR 0020 决定 1）。
            // 进程随后死掉也不丢：下次启动的恢复从孤儿段物化出同一个确定性 batch_id。只落盘不尝试上传
            work.async(qos: .userInitiated, flags: .enforceQoS) { [self] in _ = engine.processSeals() }
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
    /// 该批 15 s 内被 2xx 确认 → `.stored`；否则 `.pending(offline | backoff | paused | timeout)`；
    /// `setEnabled(false)` 时 `.pending("disabled")`。`includeContext == false` 时该批不带 ctx。
    public func flush(includeContext: Bool = true) async -> FlushResult {
        guard writer.isEnabled else { return .pending("disabled") }
        let enc = LineEncoder.encode(LogLine(ts: clock.wallMs(), level: .error, msg: "flush", tag: "rtv.flush"), synthetic: true)
        let sid = writer.currentSessionId
        guard let marker = writer.appendFlushMarker(body: enc.body, noCtx: !includeContext) else {
            return .pending("timeout")
        }
        await onWork { [self] in _ = engine.processSeals() }
        // 窗口用注入时钟计（退避 / 间隔等待）；另用真实时间兜住在途请求挂起的情况
        let window = ctl.with { $0.flushWindowMs }
        return await withCheckedContinuation { (c: CheckedContinuation<FlushResult, Never>) in
            let once = FlushOnce(c)
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(window) * 1_000_000)
                once.resume(.pending("timeout"))
            }
            once.onResume = { timer.cancel() }
            Task.detached { [self] in
                once.resume(await flushWait(sessionId: sid, marker: marker, window: window, once: once))
            }
        }
    }

    private func flushWait(sessionId sid: String, marker: Int64, window: Int64, once: FlushOnce) async -> FlushResult {
        let deadline = clock.monoMs() + window
        while !once.done {
            await drainNow()
            if await onWork({ [self] in engine.isAcked(sessionId: sid, oseq: marker) }) { return .stored }
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

    static func flushReason(_ stop: String) -> String {
        switch stop {
        case "offline": return "offline"
        case "backoff": return "backoff"
        case "paused", "upload_disabled", "not_configured", "locked", "disabled": return "paused"
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

    /// 本进程的开关（内存；启动时从盘上标记初始化）。
    public var isEnabled: Bool { writer.isEnabled }

    /// 宿主在本实例上最后一次显式 setEnabled 的值（nil = 没调过）；共享实例换 root 时带给新实例。
    var explicitEnabled: Bool? {
        enabledLock.lock()
        defer { enabledLock.unlock() }
        return requestedEnabled
    }

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

    /// 清空本地：删 root 下全部内容并重建 install.json（新 install_id）与新会话（ADR 0019 决定 9 / ADR 0020 决定 1）。
    /// 调用线程只取消在途请求并置「清空中」（排空每次取批前检查并退出），删除与重建投递到后台、立即返回——
    /// 返回时清空尚未完成，`installId` 在完成回调里才是新值。`purgeLocal()` 返回到清空完成之间写的行会随旧状态一起删除。
    /// 禁用标记在 root 外面，不受影响；禁用时清空后不拉配置。
    public func purgeLocal() {
        purge(completion: nil)
    }

    /// 同 `purgeLocal()`；清空与重建完成后在后台线程回调。
    public func purgeLocal(completion: @escaping @Sendable () -> Void) {
        purge(completion: completion)
    }

    private func purge(completion: (@Sendable () -> Void)?) {
        ctl.with { $0.purging += 1 }
        transport.cancelAll()
        work.async { [self] in
            engine.releaseUploadLock()
            engine.releaseSessionLock()
            // 先改名再删：一步原子，中途被杀也不会新旧状态混用。任何删除都发生在替代物（新 root、新 install、新会话）提交之后：
            // 改名到 bootstrap 之间宿主 log() 的行照常写进旧会话（占 seq、绝不返回空结果），随旧状态一起删除；
            // bootstrap 里的 startSession 把写入侧切到新 root（并关旧 fd）。
            let moved = engine.moveRootAside()
            if moved == nil {
                // 改名失败（极少见，如 root 所在目录只读）：退回逐项删除——宁可失去原子性也要把本地数据清掉。
                // 没有替代物可先提交：写入侧先放下当前会话（此间 log() 不落盘），删完再 bootstrap
                writer.abandonSession()
                for name in FS.list(root) { FS.remove(root.appendingPathComponent(name)) }
            }
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
            let ok = engine.bootstrap()
            // 新 root 没建成：不再往旧会话写（同未 bootstrap 的状态，由 retryBootstrap 重试），旧状态照删
            if !ok { writer.abandonSession() }
            if let moved { FS.remove(moved) }
            ctl.with { c in
                c.bootstrapped = ok
                c.installId = engine.install?.installId
                c.sessionNo = engine.current?.meta.sessionNo ?? 0
                c.purging -= 1
            }
            fetchConfig()
            reschedule()
            if let completion { DispatchQueue.global(qos: .utility).async(execute: completion) }
        }
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

    /// 旧实例收尾（root / 进程名变化时由共享实例替换）：换段后把封段、放上传锁、关写句柄投递到后台，不等待（ADR 0020 决定 1）。
    /// 收尾之前被杀也不丢：旧 root 里的会话由下次打开该 root 的实例当孤儿恢复。
    func shutdown() {
        writer.rotate(.shutdown)
        ctl.with { c in
            c.closed = true
            c.timerTask?.cancel()
            c.timerTask = nil
        }
        work.async { [self] in
            _ = engine.processSeals()
            engine.releaseUploadLock()
            writer.abandonSession()
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
                let step = await onWork { [self] () -> Engine.SendStep in
                    // 清空中：排在前面的排空不再取批（在 work 队列上判断，与清空本身串行）
                    if ctl.with({ $0.purging > 0 }) { return .stop(reason: "purging", wakeMono: nil) }
                    return engine.nextSend()
                }
                switch step {
                case .stop(let reason, let wake):
                    ctl.with { $0.lastStop = (reason, wake) }
                    break loop
                case .send(let name, let req):
                    if ctl.with({ $0.purging > 0 }) {
                        // 取批之后、发出之前清空开始了：这一批要随 root 一起清掉，不发
                        await onWork { [self] in if engine.inFlight == name { engine.inFlight = nil } }
                        ctl.with { $0.lastStop = ("purging", nil) }
                        break loop
                    }
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
    /// 响应属于旧身份（已丢弃）时同样重拉。
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
        if markerPending { cands.append(nowMono + ClientConstants.markerRetryMs) }
        enabledLock.unlock()
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

    public func setFlushWindowForTesting(_ ms: Int64) { ctl.with { $0.flushWindowMs = ms } }

    /// 最近一轮排空停下的原因（`nextSend` 的 stop reason）。
    public var debugLastStopReason: String { ctl.with { $0.lastStop.reason } }

    public var debugCounters: (seq: Int64, oseq: Int64) {
        let s = writer.snapshot
        return (s.seq, s.oseq)
    }

    public var debugOpenSegmentPath: String? { writer.currentSegmentURL?.path }
}

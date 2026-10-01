import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 重入保护（§3.3-6）：线程局部标志。redact 钩子内、SDK 内部路径上的 log() 直接忽略。
enum Reentrancy {
    static let key: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()

    static var active: Bool {
        get { pthread_getspecific(key) != nil }
        set { pthread_setspecific(key, newValue ? UnsafeRawPointer(bitPattern: 1) : nil) }
    }
}

/// 写入侧（宪法 R-1，方案 §3.3 / §3.4）：常开 fd（O_WRONLY|O_APPEND|O_CREAT），锁内只做
/// 「seq++（义务行 oseq++）+ 拼前缀 + 一次 write(2)」。逐行不 fsync；写失败 ftruncate 回上一完整行、
/// 该行照常占 seq / oseq 并记内存墓碑 write_failed；绝不抛给宿主。
///
/// 0.3.0（ADR 0022 / 0023 / 0024）：
/// - 宿主默认与配置缓存快照**只存这一份**（引擎读它）：`setHost` 在宿主线程同步重算生效级别，`setConfigCache` 由引擎推送；
/// - **收编中**（configure 时本进程有 pre 文件）：宿主的行照常过 redact / local_level 过滤后追加到 pre 文件（`r` = 1），
///   引擎线程经 `adoptAppend` 把 pre 记录按序写进会话，`commitAdoption` 在锁内收尾并切回正常态；
/// - 没有会话（bootstrap 失败、会话目录消失）时的行计数（`DropCounter`），不再静默返回；
/// - fatal 节流：距上次 fatal 强制换段不足 10 s 的 fatal 不换段、并入 error 去抖。
final class Writer: @unchecked Sendable {
    struct Outcome {
        var written = false
        var rotated = false
        var fatal = false
        var deadlineChanged = false
        var tombstone = false
        /// 换段时发现会话目录已不在（open 得 ENOENT）：调用方投递重新 bootstrap。
        var vanished = false
        /// 被开关 / local_level 过滤（不是失败）。
        var filtered = false
        /// 有行没写成（没有会话、段打不开、write 失败）。临时 writer 收编（孤儿 / 重做）据此不提交。
        var failed = false

        mutating func merge(_ o: Outcome) {
            failed = failed || o.failed
            written = written || o.written
            rotated = rotated || o.rotated
            fatal = fatal || o.fatal
            deadlineChanged = deadlineChanged || o.deadlineChanged
            tombstone = tombstone || o.tombstone
            vanished = vanished || o.vanished
        }
    }

    enum CommitResult {
        case committed(Outcome)
        /// 会话目录 / root 在收编中消失（段文件已被 unlink）：不提交，重新 bootstrap 后从偏移 0 重放（pre 文件在提交前完整）。
        case vanished
        /// 尾巴里还有没过 redact 的记录：交给调用方（锁外）处理后再来。
        case again([PreRecord])
        case failed
    }

    private let lock = NSLock()
    private let clock: any Clock
    let counter: DropCounter

    // ---- 以下全部受 lock 保护 ----
    private var sessionDir: URL?
    private var sessionId: String = ""
    private var fd: Int32 = -1
    private var cur: SegInfo
    private var seq: Int64 = 0
    private var oseq: Int64 = 0
    private var host: HostDefaults
    private var cache: ConfigCache?
    private var eff: EffectiveConfig
    /// 临时 writer（孤儿收编）直接设级别，不随宿主 / 缓存重算。
    private var fixedLevels = false
    private var uploadRank = LogLevel.warn.rank
    private var localRank = LogLevel.debug.rank
    private var enabled = true
    /// 当前段的用户（段头 user_id）。
    private var user: String?
    /// 宿主最近一次 setUser 的值（清洗后）。收编中它可能领先于 `user`：用户切换先进 pre 文件，按序重放时才落到段头。
    private var hostUser: String?
    private var flushIntervalMs: Int64 = Int64(Limits.flushIntervalSDefault) * 1000
    private var errorDeadline: Int64?
    private var lastErrorSealMono: Int64 = Int64.min / 4
    private var lastFatalRotateMono: Int64 = Int64.min / 4
    private var warnDeadline: Int64?
    private var pending: [SealJob] = []
    private var failed: [(from: Int64, to: Int64, n: Int64, atMs: Int64)] = []
    private var nextReopenMono: Int64 = 0
    private var protectedDataUnavailable = false
    private var adopting: PreFile?
    private var vanished = false

    init(clock: any Clock, host: HostDefaults = HostDefaults(uploadLevel: .warn), counter: DropCounter = DropCounter()) {
        self.clock = clock
        self.counter = counter
        self.host = host
        cur = SegInfo(segNo: 0, userId: nil, startedMs: 0, url: URL(fileURLWithPath: "/dev/null"))
        eff = ConfigCache.effective(nil, host: host, nowWall: clock.wallMs(), nowMono: clock.monoMs())
        uploadRank = eff.uploadLevel.rank
        localRank = eff.config.localLevel.rank
        flushIntervalMs = Int64(eff.config.flushIntervalS) * 1000
    }

    deinit {
        if fd >= 0 { close(fd) }
        for j in pending where j.fd >= 0 { close(j.fd) }
    }

    // MARK: 会话

    /// 开始（或重开）一个会话：seq / oseq 从 0 起，打开 seg-000001.open。
    /// 旧会话还没交出去的封段任务一并作废（purgeLocal：它们在改名出去的旧 root 里，随旧状态删除）。
    func startSession(dir: URL, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        for j in pending where j.fd >= 0 { close(j.fd) }
        fd = -1
        sessionDir = dir
        self.sessionId = sessionId
        seq = 0
        oseq = 0
        pending.removeAll()
        failed.removeAll()
        errorDeadline = nil
        warnDeadline = nil
        vanished = false
        nextReopenMono = 0
        cur = SegInfo(segNo: 0, userId: user, startedMs: 0, url: URL(fileURLWithPath: "/dev/null"))
        _ = openSegmentLocked(1)
    }

    /// 放弃当前会话（purgeLocal）：关 fd，不封段。
    func abandonSession() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        for j in pending where j.fd >= 0 { close(j.fd) }
        fd = -1
        pending.removeAll()
        failed.removeAll()
        sessionDir = nil
    }

    /// 会话目录消失：放下会话，交出已写进被删 inode 的段（当前段与待封段里 `st_nlink == 0` 的），由调用方计数。
    func abandonVanished() -> [SegInfo] {
        lock.lock()
        defer { lock.unlock() }
        var lost: [SegInfo] = []
        func gone(_ f: Int32) -> Bool {
            var st = stat()
            return fstat(f, &st) == 0 && st.st_nlink == 0
        }
        for j in pending where j.fd >= 0 {
            if gone(j.fd) { lost.append(j.info) }
            close(j.fd)
        }
        if fd >= 0 {
            if gone(fd) { lost.append(cur) }
            close(fd)
        }
        fd = -1
        pending.removeAll()
        failed.removeAll()
        sessionDir = nil
        vanished = false
        return lost
    }

    var currentSessionId: String {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    var hasSession: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionDir != nil && !vanished
    }

    /// 换段时发现会话目录已不在、还没重新 bootstrap。
    var hasVanished: Bool {
        lock.lock(); defer { lock.unlock() }
        return vanished
    }

    // MARK: 参数（宿主默认与缓存快照只存这里一份）

    private func recomputeLocked() -> EffectiveConfig {
        eff = ConfigCache.effective(cache, host: host, nowWall: clock.wallMs(), nowMono: clock.monoMs())
        if !fixedLevels {
            uploadRank = eff.uploadLevel.rank
            localRank = eff.config.localLevel.rank
            flushIntervalMs = Int64(eff.config.flushIntervalS) * 1000
        }
        return eff
    }

    /// 宿主线程（configure / reconfigure）：换宿主默认，锁内重算生效级别——返回后写的行立即按新级别判定。
    @discardableResult
    func setHost(_ h: HostDefaults) -> EffectiveConfig {
        lock.lock()
        defer { lock.unlock() }
        host = h
        return recomputeLocked()
    }

    /// 引擎线程：推新的缓存快照（不可变值）并重算。
    @discardableResult
    func setConfigCache(_ c: ConfigCache?) -> EffectiveConfig {
        lock.lock()
        defer { lock.unlock() }
        cache = c
        return recomputeLocked()
    }

    var hostDefaults: HostDefaults {
        lock.lock(); defer { lock.unlock() }
        return host
    }

    var effective: EffectiveConfig {
        lock.lock(); defer { lock.unlock() }
        return eff
    }

    /// 直接设级别（孤儿收编的临时 writer：按收编时的生效级别判定）。
    func setLevels(upload: LogLevel, local: LogLevel, flushIntervalS: Int) {
        lock.lock()
        defer { lock.unlock() }
        fixedLevels = true
        uploadRank = upload.rank
        localRank = local.rank
        flushIntervalMs = Int64(flushIntervalS) * 1000
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); enabled = on; lock.unlock()
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setProtectedDataUnavailable(_ v: Bool) {
        lock.lock(); protectedDataUnavailable = v; lock.unlock()
    }

    /// 快速预判：未启用或低于 local_level 的行不做任何工作（不占 seq）。
    func accepts(_ level: LogLevel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && level.rank >= localRank
    }

    /// 只看 local_level（收编：开关不影响已落盘的 pre 行，见实现报告）。
    func passesLocal(_ level: LogLevel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return level.rank >= localRank
    }

    /// 生效的上传 / 本地级别（远程配置钳制后；full_dump 期间上传级别为 debug）。
    var levels: (upload: LogLevel, local: LogLevel) {
        lock.lock(); defer { lock.unlock() }
        return (LogLevel.allCases[uploadRank], LogLevel.allCases[localRank])
    }

    /// 宿主最近设的用户（配置请求身份用）。
    var currentUser: String? {
        lock.lock(); defer { lock.unlock() }
        return hostUser
    }

    // MARK: 收编（ADR 0023）

    /// 建会话之前：没有 pre 文件时，configure 之前暂存的用户直接作为首段用户。
    func setInitialUser(_ u: String?) {
        lock.lock()
        user = u
        hostUser = u
        lock.unlock()
    }

    /// 进入收编中：宿主之后的行 / 用户切换追加到 pre 文件。会话从 user = nil 起（pre 文件的用户记录按序重放）；
    /// `hostUser` = configure 之前暂存的用户（配置请求的身份）。
    func beginAdopting(_ p: PreFile, hostUser u: String?) {
        lock.lock()
        adopting = p
        user = nil
        hostUser = u
        lock.unlock()
    }

    var isAdopting: Bool {
        lock.lock(); defer { lock.unlock() }
        return adopting != nil
    }

    /// 引擎线程：把一条 pre 行经**正常追加路径**写进会话（义务判定、seq / oseq、换段、去抖都由同一个状态机产生）。
    /// 不看开关：pre 行是已经落盘的数据（同恢复旧会话照常物化）；`r` = 1 的行不再按 local_level 过滤。
    /// 不计数：写不进（会话目录消失）时 pre 文件仍完整，重新 bootstrap 后从头重放，行不丢。
    func adoptAppend(level: LogLevel, ts: Int64, body: [UInt8], refilter: Bool) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return appendLocked(level: level, ts: ts, body: body, forcedOblig: false, skipLocal: !refilter, ignoreEnabled: true,
                            countDrops: false)
    }

    /// 收编从 pre 文件开头重放之前：段用户回到 pre 文件开头的状态（nil；用户切换记录按序重放）。
    func resetUserForReplay() {
        lock.lock()
        user = nil
        lock.unlock()
    }

    /// 引擎线程：重放 pre 文件里的用户切换（走 writer 的 setUser 路径；不改 hostUser）。返回是否封了段。
    func adoptSetUser(_ u: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyUserLocked(u)
    }

    /// 提交（锁内）：读到文件尾、处理追赶期间新追加的记录 → 用户对齐到宿主最近的值 → unlink pre 文件（提交点）→ 切正常态。
    func commitAdoption(_ reader: PreReader) -> CommitResult {
        lock.lock()
        defer { lock.unlock() }
        guard let p = adopting else { return .committed(Outcome()) }
        guard let recs = reader.readAvailable() else { return .failed }
        if recs.contains(where: { if case .line(false, _, _, _) = $0 { return true }; return false }) { return .again(recs) }
        var out = Outcome()
        for r in recs {
            switch r {
            case .user(let u):
                if applyUserLocked(u) { out.rotated = true }
            case .line(_, let level, let ts, let body):
                out.merge(appendLocked(level: level, ts: ts, body: body, forcedOblig: false, skipLocal: true, ignoreEnabled: true,
                                       countDrops: true))
            case .header, .garbage:
                break
            }
        }
        // 用户切换记录写失败（pre 文件满 / 写失败）时也保证最终用户正确
        if user != hostUser, applyUserLocked(hostUser) { out.rotated = true }
        // 提交前确认写进的段还在（会话目录 / root 在收编中被删：行写进了被删的 inode）——不在就不提交，重放
        func gone(_ f: Int32) -> Bool {
            var st = stat()
            return f >= 0 && fstat(f, &st) == 0 && st.st_nlink == 0
        }
        if vanished || gone(fd) || pending.contains(where: { gone($0.fd) }) {
            vanished = true
            return .vanished
        }
        // 提交点：unlink，或 unlink 失败时截成空文件（PreFile.commit）；都不成才重试——不会无限停在收编中
        guard PreFile.commit(url: p.url, fd: p.fd) else { return .failed }
        p.close()
        adopting = nil
        return .committed(out)
    }

    /// 放弃收编（purge / 会话目录消失）：交出 pre 文件（调用方删 / 关）。
    func abortAdoption() -> PreFile? {
        lock.lock()
        defer { lock.unlock() }
        let p = adopting
        adopting = nil
        return p
    }

    // MARK: 热路径

    /// 宿主行 / SDK 合成行。收编中 → 追加到 pre 文件（`r` = 1）；没有会话 → 计数（`countDrops`）。
    func append(level: LogLevel, ts: Int64, body: [UInt8], countDrops: Bool = true) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if let p = adopting {
            var out = Outcome()
            guard enabled, level.rank >= localRank else { out.filtered = true; return out }
            if p.appendLine(redacted: true, body: body) {
                out.written = true
            } else if countDrops {
                counter.add(level: level, ts: ts)
            }
            return out
        }
        return appendLocked(level: level, ts: ts, body: body, forcedOblig: false, skipLocal: false, ignoreEnabled: false,
                            countDrops: countDrops)
    }

    /// 强制写入的义务行（`rtv.pre_init_dropped`：SDK 自己的丢行报告，不受 local_level / upload_level 影响；禁用时不写）。
    /// 收编中不写（那时只能进 pre 文件、丢了强制义务的标记）：调用方等提交后再写。
    func appendForced(level: LogLevel, ts: Int64, body: [UInt8]) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard adopting == nil else { return Outcome() }
        return appendLocked(level: level, ts: ts, body: body, forcedOblig: true, skipLocal: true, ignoreEnabled: false,
                            countDrops: false)
    }

    /// flush 的合成行（level error、tag rtv.flush、synthetic）：无视 local_level / upload_level 一定是义务行，
    /// 写完立即封段。返回该行的 oseq（写失败 / 收编中 nil）。
    func appendFlushMarker(ts: Int64, body: [UInt8], noCtx: Bool) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard adopting == nil else { return nil }
        let out = appendLocked(level: .error, ts: ts, body: body, forcedOblig: true, skipLocal: true, ignoreEnabled: false,
                               countDrops: false)
        guard out.written else { return nil }
        let o = oseq
        _ = rotateLocked(.flush, noCtx: noCtx)
        return o
    }

    private func appendLocked(level: LogLevel, ts: Int64, body: [UInt8], forcedOblig: Bool, skipLocal: Bool,
                              ignoreEnabled: Bool, countDrops: Bool) -> Outcome {
        var out = Outcome()
        guard ignoreEnabled || enabled, forcedOblig || skipLocal || level.rank >= localRank else {
            out.filtered = true
            return out
        }
        guard sessionDir != nil, !vanished else {
            // 没有会话（bootstrap 失败、purge 后重建失败、会话目录消失）：行计数，之后以合成行上报（ADR 0024 决定 1）
            if countDrops { counter.add(level: level, ts: ts) }
            out.failed = true
            return out
        }
        let now = clock.monoMs()
        if fd < 0 && now >= nextReopenMono {
            if !openSegmentLocked(cur.segNo == 0 ? 1 : cur.segNo) {
                nextReopenMono = now + 1000
                if vanished {
                    if countDrops { counter.add(level: level, ts: ts) }
                    out.vanished = true
                    out.failed = true
                    return out
                }
            }
        }
        seq += 1
        let oblig = forcedOblig || level.rank >= uploadRank
        if oblig { oseq += 1 }
        let pre = LineEncoder.prefix(seq: seq, oseq: oblig ? oseq : 0)
        var buf = [UInt8]()
        buf.reserveCapacity(pre.count + body.count)
        buf.append(contentsOf: pre)
        buf.append(contentsOf: body)
        var ok = false
        if fd >= 0 {
            ok = buf.withUnsafeBytes { FS.writeAll(fd, $0) }
            if !ok { _ = ftruncate(fd, off_t(cur.bytes)) }
        }
        if !ok {
            if oblig { recordFailedLocked(oseq) ; out.tombstone = true }
            out.failed = true
            return out
        }
        out.written = true
        if !failed.isEmpty { out.tombstone = true }
        cur.bytes += Int64(buf.count)
        if cur.firstSeq == 0 { cur.firstSeq = seq }
        cur.lastSeq = seq
        cur.lineCount += 1
        if cur.lineCount == 1 {
            cur.firstTs = ts
            cur.lastTs = ts
        } else {
            cur.firstTs = min(cur.firstTs, ts)
            cur.lastTs = max(cur.lastTs, ts)
        }
        if level.rank >= LogLevel.error.rank { cur.errorLines += 1 }
        if oblig {
            if cur.firstOseq == 0 { cur.firstOseq = oseq }
            cur.lastOseq = oseq
            cur.obligCount += 1
            if level.rank >= LogLevel.error.rank { cur.hasError = true }
        }
        if level == .fatal && now - lastFatalRotateMono >= ClientConstants.fatalWindowMs {
            // 窗口内第一条 fatal：立即封段并物化（调用方投递，只落盘不尝试上传）
            if rotateLocked(.fatal, noCtx: false) {
                lastFatalRotateMono = now
                out.rotated = true
                out.fatal = true
            }
            out.vanished = vanished
            return out
        }
        // 窗口内其后的 fatal 照常逐行落盘，但不强制换段：并入 error 的去抖封段（ADR 0024 决定 8）
        if oblig && level.rank >= LogLevel.error.rank && errorDeadline == nil {
            errorDeadline = max(now + Limits.errorDebounceMs, lastErrorSealMono + Limits.errorSealMinIntervalMs)
            out.deadlineChanged = true
        }
        if oblig && cur.obligCount == 1 && warnDeadline == nil {
            warnDeadline = now + flushIntervalMs
            out.deadlineChanged = true
        }
        // 强制义务行（flush 标记、rtv.pre_init_dropped）不按大小换段：flush 标记随后自己封段，换段原因必须是 flush
        if !forcedOblig && cur.bytes >= Int64(Limits.segmentBytes) {
            out.rotated = rotateLocked(.size, noCtx: false)
        }
        // 换段时下一段 open 得 ENOENT：会话目录已不在
        out.vanished = vanished
        return out
    }

    private func recordFailedLocked(_ o: Int64) {
        let at = clock.wallMs()
        if var last = failed.last, last.to + 1 == o {
            last.to = o
            last.n += 1
            failed[failed.count - 1] = last
        } else {
            failed.append((o, o, 1, at))
        }
    }

    // MARK: 换段

    @discardableResult
    private func openSegmentLocked(_ segNo: Int) -> Bool {
        guard let dir = sessionDir else { return false }
        let url = dir.appendingPathComponent(Segments.name(segNo, open: true))
        let started = clock.wallMs()
        cur = SegInfo(segNo: segNo, userId: user, startedMs: started, url: url)
        if Faults.failsSegmentOpen(url) {
            fd = -1
            return false
        }
        let f = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if f < 0 {
            // 会话目录 / root 在运行中被删（ADR 0024 决定 4）：之后的行计数，调用方投递重新 bootstrap
            if errno == ENOENT { vanished = true }
            fd = -1
            return false
        }
        FS.markFile(url)
        let header = SegmentHeader(segNo: segNo, userId: user, startedMs: started).encode()
        if !header.withUnsafeBytes({ FS.writeAll(f, $0) }) {
            close(f)
            fd = -1
            return false
        }
        fd = f
        cur.bytes = Int64(header.count)
        return true
    }

    /// 锁内换段：当前段（有行才换）交给 work 队列封，立即打开下一段。
    @discardableResult
    private func rotateLocked(_ reason: SealReason, noCtx: Bool) -> Bool {
        guard fd >= 0, cur.lineCount > 0 else { return false }
        pending.append(SealJob(fd: fd, info: cur, reason: reason, noCtx: noCtx, seqAtSeal: seq, oseqAtSeal: oseq))
        if cur.hasError { lastErrorSealMono = clock.monoMs() }
        errorDeadline = nil
        warnDeadline = nil
        fd = -1
        _ = openSegmentLocked(cur.segNo + 1)
        return true
    }

    /// 外部触发的封段（flush / full_dump / upload_enabled / 进后台）。
    /// `onlyIfObligation`：进后台、warn 计时只在段内有义务行时封。
    @discardableResult
    func rotate(_ reason: SealReason, onlyIfObligation: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if onlyIfObligation && cur.obligCount == 0 { return false }
        return rotateLocked(reason, noCtx: false)
    }

    /// setUser：值变化即封段；当前段还没有行时直接改写 header（用户边界 = 段边界）。
    /// 收编中：只追加一条用户切换记录到 pre 文件（按序重放时才落到段头），保证 configure 之前 / 收编期间的用户边界正确。
    /// 返回 changed = 值变了（身份变化，要重拉配置），rotated = 封了段（二者不同：空段改写 header 时变了但没封）。
    @discardableResult
    func setUser(_ u: String?) -> (changed: Bool, rotated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard u != hostUser else { return (false, false) }
        hostUser = u
        if let p = adopting {
            _ = p.appendUser(u, capped: false)
            return (true, false)
        }
        return (true, applyUserLocked(u))
    }

    private func applyUserLocked(_ u: String?) -> Bool {
        guard u != user else { return false }
        user = u
        if fd >= 0 && cur.lineCount == 0 {
            let header = SegmentHeader(segNo: cur.segNo, userId: u, startedMs: cur.startedMs).encode()
            if ftruncate(fd, 0) == 0, header.withUnsafeBytes({ FS.writeAll(fd, $0) }) {
                cur.userId = u
                cur.bytes = Int64(header.count)
                return false
            }
        }
        if fd < 0 { cur.userId = u; return false }
        return rotateLocked(.user, noCtx: false)
    }

    /// 定时器：error 去抖到期 / warn 计时到期（仅当有义务行）。
    func checkDeadlines() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.monoMs()
        if let d = errorDeadline, now >= d {
            errorDeadline = nil
            if rotateLocked(.error, noCtx: false) { return true }
        }
        if let w = warnDeadline, now >= w {
            warnDeadline = nil
            if cur.obligCount > 0 { return rotateLocked(.timer, noCtx: false) }
        }
        return false
    }

    var nextDeadline: Int64? {
        lock.lock(); defer { lock.unlock() }
        return [errorDeadline, warnDeadline].compactMap { $0 }.min()
    }

    func takePendingSeals() -> [SealJob] {
        lock.lock()
        defer { lock.unlock() }
        let p = pending
        pending.removeAll()
        return p
    }

    func takeFailed() -> [(from: Int64, to: Int64, n: Int64, atMs: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        let f = failed
        failed.removeAll()
        return f
    }

    func putBackFailed(_ f: [(from: Int64, to: Int64, n: Int64, atMs: Int64)]) {
        lock.lock()
        failed.insert(contentsOf: f, at: 0)
        lock.unlock()
    }

    /// 测试 / 诊断用快照。`user` = 当前段的用户。
    struct Snapshot { var seq: Int64; var oseq: Int64; var segNo: Int; var segBytes: Int64; var segLines: Int; var user: String? }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(seq: seq, oseq: oseq, segNo: cur.segNo, segBytes: cur.bytes, segLines: cur.lineCount, user: user)
    }

    /// 测试：把当前段 fd 换成只读，模拟写失败（ENOSPC / 保护类不可用）。
    func debugBreakFd() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let ro = open(cur.url.path, O_RDONLY | O_CLOEXEC)
        close(fd)
        fd = ro
    }

    var currentSegmentURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 ? cur.url : nil
    }
}

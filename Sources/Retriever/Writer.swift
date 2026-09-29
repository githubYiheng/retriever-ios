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
final class Writer: @unchecked Sendable {
    struct Outcome {
        var written = false
        var rotated = false
        var fatal = false
        var deadlineChanged = false
        var tombstone = false
    }

    private let lock = NSLock()
    private let clock: any Clock

    // ---- 以下全部受 lock 保护 ----
    private var sessionDir: URL?
    private var sessionId: String = ""
    private var fd: Int32 = -1
    private var cur: SegInfo
    private var seq: Int64 = 0
    private var oseq: Int64 = 0
    private var uploadRank = LogLevel.warn.rank
    private var localRank = LogLevel.debug.rank
    private var enabled = true
    private var user: String?
    private var flushIntervalMs: Int64 = Int64(Limits.flushIntervalSDefault) * 1000
    private var errorDeadline: Int64?
    private var lastErrorSealMono: Int64 = Int64.min / 4
    private var warnDeadline: Int64?
    private var pending: [SealJob] = []
    private var failed: [(from: Int64, to: Int64, n: Int64, atMs: Int64)] = []
    private var nextReopenMono: Int64 = 0
    private var protectedDataUnavailable = false

    init(clock: any Clock) {
        self.clock = clock
        cur = SegInfo(segNo: 0, userId: nil, startedMs: 0, url: URL(fileURLWithPath: "/dev/null"))
    }

    deinit {
        if fd >= 0 { close(fd) }
        for j in pending where j.fd >= 0 { close(j.fd) }
    }

    // MARK: 会话

    /// 开始（或重开）一个会话：seq / oseq 从 0 起，打开 seg-000001.open。
    func startSession(dir: URL, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
        sessionDir = dir
        self.sessionId = sessionId
        seq = 0
        oseq = 0
        pending.removeAll()
        failed.removeAll()
        errorDeadline = nil
        warnDeadline = nil
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

    var currentSessionId: String {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    // MARK: 参数

    func setLevels(upload: LogLevel, local: LogLevel, flushIntervalS: Int) {
        lock.lock()
        defer { lock.unlock() }
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

    /// 生效的上传 / 本地级别（远程配置钳制后；full_dump 期间上传级别为 debug）。
    var levels: (upload: LogLevel, local: LogLevel) {
        lock.lock(); defer { lock.unlock() }
        return (LogLevel.allCases[uploadRank], LogLevel.allCases[localRank])
    }

    var currentUser: String? {
        lock.lock(); defer { lock.unlock() }
        return user
    }

    // MARK: 热路径

    func append(level: LogLevel, body: [UInt8]) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return appendLocked(level: level, body: body, forced: false)
    }

    /// flush 的合成行（level error、tag rtv.flush、synthetic）：无视 local_level / upload_level 一定是义务行，
    /// 写完立即封段。返回该行的 oseq（写失败 nil，已记 write_failed 墓碑）。
    func appendFlushMarker(body: [UInt8], noCtx: Bool) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let out = appendLocked(level: .error, body: body, forced: true)
        guard out.written else { return nil }
        let o = oseq
        _ = rotateLocked(.flush, noCtx: noCtx)
        return o
    }

    private func appendLocked(level: LogLevel, body: [UInt8], forced: Bool) -> Outcome {
        var out = Outcome()
        guard enabled, forced || level.rank >= localRank, sessionDir != nil else { return out }
        let now = clock.monoMs()
        if fd < 0 && now >= nextReopenMono {
            if !openSegmentLocked(cur.segNo == 0 ? 1 : cur.segNo) { nextReopenMono = now + 1000 }
        }
        seq += 1
        let oblig = forced || level.rank >= uploadRank
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
            return out
        }
        out.written = true
        if !failed.isEmpty { out.tombstone = true }
        cur.bytes += Int64(buf.count)
        if cur.firstSeq == 0 { cur.firstSeq = seq }
        cur.lastSeq = seq
        cur.lineCount += 1
        if oblig {
            if cur.firstOseq == 0 { cur.firstOseq = oseq }
            cur.lastOseq = oseq
            cur.obligCount += 1
            if level.rank >= LogLevel.error.rank { cur.hasError = true }
        }
        if forced { return out }
        if level == .fatal {
            // fatal：立即封段并物化（调用方在锁外同步处理，只落盘不尝试上传）
            if rotateLocked(.fatal, noCtx: false) { out.rotated = true; out.fatal = true }
            return out
        }
        if oblig && level == .error && errorDeadline == nil {
            errorDeadline = max(now + Limits.errorDebounceMs, lastErrorSealMono + Limits.errorSealMinIntervalMs)
            out.deadlineChanged = true
        }
        if oblig && cur.obligCount == 1 && warnDeadline == nil {
            warnDeadline = now + flushIntervalMs
            out.deadlineChanged = true
        }
        if cur.bytes >= Int64(Limits.segmentBytes) {
            out.rotated = rotateLocked(.size, noCtx: false)
        }
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
        let f = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if f < 0 { fd = -1; return false }
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

    /// 外部触发的封段（flush / full_dump / upload_enabled / 进后台 / 关停）。
    /// `onlyIfObligation`：进后台、warn 计时只在段内有义务行时封。
    @discardableResult
    func rotate(_ reason: SealReason, onlyIfObligation: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if onlyIfObligation && cur.obligCount == 0 { return false }
        return rotateLocked(reason, noCtx: false)
    }

    /// setUser：值变化即封段；当前段还没有行时直接改写 header（用户边界 = 段边界）。
    @discardableResult
    func setUser(_ u: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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

    /// 测试 / 诊断用快照。
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

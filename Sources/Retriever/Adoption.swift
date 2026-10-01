import Foundation
#if canImport(Darwin)
import Darwin
#endif

// 收编（ADR 0023；简报 §1.2）：configure 之前写进 pre 文件的行，经 writer 的**正常追加路径**写进会话——义务判定、seq / oseq、
// fatal 换段、error 去抖、warn 计时、用户边界都由同一个状态机产生。提交点 = unlink pre 文件（unlink 失败时截成空文件）；
// 提交前会话不物化、不上传、不参与驱逐；
// 未提交的收编在恢复时从 pre 文件重做（pre 文件在提交前始终完整）。

/// 收编时每条记录现取的 redact 钩子。
typealias RedactProvider = () -> (@Sendable (LogLine) -> LogLine?)?

/// 本进程待收编的 pre 文件。
final class PendingAdoption: @unchecked Sendable {
    let file: PreFile
    var reader: PreReader?

    init(file: PreFile) { self.file = file }

    var name: String { file.name }
    var url: URL { file.url }
}

/// 测试注入（internal）：按目录前缀让 meta.json 写失败、段文件打不开、root 目录锁拿不到。
enum Faults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var metaPrefixes: [String] = []
    nonisolated(unsafe) private static var segPrefixes: [String] = []
    nonisolated(unsafe) private static var lockPrefixes: [String] = []

    static func failSegmentOpens(under dir: URL) { lock.lock(); segPrefixes.append(dir.path); lock.unlock() }
    static func clearSegmentFaults(under dir: URL) { lock.lock(); segPrefixes.removeAll { $0 == dir.path }; lock.unlock() }
    static func failsSegmentOpen(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return segPrefixes.contains { url.path.hasPrefix($0) }
    }

    nonisolated(unsafe) private static var preAppendPrefixes: [String] = []
    nonisolated(unsafe) private static var preCommitPrefixes: [String] = []
    static func failPreAppends(under dir: URL) { lock.lock(); preAppendPrefixes.append(dir.path); lock.unlock() }
    static func clearPreAppendFaults(under dir: URL) { lock.lock(); preAppendPrefixes.removeAll { $0 == dir.path }; lock.unlock() }
    static func failsPreAppend(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return preAppendPrefixes.contains { url.path.hasPrefix($0) }
    }
    static func failPreCommits(under dir: URL) { lock.lock(); preCommitPrefixes.append(dir.path); lock.unlock() }
    static func clearPreCommitFaults(under dir: URL) { lock.lock(); preCommitPrefixes.removeAll { $0 == dir.path }; lock.unlock() }
    static func failsPreCommit(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return preCommitPrefixes.contains { url.path.hasPrefix($0) }
    }

    static func failDirLocks(under dir: URL) { lock.lock(); lockPrefixes.append(dir.path); lock.unlock() }
    static func clearDirLockFaults(under dir: URL) { lock.lock(); lockPrefixes.removeAll { $0 == dir.path }; lock.unlock() }
    static func failsDirLock(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lockPrefixes.contains { url.path.hasPrefix($0) }
    }

    static func failMetaWrites(under dir: URL) {
        lock.lock(); defer { lock.unlock() }
        metaPrefixes.append(dir.path)
    }

    static func clearMetaFaults(under dir: URL) {
        lock.lock(); defer { lock.unlock() }
        metaPrefixes.removeAll { $0 == dir.path }
    }

    static func failsMetaWrite(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return metaPrefixes.contains { url.path.hasPrefix($0) }
    }
}

/// 测试钩子（真杀进程测试在收编的各个崩溃点 SIGKILL 自己）。生产不设。
@_spi(RetrieverTesting)
public enum RetrieverTestHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hook: (@Sendable (String) -> Void)?

    /// 收编走到某个点时回调：`adopt_begin`（meta.pre 已写、尚未写任何行）、`adopt_mid`（已写进第一条记录）、
    /// `adopt_before_commit`（全部写完、unlink 之前）。
    public static func setAdoptionHook(_ f: (@Sendable (String) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        hook = f
    }

    static func adoption(_ point: String) {
        lock.lock()
        let h = hook
        lock.unlock()
        h?(point)
    }
}

extension Engine {
    /// 把一批 pre 记录经 `w` 的正常追加路径写进它的会话。`r` = 0 的行：有 redact 钩子则解码 → 钩子（不持任何 SDK 锁；
    /// 置重入标志，钩子里的 log() 被忽略；返回 nil → 丢弃）→ 重编码（ts 取回原值，保留 synthetic，truncated 与原值取或）；
    /// 无钩子不解码。然后按生效 local_level 过滤。`r` = 1 的行原样。用户切换记录走 writer 的 setUser 路径。
    /// `redact`：每条记录现取（收编途中 reconfigure 换了钩子立即生效）。
    func adopt(_ recs: [PreRecord], into w: Writer, redact: RedactProvider, hookFirst: Bool = false) -> Writer.Outcome {
        var out = Writer.Outcome()
        var first = hookFirst
        for r in recs {
            switch r {
            case .header, .garbage:
                continue
            case .user(let u):
                if w.adoptSetUser(u) { out.rotated = true }
            case .line(let redacted, let level, let ts, let body):
                var lvl = level
                var b = body
                if !redacted {
                    if let redact = redact() {
                        guard let d = LineDecoder.decode(body) else {
                            // 解不出来就不能过钩子：不带未脱敏的内容进会话，计数
                            counter.add(level: level, ts: ts)
                            continue
                        }
                        let was = Reentrancy.active
                        Reentrancy.active = true
                        let res = redact(d.line)
                        Reentrancy.active = was
                        guard var l = res else { continue }
                        l.ts = d.line.ts
                        b = LineEncoder.encode(l, synthetic: d.synthetic, truncated: d.truncated).body
                        lvl = l.level
                    }
                    guard w.passesLocal(lvl) else { continue }
                }
                out.merge(w.adoptAppend(level: lvl, ts: ts, body: b, refilter: false))
            }
            if first {
                first = false
                RetrieverTestHooks.adoption("adopt_mid")
            }
        }
        return out
    }

    /// meta.pre 所指的 pre 文件的状态（盲审裁决 8，三态）：确实不存在或长度为 0（unlink 失败时截空提交）= 已提交；
    /// 非空 = 未提交（重做）；stat 出错 = 本轮不处理（不重做，也不当普通会话恢复）。
    enum PreState { case committed, uncommitted, unknown }

    func preState(_ name: String) -> PreState {
        switch FS.sizeState(preDir.appendingPathComponent(name)) {
        case .missing, .size(0): return .committed
        case .size: return .uncommitted
        case .error: return .unknown
        }
    }

    /// 临时 writer 有行没写成：删掉这次写出的段，回到「未收编」的样子（meta.pre 保留、pre 文件不动），下次启动重做。
    private func rollbackTemp(_ dir: URL) {
        for n in FS.list(dir) where Segments.parseName(n) != nil {
            FS.remove(dir.appendingPathComponent(n))
        }
    }

    /// 收编提交后清掉 meta.json 的 `pre` 键（写不成无妨：所指文件已不在 = 已提交）。
    func clearMetaPre(dir: URL, meta: SessionMeta) {
        var m = meta
        m.pre = nil
        _ = Engine.writeMeta(dir.appendingPathComponent("meta.json"), m)
    }

    /// 读到文件尾的全部完整记录（没有并发写者的 pre 文件：孤儿 / 重做）。nil = 读失败。
    private func readAll(_ reader: PreReader) -> [PreRecord]? {
        var all: [PreRecord] = []
        while true {
            guard let recs = reader.readAvailable() else { return nil }
            if recs.isEmpty { return all }
            all.append(contentsOf: recs)
        }
    }

    /// 临时 writer（不影响活会话）：按收编时的生效级别判定。它的计数器是一次性的：写不成就不提交（pre 文件留着），行没丢，不计。
    private func tempWriter(dir: URL, sessionId: String) -> Writer {
        let w = Writer(clock: clock, counter: DropCounter())
        let lv = writer.levels
        w.setLevels(upload: lv.upload, local: lv.local, flushIntervalS: writer.effective.config.flushIntervalS)
        w.setEnabled(true)
        w.startSession(dir: dir, sessionId: sessionId)
        return w
    }

    /// 孤儿会话的 session_no：此时分配（install.json 计数器 +1，root 目录锁内）。
    func allocSessionNo() -> Int64? {
        let got = FS.withDirLock(root) { () -> Int64? in
            guard let b = FS.read(installURL), var i = InstallInfo.decode(b) else { return nil }
            i.sessionCounter += 1
            guard FS.writeAtomic(installURL, i.encode()) else { return nil }
            return i.sessionCounter
        }
        return got ?? nil
    }

    /// startup（恢复旧会话之前）：
    /// 1. 本进程目录里收编未提交的会话（meta.pre 所指文件仍在、会话与 pre 文件都没有活着的持有者）：删掉已写的段与游标，
    ///    从 pre 文件重新收编进同一个会话；
    /// 2. 用默认 root 的实例：孤儿 pre 文件（flock 可得 = 写它的进程已死；没有任何会话的 meta.pre 指着它）各建一个会话目录收编。
    /// 收编出的会话随后交给现有恢复流程（没有前后台记录 → 不合成 `rtv.unclean_exit`）。
    func adoptPreFilesAtStartup(redact: RedactProvider) {
        guard install != nil, let cur = current else { return }
        var handled = Set<String>()
        for sid in FS.list(procDir) where IDs.isUuid(sid) && sid != cur.meta.sessionId {
            let dir = procDir.appendingPathComponent(sid)
            guard case .ok(let mb) = FS.readStrict(dir.appendingPathComponent("meta.json")), let meta = SessionMeta.decode(mb),
                  let name = meta.pre else { continue }
            let url = preDir.appendingPathComponent(name)
            switch preState(name) {
            case .committed: continue                       // 按普通会话恢复
            case .unknown: handled.insert(name); continue   // 本轮不处理（恢复也跳过它）
            case .uncommitted: handled.insert(name)
            }
            let lfd = open(dir.path, O_RDONLY | O_CLOEXEC)
            guard lfd >= 0 else { continue }
            defer { close(lfd) }
            guard flock(lfd, LOCK_EX | LOCK_NB) == 0 else { continue }   // 会话还活着
            guard let reader = PreReader(url: url) else { continue }
            defer { reader.close() }
            guard flock(reader.descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }   // pre 文件还有活着的持有者
            guard !reader.isUnlinked else { continue }   // 锁的是已被别人收编删掉的 inode
            guard let recs = readAll(reader) else { continue }
            // 重做：清掉已写的段与游标里的段进度（物化游标、ctx 游标）；前后台与收尾记录（last_state / last_state_ms / closed_ms）保留，
            // 重做完由恢复流程照常判定（fg 且未收尾 → 合成 rtv.unclean_exit，排在重做出的行之后）
            for n in FS.list(dir) where Segments.parseName(n) != nil {
                FS.remove(dir.appendingPathComponent(n))
            }
            let cursorURL = dir.appendingPathComponent("cursor.json")
            if let b = FS.read(cursorURL), var c = Cursor.decode(b) {
                c.extractedThroughOseq = 0
                c.ctxThroughSeq = 0
                guard FS.writeAtomic(cursorURL, c.encode()) else { continue }
            } else {
                FS.remove(cursorURL)
            }
            let w = tempWriter(dir: dir, sessionId: meta.sessionId)
            let out = adopt(recs, into: w, redact: redact)
            w.abandonSession()
            // 有任何一行没写成（段打不开、write 失败）：不提交——pre 文件原样留着，下次启动重做（盲审 🔴3）
            if out.failed {
                rollbackTemp(dir)
                continue
            }
            RetrieverTestHooks.adoption("redo_before_commit")
            guard PreFile.commit(url: url, fd: reader.descriptor) else { continue }
            clearMetaPre(dir: dir, meta: meta)
        }
        guard adoptsOrphans else { return }
        var refs: Set<String>?
        for name in FS.list(preDir) where PreName.isValid(name) && !handled.contains(name) {
            let url = preDir.appendingPathComponent(name)
            guard let reader = PreReader(url: url) else { continue }
            defer { reader.close() }
            guard flock(reader.descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }   // 别的活进程的 pre 文件不碰
            // 打开与加锁之间别的进程收编完 unlink 并放了锁：本方锁住的是已删的 inode，放弃（否则重复收编）
            guard !reader.isUnlinked else { continue }
            if refs == nil { refs = referencedPreNames() }
            if refs!.contains(name) { continue }   // 别的进程目录里收编未提交的会话：由它自己的进程重做
            adoptOrphan(url: url, name: name, reader: reader, redact: redact)
        }
    }

    /// 全部会话 meta 里的 `pre` 引用（只在确有孤儿候选时扫）。
    private func referencedPreNames() -> Set<String> {
        var out = Set<String>()
        for p in FS.list(root) where p.hasPrefix("proc-") {
            let pdir = root.appendingPathComponent(p)
            for sid in FS.list(pdir) where IDs.isUuid(sid) {
                if let b = FS.read(pdir.appendingPathComponent(sid).appendingPathComponent("meta.json")),
                   let m = SessionMeta.decode(b), let n = m.pre {
                    out.insert(n)
                }
            }
        }
        return out
    }

    private func adoptOrphan(url: URL, name: String, reader: PreReader, redact: RedactProvider) {
        guard let recs = readAll(reader) else { return }
        let hasContent = recs.contains { r in
            switch r {
            case .line, .user: return true
            default: return false
            }
        }
        guard hasContent else {
            // 只有头记录（或连头都没写完）：没有要收编的东西
            unlink(url.path)
            return
        }
        var header: PreHeader?
        var firstTs: Int64?
        for r in recs {
            if case .header(let h) = r, header == nil { header = h }
            if case .line(_, _, let ts, _) = r, firstTs == nil { firstTs = ts }
        }
        // 头记录坏了（磁盘损坏）：started_ms 取首行 ts，进程 / 设备取本实例的
        let h = header ?? PreHeader(startedMs: firstTs ?? (FS.mtimeMs(url) ?? clock.wallMs()), process: processName, device: device)
        guard let inst = install, let no = allocSessionNo() else { return }
        let sid = IDs.newV4()
        let dir = procDir.appendingPathComponent(sid)
        guard FS.ensureDir(dir) else { return }
        // 收编期间锁住目录：别的进程的恢复不会把写了一半的会话当死会话处理
        let lfd = open(dir.path, O_RDONLY | O_CLOEXEC)
        defer { if lfd >= 0 { close(lfd) } }
        if lfd >= 0 { _ = flock(lfd, LOCK_EX | LOCK_NB) }
        let meta = SessionMeta(sessionId: sid, sessionNo: no, startedMs: h.startedMs, device: h.device, process: h.process,
                               installId: inst.installId, pre: name)
        guard Engine.writeMeta(dir.appendingPathComponent("meta.json"), meta) else {
            FS.remove(dir)
            return
        }
        let w = tempWriter(dir: dir, sessionId: sid)
        let out = adopt(recs, into: w, redact: redact)
        w.abandonSession()
        // 有任何一行没写成：不提交。删掉写出的段、留下 meta（meta.pre 指着 pre 文件）——下次启动按「收编未提交」重做（盲审 🔴3）
        if out.failed {
            rollbackTemp(dir)
            return
        }
        // 提交点（unlink，失败则截成空文件）。都失败：留着，下次启动按「收编未提交」从 pre 文件重做
        guard PreFile.commit(url: url, fd: reader.descriptor) else { return }
        clearMetaPre(dir: dir, meta: meta)
    }
}

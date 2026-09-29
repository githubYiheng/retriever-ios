import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// 一个会话的物化状态（meta + cursor + 已封段索引）。
final class SessionRecord {
    var meta: SessionMeta
    var dir: URL
    var cursor: Cursor
    /// 已封段（RETAINED），按 seg_no 升序。
    var sealed: [SegInfo]

    init(meta: SessionMeta, dir: URL, cursor: Cursor, sealed: [SegInfo]) {
        self.meta = meta
        self.dir = dir
        self.cursor = cursor
        self.sealed = sealed
    }
}

/// 后台状态机：封段处理、物化、出站箱、驱逐、恢复、配置、上传队列决策。
/// **只在 work 队列上访问**（RetrieverClient 保证串行），所以不加锁。网络请求在队列外发。
final class Engine: @unchecked Sendable {
    let root: URL
    let procDir: URL
    let outboxDir: URL
    let processName: String
    let clock: any Clock
    let platform: any PlatformHooks
    let writer: Writer

    var host: HostDefaults
    var sdkVersion: String
    var key: String
    var baseURL: URL

    var install: InstallInfo?
    var current: SessionRecord?
    var others: [String: SessionRecord] = [:]
    var device: Device

    var metas: [String: BatchMeta] = [:]
    var embeddedDrops: Set<DropEntry> = []
    var embeddedClosed: Set<String> = []
    var pendingMapping: (user: String?, digest: String)?
    var mapping: MappingState?

    var configCache: ConfigCache?
    var effective: EffectiveConfig
    var lastConfigFetchMono: Int64?

    var backoff = BackoffState()
    var fails: [String: (count: Int, otherSuccess: Bool)] = [:]
    var inFlight: String?
    var lastRequestMono: Int64?
    var uploadLockFd: Int32 = -1
    /// 当前会话目录上的 flock（进程存活期间一直持有；进程死亡由内核释放）。
    /// 恢复流程拿不到某个旧会话目录的锁 = 该会话还活着（别的进程 / 同进程另一实例），跳过不动。
    var sessionLockFd: Int32 = -1

    /// 最近被 2xx 确认的 primary 区间（flush 判断「这一批已确认」用；只留最近 512 个）。
    var ackedRanges: [(sessionId: String, from: Int64, to: Int64)] = []
    /// 本进程已生成过 backfill 的段（"<session_id>:<seg_no>"），full_dump 反复生效时不重复生成。
    var backfilledSegs: Set<String> = []
    /// 本进程写出的批文件计数（判断「这次封段有没有产生批次」）。
    var batchesWritten = 0
    var todayDay = ""
    var todayCount = 0
    var enabled = true
    var previousAppVersion: String?
    var protectedDataUnavailable = false

    init(root: URL, processName: String, key: String, baseURL: URL, options: Options,
         clock: any Clock, platform: any PlatformHooks, writer: Writer) {
        self.root = root
        self.procDir = root.appendingPathComponent("proc-\(processName)")
        self.outboxDir = root.appendingPathComponent("outbox")
        self.processName = processName
        self.clock = clock
        self.platform = platform
        self.writer = writer
        self.key = key
        self.baseURL = baseURL
        self.host = HostDefaults(options)
        self.sdkVersion = options.sdkVersion
        let f = platform.deviceFields()
        device = Device(os: f["os"] ?? "", osVersion: f["os_version"] ?? "", model: f["model"] ?? "",
                        appVersion: f["app_version"] ?? "", build: f["build"] ?? "", locale: f["locale"] ?? "",
                        sdk: "retriever-ios/\(options.sdkVersion)").sanitized()
        effective = ConfigCache.effective(nil, host: host, nowWall: clock.wallMs(), nowMono: clock.monoMs())
    }

    // MARK: 路径

    var installURL: URL { root.appendingPathComponent("install.json") }
    var uploadLockURL: URL { root.appendingPathComponent("upload.lock") }
    var backoffURL: URL { root.appendingPathComponent("backoff.json") }
    var mappingURL: URL { root.appendingPathComponent("mapping.json") }
    var dropsURL: URL { root.appendingPathComponent("drops.jsonl") }
    var sessionsURL: URL { root.appendingPathComponent("sessions.jsonl") }
    /// 远程配置缓存（§5「拉不到用缓存、重启后用墙钟兜底」需要持久化；方案布局未列，见实现报告）。
    var configURL: URL { root.appendingPathComponent("config.json") }

    var sdkHeader: String { "retriever-ios/\(sdkVersion)" }

    // MARK: 启动（同步：log() 在 init 返回后立即可用）

    /// 建目录、install.json（首次生成 O_EXCL 临时文件 → fsync → rename，失败方重读）、计数器 +1、新会话。
    @discardableResult
    func bootstrap() -> Bool {
        guard FS.ensureDir(root), FS.ensureDir(procDir), FS.ensureDir(outboxDir) else { return false }
        FS.excludeFromBackup(root)
        let result: (InstallInfo, Int64)? = FS.withDirLock(root) { bumpInstallLocked() }
        guard let (inst, sessionNo) = result else { return false }
        install = inst
        let now = clock.wallMs()
        let sid = IDs.newV4()
        let dir = procDir.appendingPathComponent(sid)
        guard FS.ensureDir(dir) else { return false }
        lockSessionDir(dir)
        let meta = SessionMeta(sessionId: sid, sessionNo: sessionNo, startedMs: now, device: device, process: processName)
        FS.writeAtomic(dir.appendingPathComponent("meta.json"), meta.encode())
        let cursor = Cursor(lastState: platform.isForeground().map { $0 ? "fg" : "bg" }, lastStateMs: now)
        let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: [])
        current = rec
        writeCursor(rec)
        writer.startSession(dir: dir, sessionId: sid)
        loadPersistentState()
        return true
    }

    func lockSessionDir(_ dir: URL) {
        releaseSessionLock()
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { sessionLockFd = fd } else { close(fd) }
    }

    func releaseSessionLock() {
        guard sessionLockFd >= 0 else { return }
        flock(sessionLockFd, LOCK_UN)
        close(sessionLockFd)
        sessionLockFd = -1
    }

    deinit {
        if uploadLockFd >= 0 { flock(uploadLockFd, LOCK_UN); close(uploadLockFd) }
        if sessionLockFd >= 0 { flock(sessionLockFd, LOCK_UN); close(sessionLockFd) }
    }

    private func bumpInstallLocked() -> (InstallInfo, Int64)? {
        var inst: InstallInfo
        if let b = FS.read(installURL), let i = InstallInfo.decode(b) {
            inst = i
        } else {
            guard let created = createInstallLocked() else { return nil }
            inst = created
        }
        inst.sessionCounter += 1
        guard FS.writeAtomic(installURL, inst.encode()) else { return nil }
        return (inst, inst.sessionCounter)
    }

    private func createInstallLocked() -> InstallInfo? {
        let info = InstallInfo(installId: IDs.newV4(), sessionCounter: 0, createdMs: clock.wallMs())
        let tmp = root.appendingPathComponent(".install.json.tmp-\(getpid())")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            FS.protect(tmp)
            let bytes = info.encode()
            let ok = bytes.withUnsafeBytes { FS.writeAll(fd, $0) } && fsync(fd) == 0
            close(fd)
            if ok && !FS.exists(installURL) && rename(tmp.path, installURL.path) == 0 {
                FS.markFile(installURL)
            } else {
                unlink(tmp.path)
            }
        }
        // 失败方（或并发的另一方已写）重读
        if let b = FS.read(installURL), let i = InstallInfo.decode(b) { return i }
        return nil
    }

    private func loadPersistentState() {
        let nowWall = clock.wallMs()
        let nowMono = clock.monoMs()
        if let b = FS.read(backoffURL), let s = BackoffState.decodeColdStart(b, nowWall: nowWall, nowMono: nowMono) {
            backoff = s
        }
        if let b = FS.read(mappingURL) { mapping = MappingState.decode(b) }
        if let b = FS.read(configURL), let o = JSONIn.object(b), let fetched = JSONIn.int64(o["fetched_ms"]) {
            configCache = ConfigCache(config: ConfigRules.clamp(o["config"], host: host), fetchedWallMs: fetched, fetchedMonoMs: nil)
        }
        effective = ConfigCache.effective(configCache, host: host, nowWall: nowWall, nowMono: nowMono)
        writer.setLevels(upload: effective.uploadLevel, local: effective.config.localLevel, flushIntervalS: effective.config.flushIntervalS)
    }

    // MARK: 状态文件

    func writeCursor(_ s: SessionRecord) {
        FS.writeAtomic(s.dir.appendingPathComponent("cursor.json"), s.cursor.encode())
    }

    func persistBackoff() {
        FS.writeAtomic(backoffURL, backoff.encode())
    }

    func setLastState(_ state: String) {
        guard let cur = current else { return }
        cur.cursor.lastState = state
        cur.cursor.lastStateMs = clock.wallMs()
        writeCursor(cur)
    }

    // MARK: 封段处理（fsync → rename → 物化 → 原子写 cursor）

    /// 处理写入侧交来的全部封段任务；返回是否有新批次产生。
    @discardableResult
    func processSeals() -> Bool {
        let jobs = writer.takePendingSeals()
        guard !jobs.isEmpty, let cur = current else {
            flushTombstones()
            return false
        }
        for j in jobs {
            _ = fsync(j.fd)
            close(j.fd)
            let sealedURL = j.info.url.deletingLastPathComponent().appendingPathComponent(Segments.name(j.info.segNo, open: false))
            var info = j.info
            if rename(j.info.url.path, sealedURL.path) == 0 {
                FS.markFile(sealedURL)
                info.url = sealedURL
            }
            if j.info.url.deletingLastPathComponent().path == cur.dir.path {
                cur.sealed.append(info)
            }
        }
        let last = jobs[jobs.count - 1]
        let noCtx = jobs.contains { $0.noCtx }
        let ignoreCap = jobs.contains { $0.reason == .flush || $0.reason == .fatal || $0.reason == .shutdown }
        let before = batchesWritten
        materialize(cur, targetOseq: last.oseqAtSeal, targetSeq: last.seqAtSeal, noCtx: noCtx, ignoreCap: ignoreCap)
        flushTombstones()
        evictIfNeeded()
        return batchesWritten != before
    }

    // MARK: 墓碑（drops.jsonl：追加写，上限 1000 条超出按 reason 合并）

    func lastAckAge(_ at: Int64) -> Int64 {
        backoff.lastAckMs < 0 ? -1 : max(0, at - backoff.lastAckMs)
    }

    /// 写入侧的 write_failed 墓碑：可写时落盘。
    func flushTombstones() {
        let failed = writer.takeFailed()
        guard !failed.isEmpty, let cur = current else { return }
        let entries = failed.map {
            DropEntry(sessionId: cur.meta.sessionId, oseqFrom: $0.from, oseqTo: $0.to, n: $0.n,
                      reason: DropReason.writeFailed.rawValue, atMs: $0.atMs, lastAckAgeMs: lastAckAge($0.atMs))
        }
        if !appendDrops(entries) { writer.putBackFailed(failed) }
    }

    @discardableResult
    func appendDrops(_ entries: [DropEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return FS.withDirLock(root) {
            guard FS.append(dropsURL, JSONL.encodeDrops(entries)) else { return false }
            let all = readDropsLocked()
            if all.count > ClientConstants.dropsFileMaxEntries {
                // 已嵌进出站箱批次的条目原样保留（2xx 后按原样删除），其余合并
                let embedded = all.filter { embeddedDrops.contains($0) }
                let rest = all.filter { !embeddedDrops.contains($0) }
                let merged = Engine.mergeDrops(rest, limit: max(1, ClientConstants.dropsFileMaxEntries - embedded.count))
                FS.writeAtomic(dropsURL, JSONL.encodeDrops(embedded + merged))
            }
            return true
        }
    }

    func readDropsLocked() -> [DropEntry] {
        JSONL.read(dropsURL).compactMap(DropEntry.decode)
    }

    func readClosedLocked() -> [ClosedSession] {
        JSONL.read(sessionsURL).compactMap(ClosedSession.decode)
    }

    /// 按 reason 合并计数：先按 (session_id, reason) 合并区间，仍超限再按 reason 合并。
    static func mergeDrops(_ entries: [DropEntry], limit: Int) -> [DropEntry] {
        if entries.count <= limit { return entries }
        func merge(_ es: [DropEntry], key: (DropEntry) -> String) -> [DropEntry] {
            var order: [String] = []
            var acc: [String: DropEntry] = [:]
            for e in es {
                let k = key(e)
                if var m = acc[k] {
                    m.oseqFrom = min(m.oseqFrom, e.oseqFrom)
                    m.oseqTo = max(m.oseqTo, e.oseqTo)
                    m.n += e.n
                    m.atMs = max(m.atMs, e.atMs)
                    m.lastAckAgeMs = max(m.lastAckAgeMs, e.lastAckAgeMs)
                    acc[k] = m
                } else {
                    acc[k] = e
                    order.append(k)
                }
            }
            return order.map { acc[$0]! }
        }
        let bySession = merge(entries) { "\($0.sessionId)|\($0.reason)" }
        if bySession.count <= limit { return bySession }
        return merge(bySession) { $0.reason }
    }

    // MARK: 杂项

    func isAcked(sessionId: String, oseq: Int64) -> Bool {
        ackedRanges.contains { $0.sessionId == sessionId && $0.from <= oseq && oseq <= $0.to }
    }

    static func digest(_ d: Device) -> String {
        var o = JSONOut()
        d.encode(into: &o)
        let h = SHA256.hash(data: o.bytes)
        return h.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func todayBatches(now: Int64) -> Int {
        let d = Day.fromMs(now)
        if d != todayDay { todayDay = d; todayCount = 0 }
        return todayCount
    }

    func countBatch(now: Int64) {
        _ = todayBatches(now: now)
        todayCount += 1
    }

    /// 所有自己进程目录里的会话记录（当前 + 旧）。
    var ownSessions: [SessionRecord] {
        var out: [SessionRecord] = []
        if let c = current { out.append(c) }
        out.append(contentsOf: others.values.sorted { $0.meta.sessionNo < $1.meta.sessionNo })
        return out
    }
}

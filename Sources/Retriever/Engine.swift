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
    /// 上次拉配置的**尝试**时刻（单调）：请求发起时记一次，响应回来再记一次。
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
    /// 本进程内存开关（work 队列上的副本：调度、恢复合成行用）；上传 / 拉配置的决策读写入侧的开关并看盘上标记（`uploadAllowed`）。
    var enabled = true
    var previousAppVersion: String?
    var protectedDataUnavailable = false
    /// 禁用标记：root **同级**的空文件 `<root>.disabled`，存在 = 禁用（ADR 0020 决定 2）。
    /// 放在 root 外面，清空 root 不可能顺手把它带走；多进程共享。
    let disabledMarkerURL: URL

    init(root: URL, processName: String, key: String, baseURL: URL, options: Options,
         clock: any Clock, platform: any PlatformHooks, writer: Writer) {
        self.root = root
        self.procDir = root.appendingPathComponent("proc-\(processName)")
        self.outboxDir = root.appendingPathComponent("outbox")
        self.disabledMarkerURL = Engine.sibling(of: root, suffix: ".disabled")
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

    /// root 同级的路径：`<root> + suffix`（禁用标记 `.disabled`、清空中的 `.purge-<uuid>`）。
    static func sibling(of root: URL, suffix: String) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + suffix)
    }

    /// 上传 / 拉配置的开关 = 本进程内存开关 ∧ 盘上没有禁用标记（每次决策 stat 一次；别的进程写的标记下一次决策就看到）。
    /// 内存开关读写入侧那一个（setEnabled 在调用线程上同步改它）：`enabled` 副本要等 work 队列轮到才对齐，
    /// 排在它前面的取批 / 拉配置不能按滞后的「启用」发出请求。
    func uploadAllowed() -> Bool {
        writer.isEnabled && !FS.exists(disabledMarkerURL)
    }

    // MARK: 启动（同步：log() 在 init 返回后立即可用）

    /// install.json 的读改写结果。
    struct InstallOutcome {
        var install: InstallInfo
        var sessionNo: Int64
        /// 刚从会话 meta 修复了身份。
        var repaired: Bool
        /// install.json 损坏且没有任何带 install_id 的 meta：容器无法归属，已清空后新建（作废的出站箱批数 / 会话目录数）。
        var discarded: (batches: Int, sessions: Int)?
    }

    /// 建目录、install.json（首次生成 O_EXCL 临时文件 → fsync → rename，失败方重读；损坏则从会话 meta 修复身份，
    /// 无副本则清空后新建，均留痕）、计数器 +1、新会话。
    @discardableResult
    func bootstrap() -> Bool {
        guard FS.ensureDir(root), FS.ensureDir(procDir), FS.ensureDir(outboxDir) else { return false }
        FS.excludeFromBackup(root)
        guard let outcome = FS.withDirLock(root, { bumpInstallLocked() }) else { return false }
        let inst = outcome.install
        install = inst
        let now = clock.wallMs()
        let sid = IDs.newV4()
        let dir = procDir.appendingPathComponent(sid)
        guard FS.ensureDir(dir) else { return false }
        lockSessionDir(dir)
        let meta = SessionMeta(sessionId: sid, sessionNo: outcome.sessionNo, startedMs: now, device: device, process: processName,
                               installId: inst.installId)
        FS.writeAtomic(dir.appendingPathComponent("meta.json"), meta.encode())
        let cursor = Cursor(lastState: platform.isForeground().map { $0 ? "fg" : "bg" }, lastStateMs: now)
        let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: [])
        current = rec
        writeCursor(rec)
        writer.startSession(dir: dir, sessionId: sid)
        loadPersistentState()
        // install.json 出过事：新会话里留一条合成行（同 rtv.flush 的合成机制），排障时看得见
        if outcome.repaired {
            appendSynthetic(now: now, tag: "rtv.install_repaired", msg: "install.json unreadable; identity repaired from session meta")
        }
        if let d = outcome.discarded {
            appendSynthetic(now: now, tag: "rtv.install_reset", msg: "install.json unreadable; local state discarded",
                            attrs: ["batches": .int(Int64(d.batches)), "sessions": .int(Int64(d.sessions))])
        }
        return true
    }

    private func appendSynthetic(now: Int64, tag: String, msg: String, attrs: [String: AttrValue]? = nil) {
        let enc = LineEncoder.encode(LogLine(ts: now, level: .warn, msg: msg, tag: tag, attrs: attrs), synthetic: true)
        _ = writer.append(level: .warn, body: enc.body)
    }

    /// 清空（ADR 0019 决定 9）的第一步：把整个 root 改名为同级的 `<root>.purge-<uuid>`（一步原子：新旧状态不可能混用），
    /// 之后的递归删除只碰改过名的目录。改名后、删完前被杀：root 已不存在，下次 bootstrap 建新 root，残留由 `removePurgeLeftovers` 清掉。
    /// 返回改名后的目录；改名失败返回 nil（root 原样还在）。
    func moveRootAside() -> URL? {
        let dst = Engine.sibling(of: root, suffix: ".purge-" + IDs.newV4())
        return rename(root.path, dst.path) == 0 ? dst : nil
    }

    /// 启动时清掉清空中途被杀留下的 `<root>.purge-*`（work 队列上，不占宿主线程）。
    func removePurgeLeftovers() {
        let parent = root.deletingLastPathComponent()
        let prefix = root.lastPathComponent + ".purge-"
        for name in FS.list(parent) where name.hasPrefix(prefix) {
            FS.remove(parent.appendingPathComponent(name))
        }
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

    /// install.json 读改写（调用方持有 root 目录锁）；nil = 本次失败、稍后 retryBootstrap。
    private func bumpInstallLocked() -> InstallOutcome? {
        var inst: InstallInfo
        var repaired = false
        var discarded: (batches: Int, sessions: Int)?
        if let b = FS.read(installURL) {
            if let i = InstallInfo.decode(b) {
                inst = i
            } else {
                // 读到了（含 0 字节）却解析不了 = 损坏。读不全（大小对不上）不算损坏，按读失败处理
                guard Int64(b.count) == FS.size(installURL) else { return nil }
                // install_id 是「这一份数据容器」的身份，单个文件损坏不改变容器：从会话 meta 的冗余副本修复、不换 id，
                // 其余状态全部继续有效（ADR 0019 决定 7）。扫描本身失败（有 meta 读不了等）→ 本次失败，绝不重建
                guard let evidence = scanIdentityLocked() else { return nil }
                if let (id, counter, created) = evidence.identity {
                    // created_ms 取该 id 下最早会话的 started_ms（与 Android 同口径；本地字段，不上传）
                    inst = InstallInfo(installId: id, sessionCounter: counter, createdMs: created)
                    repaired = true
                } else {
                    // 无副本（只在 0.1.x 升上来的首次启动恰逢损坏时可达）：清空后在空 root 里新建 install（ADR 0019 决定 8 / 9）
                    guard discardRootLocked(), let created = createInstallLocked() else { return nil }
                    inst = created
                    discarded = (evidence.batches, evidence.sessions)
                }
            }
        } else {
            // 读不到：不存在则创建；存在但读不了（首次解锁前 / 权限）则本次失败、稍后 retryBootstrap——
            // 绝不在这里重建，否则首次解锁前启动会换掉 install_id
            guard let created = createInstallLocked() else { return nil }
            inst = created
        }
        inst.sessionCounter += 1
        guard FS.writeAtomic(installURL, inst.encode()) else { return nil }
        return InstallOutcome(install: inst, sessionNo: inst.sessionCounter, repaired: repaired, discarded: discarded)
    }

    /// 无副本时的清空（ADR 0019 决定 8 / 9，与 purgeLocal 同为「先改名再删」）：在 root 目录锁内把 root 改名移走、重建空目录，
    /// 不与另一进程的 bootstrap 交错。改走的旧 root 由随后的 startup（work 队列）的 `removePurgeLeftovers` 删，不占宿主线程。
    /// 调用方持有 root 目录锁。
    private func discardRootLocked() -> Bool {
        guard moveRootAside() != nil, FS.ensureDir(root), FS.ensureDir(procDir), FS.ensureDir(outboxDir) else { return false }
        FS.excludeFromBackup(root)
        return true
    }

    /// install.json 损坏时的身份证据（ADR 0019 决定 7 / 8）：扫全部 `proc-*/<sid>/meta.json`，取 `started_ms` 最大且带
    /// `install_id` 的那个 id，会话计数器 = 该 id 下最大的 `session_no`；顺带数出作废时要写进合成行的出站箱批数与会话目录数。
    /// 目录列不出、有 meta 存在却读不了 → nil（同「install.json 读不了」）。调用方持有 root 目录锁。
    private func scanIdentityLocked() -> (identity: (String, Int64, Int64)?, batches: Int, sessions: Int)? {
        guard let procs = FS.listStrict(root) else { return nil }
        var latest: SessionMeta?
        var maxNo: [String: Int64] = [:]
        var minStarted: [String: Int64] = [:]
        var sessions = 0
        for p in procs where p.hasPrefix("proc-") {
            let pdir = root.appendingPathComponent(p)
            guard let sids = FS.listStrict(pdir) else { return nil }
            for sid in sids where IDs.isUuid(sid) {
                sessions += 1
                let url = pdir.appendingPathComponent(sid).appendingPathComponent("meta.json")
                if access(url.path, F_OK) != 0 {
                    if errno == ENOENT { continue }
                    return nil
                }
                // 读不全（读到一半出错，FS.read 交回截短的缓冲）同读不了：截短的 meta 会被当成「解析不了」跳过，误判无副本而清空
                guard let b = FS.read(url), Int64(b.count) == FS.size(url) else { return nil }
                // 解析不了 / 0.1.x 写的无 install_id 的 meta：不当副本
                guard let m = SessionMeta.decode(b), let iid = m.installId else { continue }
                maxNo[iid] = max(maxNo[iid] ?? 0, m.sessionNo)
                minStarted[iid] = min(minStarted[iid] ?? Int64.max, m.startedMs)
                if latest == nil || m.startedMs > latest!.startedMs { latest = m }
            }
        }
        let batches = FS.list(outboxDir).filter { OutboxName.parse($0) != nil }.count
        let identity = latest.flatMap { m in m.installId.map { ($0, maxNo[$0] ?? m.sessionNo, minStarted[$0] ?? m.startedMs) } }
        return (identity, batches, sessions)
    }

    /// 新 install（新 install_id、计数器 0）：O_EXCL 临时文件 → fsync → rename；目标已存在就放弃（并发的另一方已写）。
    /// 调用方持有 root 目录锁。
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

    // MARK: 墓碑与会话终态（drops.jsonl / sessions.jsonl：追加写，各自上限 1000 条；ADR 0019 决定 3 / 4）

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

    /// 追加墓碑；文件超过上限先无损合并，仍超出删最旧的未在途条目（服务端显示为无解释缺口，大声方向）。
    @discardableResult
    func appendDrops(_ entries: [DropEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return FS.withDirLock(root) {
            guard FS.append(dropsURL, JSONL.encodeDrops(entries)) else { return false }
            let all = readDropsLocked()
            if all.count > ClientConstants.dropsFileMaxEntries {
                let merged = Engine.mergeDropsLossless(all, keep: embeddedDrops)
                FS.writeAtomic(dropsURL, JSONL.encodeDrops(
                    Engine.dropOldest(merged, over: ClientConstants.dropsFileMaxEntries) { embeddedDrops.contains($0) }))
            }
            return true
        }
    }

    /// 追加一条会话终态；文件超过上限删最旧的未在途条目（这些会话在服务端归 unknown，不误报）。
    @discardableResult
    func appendClosed(_ c: ClosedSession) -> Bool {
        FS.withDirLock(root) {
            guard FS.append(sessionsURL, JSONL.encodeClosed([c])) else { return false }
            let all = readClosedLocked()
            if all.count > ClientConstants.sessionsFileMaxEntries {
                FS.writeAtomic(sessionsURL, JSONL.encodeClosed(
                    Engine.dropOldest(all, over: ClientConstants.sessionsFileMaxEntries) { embeddedClosed.contains($0.sessionId) }))
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

    /// 超出 limit 时按文件顺序删最旧的条目；在途（已嵌进出站箱批次、2xx 后按原样删除）的不删。
    static func dropOldest<T>(_ entries: [T], over limit: Int, inFlight: (T) -> Bool) -> [T] {
        var excess = entries.count - limit
        guard excess > 0 else { return entries }
        var out: [T] = []
        out.reserveCapacity(limit)
        for e in entries {
            if excess > 0 && !inFlight(e) {
                excess -= 1
                continue
            }
            out.append(e)
        }
        return out
    }

    /// 无损合并（ADR 0019 决定 4）：同会话、同 reason、区间相接或重叠的并成一条，n = 并集长度；`backfill_evicted` 同会话 n 相加。
    /// 保持不变式「每条非 backfill 墓碑 n == oseq_to − oseq_from + 1、session_id 是真实归属」：并宽只发生在真的相接处，
    /// 绝不盖住缺口。在途条目与不满足该不变式的旧条目（0.1.x 有损合并留下的）原样保留、不参与合并。
    /// 合并出的条目放在它最早一个成员的位置，其余条目保持文件顺序。
    static func mergeDropsLossless(_ entries: [DropEntry], keep: Set<DropEntry>) -> [DropEntry] {
        let backfill = DropReason.backfillEvicted.rawValue
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for (i, e) in entries.enumerated() where !keep.contains(e) {
            guard e.reason == backfill || (e.oseqFrom >= 1 && e.n == e.oseqTo - e.oseqFrom + 1) else { continue }
            let k = "\(e.sessionId)|\(e.reason)"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        var placed: [Int: [DropEntry]] = [:]
        var absorbed = Set<Int>()
        func fold(_ members: [Int], _ make: (DropEntry) -> DropEntry) {
            guard members.count > 1 else { return }
            var m = entries[members[0]]
            for i in members.dropFirst() {
                m.atMs = max(m.atMs, entries[i].atMs)
                m.lastAckAgeMs = max(m.lastAckAgeMs, entries[i].lastAckAgeMs)
            }
            let at = members.min()!
            placed[at, default: []].append(make(m))
            absorbed.formUnion(members)
        }
        for k in order {
            let idx = groups[k]!
            if entries[idx[0]].reason == backfill {
                let total = idx.reduce(Int64(0)) { $0 + entries[$1].n }
                fold(idx) { var m = $0; m.n = total; return m }
                continue
            }
            let sorted = idx.sorted { (entries[$0].oseqFrom, entries[$0].oseqTo) < (entries[$1].oseqFrom, entries[$1].oseqTo) }
            var run: [Int] = []
            var from: Int64 = 0
            var to: Int64 = 0
            func flush() {
                let (f, t) = (from, to)
                fold(run) { var m = $0; m.oseqFrom = f; m.oseqTo = t; m.n = t - f + 1; return m }
            }
            for i in sorted {
                let e = entries[i]
                if !run.isEmpty && e.oseqFrom <= to + 1 {
                    to = max(to, e.oseqTo)
                    run.append(i)
                } else {
                    if !run.isEmpty { flush() }
                    run = [i]
                    from = e.oseqFrom
                    to = e.oseqTo
                }
            }
            if !run.isEmpty { flush() }
        }
        var out: [DropEntry] = []
        for (i, e) in entries.enumerated() {
            if let ms = placed[i] { out.append(contentsOf: ms) }
            if !absorbed.contains(i) { out.append(e) }
        }
        return out
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

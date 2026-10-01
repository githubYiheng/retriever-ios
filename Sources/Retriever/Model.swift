import Foundation

// 本地状态文件与信封的数据模型（§3.2 / §3.5 / §3.6；字段名与顺序取 packages/core/src/envelope.ts）。

/// install.json：{install_id, session_counter, created_ms}
struct InstallInfo: Equatable {
    var installId: String
    var sessionCounter: Int64
    var createdMs: Int64

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"install_id\":"); o.string(installId)
        o.raw(",\"session_counter\":"); o.int(sessionCounter)
        o.raw(",\"created_ms\":"); o.int(createdMs)
        o.raw("}")
        return o.bytes
    }

    static func decode(_ b: [UInt8]) -> InstallInfo? {
        guard let o = JSONIn.object(b), let id = o["install_id"] as? String, IDs.isUuid(id) else { return nil }
        return InstallInfo(installId: id, sessionCounter: JSONIn.int64(o["session_counter"]) ?? 0,
                           createdMs: JSONIn.int64(o["created_ms"]) ?? 0)
    }
}

/// meta.json：会话开始时原子写。
/// `install_id`（可选键，ADR 0019 决定 6）：bootstrap 时的 install 身份冗余副本，install.json 损坏时据此修复；
/// 0.1.x 写的 meta 没有这个键（照读，只是不当副本），旧 SDK 读新文件忽略它。
struct SessionMeta: Equatable {
    var sessionId: String
    var sessionNo: Int64
    var startedMs: Int64
    var device: Device
    var process: String
    var installId: String?

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"session_id\":"); o.string(sessionId)
        o.raw(",\"session_no\":"); o.int(sessionNo)
        o.raw(",\"started_ms\":"); o.int(startedMs)
        o.raw(",\"device\":"); device.encode(into: &o)
        o.raw(",\"process\":"); o.string(process)
        if let i = installId { o.raw(",\"install_id\":"); o.string(i) }
        o.raw("}")
        return o.bytes
    }

    static func decode(_ b: [UInt8]) -> SessionMeta? {
        guard let o = JSONIn.object(b), let sid = o["session_id"] as? String, IDs.isUuid(sid),
              let no = JSONIn.int64(o["session_no"]), no >= 1,
              let dev = Device.decode(o["device"]) else { return nil }
        return SessionMeta(sessionId: sid, sessionNo: no, startedMs: JSONIn.int64(o["started_ms"]) ?? 0,
                           device: dev, process: (o["process"] as? String) ?? "main",
                           installId: (o["install_id"] as? String).flatMap { IDs.isUuid($0) ? $0 : nil })
    }
}

/// cursor.json：{extracted_through_oseq, ctx_through_seq, last_state: fg|bg, last_state_ms}（原子写）。
/// `closed_ms`：恢复流程把旧会话终态写进 sessions.jsonl 之后打的「已结束」标记（方案布局未列，见实现报告）。
struct Cursor: Equatable {
    var extractedThroughOseq: Int64 = 0
    var ctxThroughSeq: Int64 = 0
    var lastState: String? = nil
    var lastStateMs: Int64 = 0
    var closedMs: Int64? = nil

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"extracted_through_oseq\":"); o.int(extractedThroughOseq)
        o.raw(",\"ctx_through_seq\":"); o.int(ctxThroughSeq)
        o.raw(",\"last_state\":"); o.stringOrNull(lastState)
        o.raw(",\"last_state_ms\":"); o.int(lastStateMs)
        if let c = closedMs { o.raw(",\"closed_ms\":"); o.int(c) }
        o.raw("}")
        return o.bytes
    }

    static func decode(_ b: [UInt8]) -> Cursor? {
        guard let o = JSONIn.object(b) else { return nil }
        return Cursor(extractedThroughOseq: JSONIn.int64(o["extracted_through_oseq"]) ?? 0,
                      ctxThroughSeq: JSONIn.int64(o["ctx_through_seq"]) ?? 0,
                      lastState: o["last_state"] as? String,
                      lastStateMs: JSONIn.int64(o["last_state_ms"]) ?? 0,
                      closedMs: JSONIn.int64(o["closed_ms"]))
    }
}

/// 一个段的索引（封段时由写入侧统计；恢复 / 旧会话由读文件重建）。
struct SegInfo {
    var segNo: Int
    var userId: String?
    var startedMs: Int64
    var firstSeq: Int64 = 0
    var lastSeq: Int64 = 0
    var firstOseq: Int64 = 0
    var lastOseq: Int64 = 0
    var lineCount: Int = 0
    var obligCount: Int = 0
    var hasError: Bool = false
    var bytes: Int64 = 0
    var url: URL

    static func from(_ f: SegmentFile, url: URL) -> SegInfo {
        var s = SegInfo(segNo: f.segNo, userId: f.header?.userId, startedMs: f.header?.startedMs ?? 0, url: url)
        for l in f.lines {
            if s.firstSeq == 0 { s.firstSeq = l.seq }
            s.lastSeq = max(s.lastSeq, l.seq)
            s.lineCount += 1
            if l.oseq > 0 {
                if s.firstOseq == 0 { s.firstOseq = l.oseq }
                s.lastOseq = max(s.lastOseq, l.oseq)
                s.obligCount += 1
                if l.levelRank >= LogLevel.error.rank { s.hasError = true }
            }
        }
        s.bytes = Int64(f.data.count)
        return s
    }
}

enum SealReason: String {
    case size, user, background, error, fatal, timer, flush, fullDump, uploadEnabled, shutdown, recovery
}

/// 封段任务：锁内换段时生成，work 队列里 fsync + rename + 物化。
struct SealJob {
    var fd: Int32
    var info: SegInfo
    var reason: SealReason
    /// flush(includeContext: false)：本次物化不附 ctx。
    var noCtx: Bool
    /// 换段时刻的全局 seq / oseq（物化的上界）。
    var seqAtSeal: Int64
    var oseqAtSeal: Int64
}

enum DropReason: String {
    case bufferOverflow = "buffer_overflow"
    case writeFailed = "write_failed"
    case corrupt
    case backfillEvicted = "backfill_evicted"
    case quarantineEvicted = "quarantine_evicted"
}

/// 墓碑：{session_id, oseq_from, oseq_to, n, reason, at_ms, last_ack_age_ms}
struct DropEntry: Hashable {
    var sessionId: String
    var oseqFrom: Int64
    var oseqTo: Int64
    var n: Int64
    var reason: String
    var atMs: Int64
    var lastAckAgeMs: Int64

    func encode(into o: inout JSONOut) {
        o.raw("{\"session_id\":"); o.string(sessionId)
        o.raw(",\"oseq_from\":"); o.int(oseqFrom)
        o.raw(",\"oseq_to\":"); o.int(oseqTo)
        o.raw(",\"n\":"); o.int(n)
        o.raw(",\"reason\":"); o.string(reason)
        o.raw(",\"at_ms\":"); o.int(atMs)
        o.raw(",\"last_ack_age_ms\":"); o.int(lastAckAgeMs)
        o.raw("}")
    }

    static func decode(_ v: Any?) -> DropEntry? {
        guard let o = v as? [String: Any], let sid = o["session_id"] as? String, let r = o["reason"] as? String,
              let f = JSONIn.int64(o["oseq_from"]), let t = JSONIn.int64(o["oseq_to"]), let n = JSONIn.int64(o["n"]) else { return nil }
        return DropEntry(sessionId: sid, oseqFrom: f, oseqTo: t, n: n, reason: r, atMs: JSONIn.int64(o["at_ms"]) ?? 0,
                         lastAckAgeMs: JSONIn.int64(o["last_ack_age_ms"]) ?? -1)
    }
}

enum SessionExit: String { case cleanBg = "clean_bg", uncleanFg = "unclean_fg", unknown }

/// 会话终态：{session_id, session_no, started_ms, ended_ms, last_seq, last_oseq, exit}
struct ClosedSession: Hashable {
    var sessionId: String
    var sessionNo: Int64
    var startedMs: Int64
    var endedMs: Int64
    var lastSeq: Int64
    var lastOseq: Int64
    var exit: String

    func encode(into o: inout JSONOut) {
        o.raw("{\"session_id\":"); o.string(sessionId)
        o.raw(",\"session_no\":"); o.int(sessionNo)
        o.raw(",\"started_ms\":"); o.int(startedMs)
        o.raw(",\"ended_ms\":"); o.int(endedMs)
        o.raw(",\"last_seq\":"); o.int(lastSeq)
        o.raw(",\"last_oseq\":"); o.int(lastOseq)
        o.raw(",\"exit\":"); o.string(exit)
        o.raw("}")
    }

    static func decode(_ v: Any?) -> ClosedSession? {
        guard let o = v as? [String: Any], let sid = o["session_id"] as? String, let no = JSONIn.int64(o["session_no"]),
              let ex = o["exit"] as? String else { return nil }
        return ClosedSession(sessionId: sid, sessionNo: no, startedMs: JSONIn.int64(o["started_ms"]) ?? 0,
                             endedMs: JSONIn.int64(o["ended_ms"]) ?? 0, lastSeq: JSONIn.int64(o["last_seq"]) ?? 0,
                             lastOseq: JSONIn.int64(o["last_oseq"]) ?? 0, exit: ex)
    }
}

/// jsonl 文件（drops.jsonl / sessions.jsonl）的读写。
enum JSONL {
    static func read(_ url: URL) -> [[String: Any]] {
        guard let b = FS.read(url), !b.isEmpty else { return [] }
        var out: [[String: Any]] = []
        var start = 0
        for i in 0..<b.count where b[i] == 0x0A {
            if i > start, let o = JSONIn.object(Array(b[start..<i])) { out.append(o) }
            start = i + 1
        }
        return out
    }

    static func encodeDrops(_ d: [DropEntry]) -> [UInt8] {
        var o = JSONOut()
        for e in d { e.encode(into: &o); o.raw("\n") }
        return o.bytes
    }

    static func encodeClosed(_ c: [ClosedSession]) -> [UInt8] {
        var o = JSONOut()
        for e in c { e.encode(into: &o); o.raw("\n") }
        return o.bytes
    }
}

/// mapping.json：{user_id, device_digest, acked_ms}（上次被服务端确认的映射）
struct MappingState: Equatable {
    var userId: String?
    var deviceDigest: String
    var ackedMs: Int64

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"user_id\":"); o.stringOrNull(userId)
        o.raw(",\"device_digest\":"); o.string(deviceDigest)
        o.raw(",\"acked_ms\":"); o.int(ackedMs)
        o.raw("}")
        return o.bytes
    }

    static func decode(_ b: [UInt8]) -> MappingState? {
        guard let o = JSONIn.object(b), let d = o["device_digest"] as? String else { return nil }
        return MappingState(userId: o["user_id"] as? String, deviceDigest: d, ackedMs: JSONIn.int64(o["acked_ms"]) ?? 0)
    }
}

/// 信封头（lines 之前的全部字段），字段顺序取 envelope.ts 的 Envelope。
struct EnvelopeHeader {
    var kind: IDs.BatchKind
    var batchId: String
    var createdMs: Int64
    var day: String
    var installId: String
    var sessionId: String
    var sessionNo: Int64
    var process: String
    var userId: String?
    var device: Device
    var seqFrom: Int64
    var seqTo: Int64
    var oseqFrom: Int64?
    var oseqTo: Int64?
    var ctxTruncated: Int64?
    var drops: [DropEntry] = []
    var closedSessions: [ClosedSession] = []
    /// 本版不再产生（终态带不完留给下一批，ADR 0019 决定 2）；只为 413 切分 0.1.x 留在出站箱的旧批时原样转交。
    var closedSessionsDropped: Int64 = 0
    var mapping: (userId: String?, device: Device)? = nil

    /// 输出到 `"lines":[` 为止（含）。
    func encodePrefix() -> [UInt8] {
        var o = JSONOut(capacity: 1024)
        o.raw("{\"v\":1,\"kind\":"); o.string(kind.rawValue)
        o.raw(",\"batch_id\":"); o.string(batchId)
        o.raw(",\"created_ms\":"); o.int(createdMs)
        o.raw(",\"day\":"); o.string(day)
        o.raw(",\"install_id\":"); o.string(installId)
        o.raw(",\"session_id\":"); o.string(sessionId)
        o.raw(",\"session_no\":"); o.int(sessionNo)
        o.raw(",\"process\":"); o.string(process)
        o.raw(",\"user_id\":"); o.stringOrNull(userId)
        o.raw(",\"device\":"); device.encode(into: &o)
        o.raw(",\"seq_from\":"); o.int(seqFrom)
        o.raw(",\"seq_to\":"); o.int(seqTo)
        if let f = oseqFrom, let t = oseqTo {
            o.raw(",\"oseq_from\":"); o.int(f)
            o.raw(",\"oseq_to\":"); o.int(t)
        }
        if let c = ctxTruncated { o.raw(",\"ctx_truncated\":"); o.int(c) }
        if !drops.isEmpty {
            o.raw(",\"drops\":[")
            for (i, d) in drops.enumerated() { if i > 0 { o.raw(",") }; d.encode(into: &o) }
            o.raw("]")
        }
        if !closedSessions.isEmpty {
            o.raw(",\"closed_sessions\":[")
            for (i, c) in closedSessions.enumerated() { if i > 0 { o.raw(",") }; c.encode(into: &o) }
            o.raw("]")
        }
        if closedSessionsDropped > 0 { o.raw(",\"closed_sessions_dropped\":"); o.int(closedSessionsDropped) }
        if let m = mapping {
            o.raw(",\"mapping\":{\"user_id\":"); o.stringOrNull(m.userId)
            o.raw(",\"device\":"); m.device.encode(into: &o)
            o.raw("}")
        }
        o.raw(",\"lines\":[")
        return o.bytes
    }

    /// 整个信封：头 + 行（逗号分隔）+ `]}`。
    func encode(lines: [[UInt8]]) -> [UInt8] {
        var out = encodePrefix()
        out.reserveCapacity(out.count + lines.reduce(0) { $0 + $1.count + 1 } + 2)
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(0x2C) }
            out.append(contentsOf: l)
        }
        out.append(0x5D)
        out.append(0x7D)
        return out
    }

    static func decode(_ o: [String: Any]) -> EnvelopeHeader? {
        guard let k = o["kind"] as? String, let kind = IDs.BatchKind(rawValue: k),
              let bid = o["batch_id"] as? String, let created = JSONIn.int64(o["created_ms"]),
              let day = o["day"] as? String, let iid = o["install_id"] as? String, let sid = o["session_id"] as? String,
              let sno = JSONIn.int64(o["session_no"]), let proc = o["process"] as? String,
              let dev = Device.decode(o["device"]) else { return nil }
        var h = EnvelopeHeader(kind: kind, batchId: bid, createdMs: created, day: day, installId: iid, sessionId: sid,
                               sessionNo: sno, process: proc, userId: o["user_id"] as? String, device: dev,
                               seqFrom: JSONIn.int64(o["seq_from"]) ?? 0, seqTo: JSONIn.int64(o["seq_to"]) ?? 0,
                               oseqFrom: JSONIn.int64(o["oseq_from"]), oseqTo: JSONIn.int64(o["oseq_to"]),
                               ctxTruncated: JSONIn.int64(o["ctx_truncated"]))
        h.drops = ((o["drops"] as? [Any]) ?? []).compactMap(DropEntry.decode)
        h.closedSessions = ((o["closed_sessions"] as? [Any]) ?? []).compactMap(ClosedSession.decode)
        h.closedSessionsDropped = JSONIn.int64(o["closed_sessions_dropped"]) ?? 0
        if let m = o["mapping"] as? [String: Any], let md = Device.decode(m["device"]) {
            h.mapping = (m["user_id"] as? String, md)
        }
        return h
    }
}

/// 出站箱批文件的元数据（物化时填入缓存；启动时解压扫描重建）。
struct BatchMeta {
    var name: String
    /// 0 / 1 / 2 = p0 / p1 / p2；3 = q
    var prio: Int
    var createdMs: Int64
    var batchId: String
    var kind: IDs.BatchKind
    /// 信封里的 install_id：请求头 `X-Rtv-Install` 用它（ADR 0019 决定 10）；读不出信封的兜底元数据为空 = 用当前值。
    var installId: String
    var sessionId: String
    var oseqFrom: Int64
    var oseqTo: Int64
    var lineCount: Int
    var hasWarnOrAbove: Bool
    var hasError: Bool
    var drops: [DropEntry]
    var closed: [ClosedSession]
    var mappingUser: String??
    var mappingDigest: String?
    var bytes: Int64

    /// 429 `["info","backfill"]` 暂停的类别：p2 = backfill；不含 warn 以上的 primary = info。
    var category: String? {
        if kind == .backfill { return "backfill" }
        return hasWarnOrAbove ? nil : "info"
    }
}

/// 出站箱文件名：`p{0|1|2}-<created_ms>-<batch_id>.gz` / `q-<created_ms>-<batch_id>.gz`。
enum OutboxName {
    static func make(prio: Int, createdMs: Int64, batchId: String) -> String {
        (prio >= 3 ? "q" : "p\(prio)") + "-\(createdMs)-\(batchId).gz"
    }

    static func parse(_ name: String) -> (prio: Int, createdMs: Int64, batchId: String)? {
        guard name.hasSuffix(".gz") else { return nil }
        let stem = name.dropLast(3)
        let parts = stem.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let created = Int64(parts[1]) else { return nil }
        let prio: Int
        switch parts[0] {
        case "p0": prio = 0
        case "p1": prio = 1
        case "p2": prio = 2
        case "q": prio = 3
        default: return nil
        }
        let bid = String(parts[2])
        guard IDs.isUuid(bid) else { return nil }
        return (prio, created, bid)
    }
}

/// backoff.json：{attempt, next_at_wall_ms, next_at_mono_ms, paused_until_ms, paused_categories, reason}
/// 另存 `last_ack_ms`（墓碑 last_ack_age_ms 需要跨启动的「上次 2xx」时刻；方案布局未列，见实现报告）。
struct BackoffState: Equatable {
    var attempt: Int = 0
    var nextAtWallMs: Int64 = 0
    var nextAtMonoMs: Int64 = 0
    var pausedUntilMs: Int64 = 0
    var pausedUntilMono: Int64 = 0
    var pausedCategories: [String] = []
    var reason: String = ""
    var lastAckMs: Int64 = -1

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"attempt\":"); o.int(attempt)
        o.raw(",\"next_at_wall_ms\":"); o.int(nextAtWallMs)
        o.raw(",\"next_at_mono_ms\":"); o.int(nextAtMonoMs)
        o.raw(",\"paused_until_ms\":"); o.int(pausedUntilMs)
        o.raw(",\"paused_categories\":[")
        for (i, c) in pausedCategories.enumerated() { if i > 0 { o.raw(",") }; o.string(c) }
        o.raw("],\"reason\":"); o.string(reason)
        o.raw(",\"last_ack_ms\":"); o.int(lastAckMs)
        o.raw("}")
        return o.bytes
    }

    /// 冷启动：单调时钟不跨进程，用墙钟换算；next_at 晚于 now + 15 min（时钟回拨）截断。
    static func decodeColdStart(_ b: [UInt8], nowWall: Int64, nowMono: Int64) -> BackoffState? {
        guard let o = JSONIn.object(b) else { return nil }
        var s = BackoffState()
        s.attempt = Int(JSONIn.int64(o["attempt"]) ?? 0)
        s.nextAtWallMs = JSONIn.int64(o["next_at_wall_ms"]) ?? 0
        s.pausedUntilMs = JSONIn.int64(o["paused_until_ms"]) ?? 0
        s.pausedCategories = (o["paused_categories"] as? [Any])?.compactMap { $0 as? String } ?? []
        s.reason = (o["reason"] as? String) ?? ""
        s.lastAckMs = JSONIn.int64(o["last_ack_ms"]) ?? -1
        let nextWait = min(max(s.nextAtWallMs - nowWall, 0), Limits.backoffMaxMs)
        s.nextAtWallMs = nextWait > 0 ? nowWall + nextWait : 0
        s.nextAtMonoMs = nextWait > 0 ? nowMono + nextWait : 0
        let pauseWait = min(max(s.pausedUntilMs - nowWall, 0), Limits.pause401MaxMs)
        s.pausedUntilMs = pauseWait > 0 ? nowWall + pauseWait : 0
        s.pausedUntilMono = pauseWait > 0 ? nowMono + pauseWait : 0
        if pauseWait == 0 { s.pausedCategories = [] }
        return s
    }
}

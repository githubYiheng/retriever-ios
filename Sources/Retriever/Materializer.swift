import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 批次物化（方案 §3.5）。
extension Engine {
    struct OLine {
        var seq: Int64
        var oseq: Int64
        var ts: Int64
        var rank: Int
        var raw: [UInt8]
    }

    struct Chunk {
        var user: String?
        var lines: [OLine] = []
        var bytes = 0
        var hasError = false
        var ctx: [OLine] = []
        var ctxTruncated: Int64?
        var extras = false
        var mapping = false
    }

    /// 义务行 = 本会话 oseq ∈ (extracted_through_oseq, targetOseq]，按 oseq 连续取走；
    /// 用户边界与 oseq 缺口（write_failed / 驱逐 / 损坏已记墓碑）处切批；解压后 ≤ 768 KB，超出按 oseq 切多批；
    /// 本批含 error / fatal（或 flush 要求）时附 ctx；没有义务行 → 不产生批次。
    func materialize(_ s: SessionRecord, targetOseq: Int64, targetSeq: Int64, forceCtx: Bool, ignoreCap: Bool) {
        let now = clock.wallMs()
        guard let inst = install else { return }
        var cache: [Int: SegmentFile] = [:]
        func load(_ info: SegInfo) -> SegmentFile? {
            if let f = cache[info.segNo] { return f }
            let f = Segments.read(info.url, validate: false)
            cache[info.segNo] = f
            return f
        }

        let from = s.cursor.extractedThroughOseq + 1
        var ob: [(OLine, String?)] = []
        if targetOseq >= from {
            for info in s.sealed where info.obligCount > 0 && info.lastOseq >= from && info.firstOseq <= targetOseq {
                guard let f = load(info) else { continue }
                for l in f.lines where l.oseq >= from && l.oseq <= targetOseq {
                    ob.append((OLine(seq: l.seq, oseq: l.oseq, ts: l.ts, rank: l.levelRank, raw: Array(f.data[l.range])), info.userId))
                }
            }
            ob.sort { $0.0.oseq < $1.0.oseq }
        }
        if ob.isEmpty {
            if targetOseq >= from {
                // 区间内的行都不在盘上（写失败 / 已驱逐，均已记墓碑）
                s.cursor.extractedThroughOseq = targetOseq
                writeCursor(s)
            }
            return
        }
        let hasError = ob.contains { $0.0.rank >= LogLevel.error.rank }
        let cap = effective.config.dailyBatchCap
        if !ignoreCap && !hasError && cap > 0 && todayBatches(now: now) >= cap {
            // daily_batch_cap：超出的 p1 合并到下一次封段（p0 不受限；日志不丢只是攒大包，ADR 0005）
            return
        }

        let budget = Limits.batchUncompressedBytesClient
        let isCurrent = s === current
        // 头部字节上限估计：用最大位数的数字占位，外加 extras 的真实字节
        func headerBytes(user: String?, extras: ([DropEntry], [ClosedSession], Int64)?, mapping: Bool) -> Int {
            var h = EnvelopeHeader(kind: .primary, batchId: IDs.namespace, createdMs: 9_999_999_999_999, day: "2026-09-29",
                                   installId: inst.installId, sessionId: s.meta.sessionId, sessionNo: s.meta.sessionNo,
                                   process: s.meta.process, userId: user, device: s.meta.device,
                                   seqFrom: 9_007_199_254_740_991, seqTo: 9_007_199_254_740_991,
                                   oseqFrom: 9_007_199_254_740_991, oseqTo: 9_007_199_254_740_991, ctxTruncated: 9_007_199_254_740_991)
            if let e = extras { h.drops = e.0; h.closedSessions = e.1; h.closedSessionsDropped = e.2 }
            if mapping { h.mapping = (user, s.meta.device) }
            return h.encodePrefix().count + 2
        }

        // extras（drops / closed_sessions）只随本次物化的第一批
        let extras = takeExtras()
        var chunks: [Chunk] = []
        var curChunk: Chunk? = nil
        var curHeader = 0
        var prevOseq: Int64 = -1
        var prevUser: String?? = .none
        var mappingPendingFor: (String?, String)? = nil
        func startChunk(user: String?) {
            var c = Chunk(user: user)
            c.extras = chunks.isEmpty && curChunk == nil
            let digest = Engine.digest(s.meta.device)
            if isCurrent && needMapping(user: user, digest: digest, now: now)
                && !(mappingPendingFor.map { $0.0 == user && $0.1 == digest } ?? false) {
                c.mapping = true
                mappingPendingFor = (user, digest)
            }
            curHeader = headerBytes(user: user, extras: c.extras ? extras : nil, mapping: c.mapping)
            curChunk = c
        }
        for (l, user) in ob {
            let cost = l.raw.count + 1
            let boundary = prevUser == .none || prevUser! != user || l.oseq != prevOseq + 1
            if curChunk == nil {
                startChunk(user: user)
            } else if boundary || curHeader + curChunk!.bytes + cost > budget {
                chunks.append(curChunk!)
                startChunk(user: user)
            }
            curChunk!.lines.append(l)
            curChunk!.bytes += cost
            if l.rank >= LogLevel.error.rank { curChunk!.hasError = true }
            prevOseq = l.oseq
            prevUser = .some(user)
        }
        if let c = curChunk { chunks.append(c) }

        // ctx：附在最后一个含 error 的批（flush 要求时附在最后一批）
        var ctxTarget: Int? = chunks.lastIndex { $0.hasError }
        if ctxTarget == nil && forceCtx { ctxTarget = chunks.count - 1 }
        if let t = ctxTarget {
            let user = chunks[t].user
            let hb = headerBytes(user: user, extras: chunks[t].extras ? extras : nil, mapping: chunks[t].mapping)
            let room = budget - hb - chunks[t].bytes
            let byteBudget = min(effective.config.contextBytes, room)
            let lineBudget = effective.config.contextLines
            var taken: [OLine] = []
            var takenBytes = 0
            var truncated: Int64 = 0
            var stop = false
            let through = s.cursor.ctxThroughSeq
            for info in s.sealed.reversed() {
                if info.lineCount == 0 || info.firstSeq > targetSeq { continue }
                if info.userId != user || info.lastSeq <= through { break }
                if info.lineCount == info.obligCount { continue }
                if stop && info.firstSeq > through && info.lastSeq <= targetSeq {
                    truncated += Int64(info.lineCount - info.obligCount)
                    continue
                }
                guard let f = load(info) else { continue }
                for l in f.lines.reversed() where l.oseq == 0 && l.seq > through && l.seq <= targetSeq {
                    if stop { truncated += 1; continue }
                    let raw = Segments.withCtx(f.data[l.range])
                    let cost = raw.count + 1
                    if taken.count < lineBudget && takenBytes + cost <= byteBudget {
                        taken.append(OLine(seq: l.seq, oseq: 0, ts: l.ts, rank: l.levelRank, raw: raw))
                        takenBytes += cost
                    } else {
                        stop = true
                        truncated += 1
                    }
                }
            }
            chunks[t].ctx = taken.reversed()
            chunks[t].ctxTruncated = truncated
            s.cursor.ctxThroughSeq = max(s.cursor.ctxThroughSeq, targetSeq)
        }

        // 写批：信封 JSON → gzip → outbox/tmp-* → fsync → rename（提交点）；全部成功后原子写 cursor
        var committedThrough = s.cursor.extractedThroughOseq
        var usedExtras = false
        for c in chunks {
            var all = c.lines
            if !c.ctx.isEmpty {
                all.append(contentsOf: c.ctx)
                all.sort { $0.seq < $1.seq }
            }
            let tsMin = all.map(\.ts).min() ?? now
            let oseqFrom = c.lines.first!.oseq
            guard let bid = IDs.batchId(installId: inst.installId, sessionId: s.meta.sessionId, kind: .primary, n: oseqFrom) else { break }
            var h = EnvelopeHeader(kind: .primary, batchId: bid, createdMs: now, day: Day.clientDay(tsMinMs: tsMin, createdMs: now),
                                   installId: inst.installId, sessionId: s.meta.sessionId, sessionNo: s.meta.sessionNo,
                                   process: s.meta.process, userId: c.user, device: s.meta.device,
                                   seqFrom: all.first!.seq, seqTo: all.last!.seq,
                                   oseqFrom: oseqFrom, oseqTo: c.lines.last!.oseq, ctxTruncated: c.ctxTruncated)
            if c.extras {
                h.drops = extras.0
                h.closedSessions = extras.1
                h.closedSessionsDropped = extras.2
                usedExtras = true
            }
            if c.mapping { h.mapping = (c.user, s.meta.device) }
            guard writeBatch(h, lines: all.map(\.raw), prio: c.hasError ? 0 : 1) != nil else {
                if c.extras { usedExtras = false }
                break
            }
            if c.mapping { pendingMapping = (c.user, Engine.digest(s.meta.device)) }
            countBatch(now: now)
            committedThrough = h.oseqTo!
        }
        if !usedExtras { releaseExtras(extras) }
        // 区间尾部若因缺口没有行，也视为已处理（墓碑已覆盖）
        if committedThrough == ob.last!.0.oseq { committedThrough = max(committedThrough, targetOseq) }
        s.cursor.extractedThroughOseq = committedThrough
        writeCursor(s)
    }

    /// 映射块：user_id 或设备摘要相对 mapping.json 变化、或距 acked_ms ≥ 24 h。
    func needMapping(user: String?, digest: String, now: Int64) -> Bool {
        if let p = pendingMapping, p.user == user, p.digest == digest { return false }
        guard let m = mapping else { return true }
        return m.userId != user || m.deviceDigest != digest || now - m.ackedMs >= Limits.mappingRefreshMs
    }

    /// 取本批要带的 drops（≤ 100，超出按 reason 合并）与 closed_sessions（≤ 20，更旧的合并为计数）。
    /// 条目留在 jsonl 里直到携带它的批 2xx；在途的用内存集合排除，避免重复携带。
    func takeExtras() -> ([DropEntry], [ClosedSession], Int64) {
        FS.withDirLock(root) {
            var drops = readDropsLocked()
            var avail = drops.filter { !embeddedDrops.contains($0) }
            if avail.count > Limits.dropsPerBatch {
                let merged = Engine.mergeDrops(avail, limit: Limits.dropsPerBatch)
                let embedded = drops.filter { embeddedDrops.contains($0) }
                drops = embedded + merged
                FS.writeAtomic(dropsURL, JSONL.encodeDrops(drops))
                avail = merged
            }
            let takeDrops = Array(avail.prefix(Limits.dropsPerBatch))
            embeddedDrops.formUnion(takeDrops)

            let closed = readClosedLocked()
            var availC = closed.filter { !embeddedClosed.contains($0.sessionId) }
            var dropped: Int64 = 0
            if availC.count > Limits.closedSessionsPerBatch {
                availC.sort { $0.endedMs < $1.endedMs }
                let older = availC.prefix(availC.count - Limits.closedSessionsPerBatch)
                dropped = Int64(older.count)
                let olderIds = Set(older.map(\.sessionId))
                FS.writeAtomic(sessionsURL, JSONL.encodeClosed(closed.filter { !olderIds.contains($0.sessionId) }))
                availC = Array(availC.suffix(Limits.closedSessionsPerBatch))
            }
            embeddedClosed.formUnion(availC.map(\.sessionId))
            return (takeDrops, availC, dropped)
        }
    }

    func releaseExtras(_ e: ([DropEntry], [ClosedSession], Int64)) {
        embeddedDrops.subtract(e.0)
        embeddedClosed.subtract(e.1.map(\.sessionId))
    }

    /// 写一个批文件；返回元数据（失败 nil，不留半成品：tmp 在失败时删除，启动时也清理）。
    @discardableResult
    func writeBatch(_ h: EnvelopeHeader, lines: [[UInt8]], prio: Int, replacing: String? = nil) -> BatchMeta? {
        let json = h.encode(lines: lines)
        guard let gz = Gzip.compress(json) else { return nil }
        let tmp = outboxDir.appendingPathComponent("tmp-\(processName)-\(IDs.newV4())")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        FS.protect(tmp)
        let ok = gz.withUnsafeBytes { FS.writeAll(fd, $0) } && fsync(fd) == 0
        close(fd)
        let name = OutboxName.make(prio: prio, createdMs: h.createdMs, batchId: h.batchId)
        let dest = outboxDir.appendingPathComponent(name)
        guard ok, rename(tmp.path, dest.path) == 0 else {
            unlink(tmp.path)
            return nil
        }
        FS.markFile(dest)
        let meta = Engine.meta(name: name, header: h, lines: lines, bytes: Int64(gz.count))
        metas[name] = meta
        batchesWritten += 1
        return meta
    }

    static let levelWarn = Array("\"level\":\"warn\"".utf8)
    static let levelError = Array("\"level\":\"error\"".utf8)
    static let levelFatal = Array("\"level\":\"fatal\"".utf8)
    static let ctxMark = Array(",\"ctx\":true".utf8)

    static func meta(name: String, header h: EnvelopeHeader, lines: [[UInt8]], bytes: Int64) -> BatchMeta {
        var warn = false
        var err = false
        for l in lines {
            let s = l[...]
            let e = Bytes.contains(levelError, in: s) || Bytes.contains(levelFatal, in: s)
            if e || Bytes.contains(levelWarn, in: s) { warn = true }
            if e && !Bytes.contains(ctxMark, in: s) { err = true }
        }
        let prio = OutboxName.parse(name)?.prio ?? 1
        return BatchMeta(name: name, prio: prio, createdMs: h.createdMs, batchId: h.batchId, kind: h.kind, sessionId: h.sessionId,
                         oseqFrom: h.oseqFrom ?? 0, oseqTo: h.oseqTo ?? 0, lineCount: lines.count, hasWarnOrAbove: warn,
                         hasError: err, drops: h.drops, closed: h.closedSessions,
                         mappingUser: h.mapping.map { .some($0.userId) } ?? .none,
                         mappingDigest: h.mapping.map { Engine.digest($0.device) }, bytes: bytes)
    }

    // MARK: backfill（full_dump 生效时；§3.5 / §5）

    /// 对 RETAINED 段中没有作为 ctx 上传过（seq > ctx_through_seq）的非义务行按段生成 backfill 批（p2，不带 oseq）。
    func materializeBackfill() {
        guard let inst = install else { return }
        let now = clock.wallMs()
        for s in ownSessions {
            var through = s.cursor.ctxThroughSeq
            for info in s.sealed where info.lastSeq > s.cursor.ctxThroughSeq {
                if info.lineCount == info.obligCount { through = max(through, info.lastSeq); continue }
                guard let f = Segments.read(info.url, validate: false) else { continue }
                var lines: [OLine] = f.lines.filter { $0.oseq == 0 && $0.seq > s.cursor.ctxThroughSeq }.map {
                    OLine(seq: $0.seq, oseq: 0, ts: $0.ts, rank: $0.levelRank, raw: Array(f.data[$0.range]))
                }
                if lines.isEmpty { through = max(through, info.lastSeq); continue }
                // 一个段 ≤ 512 KB + 一行，放得进 768 KB；保险起见超出时保留最新的
                var total = lines.reduce(0) { $0 + $1.raw.count + 1 } + 2048
                while total > Limits.batchUncompressedBytesClient && lines.count > 1 {
                    total -= lines.removeFirst().raw.count + 1
                }
                guard let bid = IDs.batchId(installId: inst.installId, sessionId: s.meta.sessionId, kind: .backfill, n: Int64(info.segNo)) else { continue }
                let h = EnvelopeHeader(kind: .backfill, batchId: bid, createdMs: now,
                                       day: Day.clientDay(tsMinMs: lines.map(\.ts).min() ?? now, createdMs: now),
                                       installId: inst.installId, sessionId: s.meta.sessionId, sessionNo: s.meta.sessionNo,
                                       process: s.meta.process, userId: info.userId, device: s.meta.device,
                                       seqFrom: lines.first!.seq, seqTo: lines.last!.seq, oseqFrom: nil, oseqTo: nil, ctxTruncated: nil)
                guard writeBatch(h, lines: lines.map(\.raw), prio: 2) != nil else { break }
                through = max(through, info.lastSeq)
            }
            if through > s.cursor.ctxThroughSeq {
                s.cursor.ctxThroughSeq = through
                writeCursor(s)
            }
        }
    }
}

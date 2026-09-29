import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 出站箱（§3.2 / §3.7 / §3.8）：元数据、驱逐、隔离、413 切分。
extension Engine {
    static let linesKey = Array("\"lines\":[".utf8)
    static let seqKey = Array("{\"seq\":".utf8)

    /// 解压并拆出信封头与行（行字节原样）。
    struct ParsedBatch {
        var header: EnvelopeHeader
        var lines: [[UInt8]]
    }

    static func parseBatch(_ gz: [UInt8]) -> ParsedBatch? {
        guard let json = Gzip.decompress(gz), let at = Bytes.find(linesKey, in: json) else { return nil }
        var headJSON = Array(json[0..<(at + linesKey.count)])
        headJSON.append(contentsOf: Array("]}".utf8))
        guard let o = JSONIn.object(headJSON), let h = EnvelopeHeader.decode(o) else { return nil }
        // 顶层行数组：按括号深度切（字符串内的括号 / 引号转义要跳过）
        var lines: [[UInt8]] = []
        var i = at + linesKey.count
        var depth = 0
        var inStr = false
        var esc = false
        var start = -1
        while i < json.count {
            let c = json[i]
            if inStr {
                if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { inStr = false }
            } else if c == 0x22 {
                inStr = true
            } else if c == 0x7B {
                if depth == 0 { start = i }
                depth += 1
            } else if c == 0x7D {
                depth -= 1
                if depth == 0 && start >= 0 { lines.append(Array(json[start...i])); start = -1 }
            } else if c == 0x5D && depth == 0 {
                break
            }
            i += 1
        }
        return ParsedBatch(header: h, lines: lines)
    }

    func loadMeta(_ name: String) -> BatchMeta? {
        let url = outboxDir.appendingPathComponent(name)
        guard let gz = FS.read(url), let p = Engine.parseBatch(gz) else { return nil }
        return Engine.meta(name: name, header: p.header, lines: p.lines, bytes: Int64(gz.count))
    }

    /// 与磁盘对齐（出站箱在多进程间共享）：新文件读元数据，消失的文件移出缓存。
    func reconcileOutbox() {
        var seen = Set<String>()
        for name in FS.list(outboxDir) {
            guard OutboxName.parse(name) != nil else { continue }
            seen.insert(name)
            if metas[name] == nil {
                if let m = loadMeta(name) {
                    metas[name] = m
                } else if let p = OutboxName.parse(name) {
                    // 读不出（位腐烂等）：保守当作含 warn 的 primary，交给服务端隔离
                    metas[name] = BatchMeta(name: name, prio: p.prio, createdMs: p.createdMs, batchId: p.batchId, kind: .primary,
                                            sessionId: "", oseqFrom: 0, oseqTo: 0, lineCount: 0, hasWarnOrAbove: true,
                                            hasError: p.prio == 0, drops: [], closed: [], mappingUser: .none, mappingDigest: nil,
                                            bytes: FS.size(outboxDir.appendingPathComponent(name)) ?? 0)
                }
            }
        }
        for k in metas.keys where !seen.contains(k) { metas.removeValue(forKey: k) }
    }

    /// 启动：清 tmp、扫出站箱、重建「在途携带」集合与今日批数。
    func scanOutboxAtStartup() {
        let nowWall = clock.wallMs()
        for name in FS.list(outboxDir) where name.hasPrefix("tmp-") {
            let url = outboxDir.appendingPathComponent(name)
            // 自己进程名的 tmp 一定是崩溃残留；别的进程的只清 1 h 以前的（可能正在构建）
            if name.hasPrefix("tmp-\(processName)-") || (FS.mtimeMs(url) ?? 0) < nowWall - 3_600_000 {
                FS.remove(url)
            }
        }
        for name in FS.list(root) where name.hasPrefix(".") && name.contains(".tmp-") {
            let url = root.appendingPathComponent(name)
            if (FS.mtimeMs(url) ?? 0) < nowWall - 3_600_000 { FS.remove(url) }
        }
        reconcileOutbox()
        embeddedDrops = []
        embeddedClosed = []
        pendingMapping = nil
        let today = Day.fromMs(nowWall)
        todayDay = today
        todayCount = 0
        for m in metas.values {
            embeddedDrops.formUnion(m.drops)
            embeddedClosed.formUnion(m.closed.map(\.sessionId))
            if let u = m.mappingUser, let d = m.mappingDigest { pendingMapping = (u, d) }
            if m.prio <= 1 && Day.fromMs(m.createdMs) == today { todayCount += 1 }
        }
    }

    // MARK: 隔离（毒批）

    func quarantine(_ name: String) {
        guard var m = metas[name] else { return }
        let q = OutboxName.make(prio: 3, createdMs: m.createdMs, batchId: m.batchId)
        let src = outboxDir.appendingPathComponent(name)
        let dst = outboxDir.appendingPathComponent(q)
        guard rename(src.path, dst.path) == 0 else { return }
        FS.touch(dst, wallMs: clock.wallMs())
        FS.markFile(dst)
        metas.removeValue(forKey: name)
        m.name = q
        m.prio = 3
        metas[q] = m
        fails.removeValue(forKey: name)
    }

    /// q-* 在 24 h 后或 app_version 变化后回到队列。
    func releaseQuarantine(force: Bool) {
        let now = clock.wallMs()
        for (name, m) in metas where m.prio == 3 {
            let url = outboxDir.appendingPathComponent(name)
            let since = FS.mtimeMs(url) ?? 0
            guard force || now - since >= ClientConstants.quarantineRetryMs else { continue }
            let prio = m.kind == .backfill ? 2 : (m.hasError ? 0 : 1)
            let p = OutboxName.make(prio: prio, createdMs: m.createdMs, batchId: m.batchId)
            if rename(url.path, outboxDir.appendingPathComponent(p).path) == 0 {
                metas.removeValue(forKey: name)
                var m2 = m
                m2.name = p
                m2.prio = prio
                metas[p] = m2
            }
        }
    }

    /// 最早的隔离批再试时刻（单调）。
    func nextQuarantineReleaseMono() -> Int64? {
        let nowWall = clock.wallMs()
        let nowMono = clock.monoMs()
        var best: Int64?
        for (name, m) in metas where m.prio == 3 {
            let since = FS.mtimeMs(outboxDir.appendingPathComponent(name)) ?? nowWall
            let at = nowMono + max(0, since + ClientConstants.quarantineRetryMs - nowWall)
            best = min(best ?? at, at)
        }
        return best
    }

    // MARK: 413：按 oseq（或 ctx）二分重物化（新的确定性 batch_id），原批删除

    func split413(_ name: String) {
        let url = outboxDir.appendingPathComponent(name)
        guard let gz = FS.read(url), let p = Engine.parseBatch(gz), p.header.kind == .primary else {
            quarantine(name)
            return
        }
        struct L { var raw: [UInt8]; var seq: Int64; var oseq: Int64; var ts: Int64; var rank: Int; var ctx: Bool }
        var ls: [L] = []
        for raw in p.lines {
            guard let pre = Segments.parsePrefix(raw, 0..<raw.count) else { continue }
            ls.append(L(raw: raw, seq: pre.seq, oseq: pre.oseq, ts: pre.ts, rank: pre.levelRank, ctx: Bytes.contains(Engine.ctxMark, in: raw[...])))
        }
        let oblig = ls.filter { !$0.ctx && $0.oseq > 0 }
        var ctx = ls.filter { $0.ctx }
        let h = p.header
        var parts: [(EnvelopeHeader, [L])] = []
        if oblig.count >= 2 {
            let mid = oblig[oblig.count / 2 - 1].oseq
            let a = oblig.filter { $0.oseq <= mid }
            let b = oblig.filter { $0.oseq > mid }
            let aErr = a.contains { $0.rank >= LogLevel.error.rank }
            let bErr = b.contains { $0.rank >= LogLevel.error.rank }
            let ctxToA = aErr && !bErr
            var ha = h
            var hb = h
            ha.oseqFrom = a.first!.oseq; ha.oseqTo = a.last!.oseq
            hb.oseqFrom = b.first!.oseq; hb.oseqTo = b.last!.oseq
            hb.drops = []; hb.closedSessions = []; hb.closedSessionsDropped = 0; hb.mapping = nil
            if ctxToA { hb.ctxTruncated = nil } else { ha.ctxTruncated = nil }
            parts = [(ha, a + (ctxToA ? ctx : [])), (hb, b + (ctxToA ? [] : ctx))]
        } else if oblig.count == 1 && !ctx.isEmpty {
            ctx.sort { $0.seq < $1.seq }
            let drop = max(1, ctx.count / 2)
            ctx.removeFirst(drop)
            var ha = h
            ha.ctxTruncated = (h.ctxTruncated ?? 0) + Int64(drop)
            parts = [(ha, oblig + ctx)]
        } else {
            quarantine(name)
            return
        }
        let old = metas[name]
        var written: [String] = []
        for part in parts {
            var hh = part.0
            var lines = part.1
            lines.sort { $0.seq < $1.seq }
            guard let inst = install, let bid = IDs.batchId(installId: inst.installId, sessionId: hh.sessionId, kind: .primary, n: hh.oseqFrom!) else { continue }
            hh.batchId = bid
            hh.seqFrom = lines.first!.seq
            hh.seqTo = lines.last!.seq
            hh.day = Day.clientDay(tsMinMs: lines.map(\.ts).min()!, createdMs: hh.createdMs)
            let hasErr = lines.contains { !$0.ctx && $0.rank >= LogLevel.error.rank }
            if let m = writeBatch(hh, lines: lines.map(\.raw), prio: hasErr ? 0 : 1) { written.append(m.name) }
        }
        guard written.count == parts.count else { return }
        if !written.contains(name) {
            FS.remove(url)
            metas.removeValue(forKey: name)
        }
        fails.removeValue(forKey: name)
        _ = old
    }

    // MARK: 驱逐（§3.8，宪法 R-5）

    /// 总量 = 各会话段 + 出站箱；上限 = min(local_cap_bytes, 本方已占 + 可用空间 − 64 MB 余量)。
    /// 顺序：RETAINED 段最旧优先（无义务不记墓碑；> 7 d 无条件删）→ p2（backfill_evicted）→ q（quarantine_evicted）
    /// → p1（buffer_overflow）→ p0（buffer_overflow）。当前 OPEN 段永不驱逐。
    func evictIfNeeded() {
        let nowWall = clock.wallMs()
        struct Seg { var url: URL; var size: Int64; var mtime: Int64; var segNo: Int }
        var sealed: [Seg] = []
        var total: Int64 = 0
        for procName in FS.list(root) where procName.hasPrefix("proc-") {
            let pdir = root.appendingPathComponent(procName)
            for sid in FS.list(pdir) where IDs.isUuid(sid) {
                let sdir = pdir.appendingPathComponent(sid)
                for f in FS.list(sdir) {
                    guard let (segNo, isOpen) = Segments.parseName(f) else { continue }
                    let url = sdir.appendingPathComponent(f)
                    let size = FS.size(url) ?? 0
                    total += size
                    if !isOpen { sealed.append(Seg(url: url, size: size, mtime: FS.mtimeMs(url) ?? nowWall, segNo: segNo)) }
                }
            }
        }
        reconcileOutbox()
        for m in metas.values { total += m.bytes }

        var cap = Int64(effective.config.localCapBytes)
        if let avail = platform.availableBytes(at: root) {
            cap = min(cap, max(0, total + avail - ClientConstants.diskReserveBytes))
        }
        sealed.sort { ($0.mtime, $0.segNo) < ($1.mtime, $1.segNo) }
        var tombs: [DropEntry] = []
        let maxAge = Int64(Limits.ringMaxAgeDays) * ClientConstants.dayMs
        var remaining: [Seg] = []
        for s in sealed {
            if nowWall - s.mtime > maxAge {
                total -= s.size
                evictSegment(s.url, now: nowWall, tombs: &tombs)
            } else {
                remaining.append(s)
            }
        }
        if total > cap, let cur = current, (cur.sealed.last?.lastOseq ?? 0) > cur.cursor.extractedThroughOseq {
            // daily cap 推迟的义务行先物化，保证 RETAINED 段不带义务
            materialize(cur, targetOseq: cur.sealed.map(\.lastOseq).max() ?? 0,
                        targetSeq: cur.sealed.last?.lastSeq ?? 0, noCtx: false, ignoreCap: true)
            reconcileOutbox()
            total = remaining.reduce(0) { $0 + $1.size } + metas.values.reduce(0) { $0 + $1.bytes }
                + (FS.size(writer.currentSegmentURL ?? URL(fileURLWithPath: "/nonexistent")) ?? 0)
        }
        for s in remaining where total > cap {
            total -= s.size
            evictSegment(s.url, now: nowWall, tombs: &tombs)
        }
        if total > cap {
            for prio in [2, 3, 1, 0] {
                let batch = metas.values.filter { $0.prio == prio && $0.name != inFlight }
                    .sorted { ($0.createdMs, $0.name) < ($1.createdMs, $1.name) }
                for m in batch where total > cap {
                    total -= m.bytes
                    evictBatch(m, now: nowWall, tombs: &tombs)
                }
            }
        }
        if !tombs.isEmpty { appendDrops(tombs) }
    }

    private func evictSegment(_ url: URL, now: Int64, tombs: inout [DropEntry]) {
        for s in ownSessions {
            guard let idx = s.sealed.firstIndex(where: { $0.url.path == url.path }) else { continue }
            let info = s.sealed[idx]
            if info.obligCount > 0 && info.lastOseq > s.cursor.extractedThroughOseq {
                let from = max(info.firstOseq, s.cursor.extractedThroughOseq + 1)
                tombs.append(DropEntry(sessionId: s.meta.sessionId, oseqFrom: from, oseqTo: info.lastOseq,
                                       n: info.lastOseq - from + 1, reason: DropReason.bufferOverflow.rawValue,
                                       atMs: now, lastAckAgeMs: lastAckAge(now)))
            }
            s.sealed.remove(at: idx)
            if s !== current && s.sealed.isEmpty && s.cursor.closedMs != nil {
                others.removeValue(forKey: s.meta.sessionId)
                FS.remove(s.dir)
                return
            }
            break
        }
        FS.remove(url)
        // 别的进程 / 已关闭会话的目录空了就一并清掉
        let dir = url.deletingLastPathComponent()
        if !FS.list(dir).contains(where: { Segments.parseName($0) != nil }),
           dir.path != current?.dir.path, others[dir.lastPathComponent] == nil,
           dir.deletingLastPathComponent().path != procDir.path {
            FS.remove(dir)
        }
    }

    private func evictBatch(_ m: BatchMeta, now: Int64, tombs: inout [DropEntry]) {
        FS.remove(outboxDir.appendingPathComponent(m.name))
        metas.removeValue(forKey: m.name)
        fails.removeValue(forKey: m.name)
        // 携带的墓碑 / 会话终态仍在 jsonl 里，放回待携带
        embeddedDrops.subtract(m.drops)
        embeddedClosed.subtract(m.closed.map(\.sessionId))
        if let u = m.mappingUser, let p = pendingMapping, p.user == u, p.digest == m.mappingDigest { pendingMapping = nil }
        guard !m.sessionId.isEmpty else { return }
        let age = lastAckAge(now)
        if m.kind == .backfill {
            tombs.append(DropEntry(sessionId: m.sessionId, oseqFrom: 0, oseqTo: 0, n: Int64(max(m.lineCount, 1)),
                                   reason: DropReason.backfillEvicted.rawValue, atMs: now, lastAckAgeMs: age))
        } else if m.oseqFrom > 0 {
            let reason = m.prio == 3 ? DropReason.quarantineEvicted : DropReason.bufferOverflow
            tombs.append(DropEntry(sessionId: m.sessionId, oseqFrom: m.oseqFrom, oseqTo: m.oseqTo, n: m.oseqTo - m.oseqFrom + 1,
                                   reason: reason.rawValue, atMs: now, lastAckAgeMs: age))
        }
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 启动恢复（§3.4 ORPHAN）：旧会话截残行、判退出、unclean_fg 合成 error 并按 error 封段带 ctx、
/// 旧会话终态写 sessions.jsonl；旧 session_id / user_id / device 一律取持久化值；
/// cursor = max(cursor 文件, 出站箱里本会话最大 oseq_to)。
extension Engine {
    static let uncleanTag = Array("\"tag\":\"rtv.unclean_exit\"".utf8)

    func recoverOldSessions() {
        guard let cur = current else { return }
        let now = clock.wallMs()
        var outMax: [String: Int64] = [:]
        for m in metas.values where m.kind == .primary && !m.sessionId.isEmpty {
            outMax[m.sessionId] = max(outMax[m.sessionId] ?? 0, m.oseqTo)
        }
        let (existingClosed, existingDrops): (Set<String>, [DropEntry]) = FS.withDirLock(root) {
            (Set(readClosedLocked().map(\.sessionId)), readDropsLocked())
        }
        var latest: SessionMeta?

        for sid in FS.list(procDir) where IDs.isUuid(sid) && sid != cur.meta.sessionId {
            let dir = procDir.appendingPathComponent(sid)
            // 活着的会话（别的进程 / 同进程另一实例持有目录锁）不动
            let lfd = open(dir.path, O_RDONLY | O_CLOEXEC)
            if lfd >= 0 && flock(lfd, LOCK_EX | LOCK_NB) != 0 {
                close(lfd)
                continue
            }
            if let m = recoverOne(sid: sid, dir: dir, now: now, outMax: outMax, existingClosed: existingClosed,
                                  existingDrops: existingDrops) {
                if latest == nil || m.sessionNo > latest!.sessionNo { latest = m }
            }
            if lfd >= 0 {
                flock(lfd, LOCK_UN)
                close(lfd)
            }
        }
        previousAppVersion = latest?.device.appVersion
    }

    /// 恢复一个旧会话；返回它的 meta（用于判断 app_version 变化）。
    private func recoverOne(sid: String, dir: URL, now: Int64, outMax: [String: Int64], existingClosed: Set<String>,
                            existingDrops: [DropEntry]) -> SessionMeta? {
        var newTombs: [DropEntry] = []
        let segNames = FS.list(dir).compactMap { n -> (Int, Bool, String)? in
            guard let (no, open) = Segments.parseName(n) else { return nil }
            return (no, open, n)
        }.sorted { ($0.0, $0.1 ? 1 : 0) < ($1.0, $1.1 ? 1 : 0) }
        guard let mb = FS.read(dir.appendingPathComponent("meta.json")), let meta = SessionMeta.decode(mb) else {
            if segNames.isEmpty { FS.remove(dir) }
            return nil
        }
        var cursor = FS.read(dir.appendingPathComponent("cursor.json")).flatMap(Cursor.decode) ?? Cursor()
        cursor.extractedThroughOseq = max(cursor.extractedThroughOseq, outMax[sid] ?? 0)

        var files: [SegmentFile] = []
        for (_, isOpen, n) in segNames {
            let url = dir.appendingPathComponent(n)
            guard var f = Segments.read(url, validate: isOpen) else { continue }
            if isOpen && f.validEnd < f.data.count {
                // 截残行：回到最后一个完整行
                let fd = open(url.path, O_WRONLY | O_CLOEXEC)
                if fd >= 0 {
                    _ = ftruncate(fd, off_t(f.validEnd))
                    _ = fsync(fd)
                    close(fd)
                }
                f.data = Array(f.data[0..<f.validEnd])
            }
            files.append(f)
        }

        var maxSeq: Int64 = 0
        var maxOseq: Int64 = 0
        var maxTs = meta.startedMs
        var present = Set<Int64>()
        for f in files {
            for l in f.lines {
                maxSeq = max(maxSeq, l.seq)
                maxTs = max(maxTs, l.ts)
                if l.oseq > 0 { maxOseq = max(maxOseq, l.oseq); present.insert(l.oseq) }
            }
            if let t = f.tornSeq { maxSeq = max(maxSeq, t) }
            if let t = f.tornOseq, t > 0 { maxOseq = max(maxOseq, t) }
        }
        maxSeq = max(maxSeq, cursor.ctxThroughSeq)

        if cursor.closedMs == nil {
            // 缺口（残行、全 0 块、未落盘的 write_failed）计 corrupt 墓碑；已有墓碑覆盖的不重复记
            let covered = existingDrops.filter { $0.sessionId == sid }
            var o = cursor.extractedThroughOseq + 1
            while o <= maxOseq {
                if present.contains(o) || covered.contains(where: { $0.oseqFrom <= o && o <= $0.oseqTo }) { o += 1; continue }
                let start = o
                while o + 1 <= maxOseq && !present.contains(o + 1)
                        && !covered.contains(where: { $0.oseqFrom <= o + 1 && o + 1 <= $0.oseqTo }) { o += 1 }
                newTombs.append(DropEntry(sessionId: sid, oseqFrom: start, oseqTo: o, n: o - start + 1,
                                          reason: DropReason.corrupt.rawValue, atMs: now, lastAckAgeMs: lastAckAge(now)))
                o += 1
            }
            let exit: SessionExit = cursor.lastState == "fg" ? .uncleanFg : (cursor.lastState == "bg" ? .cleanBg : .unknown)
            let lastRaw: ArraySlice<UInt8>? = files.last.flatMap { f in f.lines.last.map { f.data[$0.range] } }
            let alreadySynth = lastRaw.map { Bytes.contains(Engine.uncleanTag, in: $0) } ?? false
            if exit == .uncleanFg && !alreadySynth {
                let oblig = LogLevel.error.rank >= effective.uploadLevel.rank
                let seq = maxSeq + 1
                let oseq: Int64 = oblig ? maxOseq + 1 : 0
                let ts = max(maxTs, cursor.lastStateMs)
                let enc = LineEncoder.encode(LogLine(ts: ts, level: .error, msg: "process ended while foregrounded",
                                                     tag: "rtv.unclean_exit"), synthetic: true)
                var bytes = LineEncoder.prefix(seq: seq, oseq: oseq)
                bytes.append(contentsOf: enc.body)
                var target: URL
                if let last = files.last, !last.sealed {
                    target = last.url
                } else {
                    let no = (files.last?.segNo ?? 0) + 1
                    target = dir.appendingPathComponent(Segments.name(no, open: true))
                    let header = SegmentHeader(segNo: no, userId: files.last?.header?.userId, startedMs: ts).encode()
                    FS.writeAtomic(target, header)
                }
                if FS.append(target, bytes) {
                    maxSeq = seq
                    if oseq > 0 { maxOseq = oseq }
                    if let idx = files.firstIndex(where: { $0.url.path == target.path }) {
                        if let f = Segments.read(target, validate: false) { files[idx] = f }
                    } else if let f = Segments.read(target, validate: false) {
                        files.append(f)
                    }
                }
            }
            let sealed = sealAll(files)
            let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: sealed)
            if !existingClosed.contains(sid) {
                let c = ClosedSession(sessionId: sid, sessionNo: meta.sessionNo, startedMs: meta.startedMs,
                                      endedMs: max(maxTs, cursor.lastStateMs, meta.startedMs), lastSeq: maxSeq,
                                      lastOseq: maxOseq, exit: exit.rawValue)
                FS.withDirLock(root) { _ = FS.append(sessionsURL, JSONL.encodeClosed([c])) }
            }
            if !newTombs.isEmpty {
                appendDrops(newTombs)
                newTombs.removeAll()
            }
            // 按 error 封段带 ctx（合成 error 在批内 → 自动附 ctx）
            materialize(rec, targetOseq: maxOseq, targetSeq: maxSeq, forceCtx: false, ignoreCap: true)
            rec.cursor.closedMs = now
            writeCursor(rec)
            register(rec)
        } else {
            let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: sealAll(files))
            if maxOseq > cursor.extractedThroughOseq {
                materialize(rec, targetOseq: maxOseq, targetSeq: maxSeq, forceCtx: false, ignoreCap: true)
            }
            register(rec)
        }
        return meta
    }

    private func register(_ rec: SessionRecord) {
        if rec.sealed.isEmpty {
            FS.remove(rec.dir)
        } else {
            others[rec.meta.sessionId] = rec
        }
    }

    /// 旧会话的 .open 段一律 fsync + rename 为 .sealed；返回段索引。
    private func sealAll(_ files: [SegmentFile]) -> [SegInfo] {
        var out: [SegInfo] = []
        for f in files {
            var url = f.url
            if !f.sealed {
                let fd = open(url.path, O_WRONLY | O_CLOEXEC)
                if fd >= 0 { _ = fsync(fd); close(fd) }
                let dst = url.deletingLastPathComponent().appendingPathComponent(Segments.name(f.segNo, open: false))
                if rename(url.path, dst.path) == 0 {
                    FS.markFile(dst)
                    url = dst
                }
            }
            out.append(SegInfo.from(f, url: url))
        }
        return out.sorted { $0.segNo < $1.segNo }
    }
}

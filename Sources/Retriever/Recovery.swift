import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 启动恢复（§3.4 ORPHAN）：旧会话截残行、判退出、unclean_fg 合成 error 并按 error 封段带 ctx、
/// 有义务行的旧会话终态写 sessions.jsonl；旧 session_id / user_id / device 一律取持久化值；
/// cursor = max(cursor 文件, 出站箱里本会话最大 oseq_to)。段读不出的会话原样留到下次启动；零行的会话目录直接删。
extension Engine {
    static let uncleanTag = "rtv.unclean_exit"

    /// 返回 false = 本次没恢复（拿不到 root 目录锁），调用方稍后重试；没有当前会话时无事可做，算完成。
    @discardableResult
    func recoverOldSessions() -> Bool {
        guard let cur = current else { return true }
        let now = clock.wallMs()
        var outMax: [String: Int64] = [:]
        for m in metas.values where m.kind == .primary && !m.sessionId.isEmpty {
            outMax[m.sessionId] = max(outMax[m.sessionId] ?? 0, m.oseqTo)
        }
        // 拿不到 root 目录锁：本次不恢复，下次启动再来（ADR 0024 决定 3：不得不加锁执行）
        guard let (existingClosed, existingDrops) = FS.withDirLock(root, { () -> (Set<String>, [DropEntry]) in
            (Set(readClosedLocked().map(\.sessionId)), readDropsLocked())
        }) else { return false }
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
                // 最近的旧会话按 started_ms 认（孤儿收编出的会话 session_no 在收编时才分配，ADR 0023）
                if latest == nil || (m.startedMs, m.sessionNo) > (latest!.startedMs, latest!.sessionNo) { latest = m }
            }
            if lfd >= 0 {
                flock(lfd, LOCK_UN)
                close(lfd)
            }
        }
        previousAppVersion = latest?.device.appVersion
        return true
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
        // 收编未提交（meta.pre 所指文件非空）或判不清（stat 出错）：不恢复、不物化，等重做 / 下一轮（ADR 0023；盲审裁决 8）。
        // 确实不存在或长度为 0（截空提交）= 已提交
        if let pre = meta.pre, preState(pre) != .committed { return nil }
        var cursor = FS.read(dir.appendingPathComponent("cursor.json")).flatMap(Cursor.decode) ?? Cursor()
        cursor.extractedThroughOseq = max(cursor.extractedThroughOseq, outMax[sid] ?? 0)

        var files: [SegmentFile] = []
        for (_, isOpen, n) in segNames {
            let url = dir.appendingPathComponent(n)
            // 段读不出（保护类 / fd 耗尽等）：不推进 cursor、不删会话目录、不写终态，整个会话留到下次启动重试（ADR 0019 决定 13）
            guard var f = Segments.read(url, validate: isOpen) else { return meta }
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
        // 盘上最大值在旧段被驱逐后偏低：并入已物化高水位（已含出站箱）与本会话墓碑，
        // 否则合成行与已上传的 oseq 撞号、永不上传，终态 last_oseq 低报
        let tombMax = existingDrops.filter { $0.sessionId == sid }.map(\.oseqTo).max() ?? 0
        maxOseq = max(maxOseq, cursor.extractedThroughOseq, tombMax)
        maxSeq = max(maxSeq, cursor.ctxThroughSeq)

        if maxSeq == 0 && maxOseq == 0 {
            // 零行：盘上无行，也没有任何已物化 / 已驱逐 / 墓碑的痕迹（后台拉起的空进程、禁用期间的进程多是这样）：
            // 无数据、无终态可写，目录直接删（ADR 0019 决定 1），不留到 7 天年龄驱逐、也不在每次冷启动重读。
            // 判零行在合成 rtv.unclean_exit 之前：禁用期间启动的会话必是零行，不能事后由已启用的进程替它合成一条
            // 带时刻的崩溃证据上报（撤回同意 = 不写不传，ADR 0020 决定 2）；代价是启用期「一行未写就前台崩溃」不留痕
            FS.remove(dir)
            return meta
        }

        var exit: SessionExit = .unknown
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
            exit = cursor.lastState == "fg" ? .uncleanFg : (cursor.lastState == "bg" ? .cleanBg : .unknown)
            let lastRaw: ArraySlice<UInt8>? = files.last.flatMap { f in f.lines.last.map { f.data[$0.range] } }
            // 已合成过：按位置认（行尾 synthetic 标记 + msg 之后的 tag），attrs 里的同名键不算（ADR 0024 决定 9）
            let alreadySynth = lastRaw.map { Segments.tail($0).synthetic && Segments.tag($0) == Engine.uncleanTag } ?? false
            // 合成行也是写入：只看本进程内存开关（禁用 = 不写，ADR 0020 决定 2）
            if exit == .uncleanFg && !alreadySynth && enabled {
                let oblig = LogLevel.error.rank >= writer.levels.upload.rank
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
        }


        if cursor.closedMs == nil {
            let sealed = sealAll(files)
            let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: sealed)
            // 终态只为有义务行的会话写（ADR 0019 决定 1）：没有义务行的会话服务端无可结算，空会话的终态只会挤占别人
            var closedOk = true
            if maxOseq > 0 && !existingClosed.contains(sid) {
                closedOk = appendClosed(ClosedSession(sessionId: sid, sessionNo: meta.sessionNo, startedMs: meta.startedMs,
                                                      endedMs: max(maxTs, cursor.lastStateMs, meta.startedMs), lastSeq: maxSeq,
                                                      lastOseq: maxOseq, exit: exit.rawValue))
            }
            let dropsOk = newTombs.isEmpty ? true : appendDrops(newTombs)
            // 按 error 封段带 ctx（合成 error 在批内 → 自动附 ctx）。墓碑没写成就不物化：游标一旦越过缺口，
            // 下次启动的缺口扫描（从游标往后）再也找不到它；整个会话留到下次启动重试（同段读不出，ADR 0019 决定 13）
            if dropsOk {
                materialize(rec, targetOseq: maxOseq, targetSeq: maxSeq, noCtx: false, ignoreCap: true)
            }
            // 终态或墓碑没写成（磁盘满等）：不打「已收尾」标记，下次启动重试（终态按 session_id、合成行都有防重复），不静默丢
            if closedOk && dropsOk {
                rec.cursor.closedMs = now
                writeCursor(rec)
            }
            register(rec)
        } else {
            let rec = SessionRecord(meta: meta, dir: dir, cursor: cursor, sealed: sealAll(files))
            if maxOseq > cursor.extractedThroughOseq {
                materialize(rec, targetOseq: maxOseq, targetSeq: maxSeq, noCtx: false, ignoreCap: true)
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

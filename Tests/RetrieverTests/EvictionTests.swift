import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 容量与驱逐（方案 §3.8；宪法 R-5）。
final class EvictionTests: XCTestCase {
    /// 准备：RETAINED 段 ×2（无义务）、p2、q、p1、p0 各一。
    func prepare() async -> Harness {
        let h = Harness(key: "")
        await h.settle()
        // 先生成一个 p2（只覆盖第一段），再塞两段 RETAINED 作驱逐对象
        h.client.log(.debug, "backfill me")
        await h.seal()
        await h.work { $0.materializeBackfill() }
        for _ in 0..<2 {
            let seg = h.client.writer.snapshot.segNo
            while h.client.writer.snapshot.segNo == seg { h.client.log(.debug, String(repeating: "d", count: 300)) }
            await h.settle()
        }
        h.client.log(.warn, "to quarantine")
        await h.seal()
        await h.work { e in
            let name = e.metas.values.first { $0.prio == 1 }!.name
            e.quarantine(name)
        }
        h.clock.advance(1)
        h.client.log(.warn, "p1")
        await h.seal()
        h.clock.advance(1)
        h.client.log(.error, "p0")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().map { String($0.prefix(2)) }.sorted(), ["p0", "p1", "p2", "q-"])
        return h
    }

    func testEvictionOrderAndTombstones() async throws {
        let h = await prepare()
        let sid = h.client.writer.currentSessionId
        let dir = h.sessionDir()
        let sealedSegs = { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".sealed") }.sorted() }
        XCTAssertEqual(sealedSegs().count, 6)
        // 阶段 1：上限刚好容下「出站箱全部 − p2」+ 当前段 → 删光 RETAINED 段，再删 p2
        let (segBytes, openBytes, box): (Int64, Int64, [String: Int64]) = await h.work { e in
            let segs = e.current!.sealed.reduce(Int64(0)) { $0 + (FS.size($1.url) ?? 0) }
            let open = FS.size(e.writer.currentSegmentURL!) ?? 0
            var b: [String: Int64] = [:]
            for m in e.metas.values { b[String(m.name.prefix(2))] = m.bytes }
            return (segs, open, b)
        }
        XCTAssertGreaterThan(segBytes, 1_000_000)
        let cap1 = openBytes + box["q-"]! + box["p1"]! + box["p0"]!
        await h.work { e in
            e.effective.config.localCapBytes = Int(cap1)
            e.evictIfNeeded()
        }
        XCTAssertEqual(sealedSegs(), [])
        XCTAssertEqual(h.outboxFiles().map { String($0.prefix(2)) }.sorted(), ["p0", "p1", "q-"])
        var drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.map { $0["reason"] as? String }, ["backfill_evicted"], "RETAINED 段无义务：不记墓碑")
        XCTAssertEqual(int(drops[0]["oseq_from"]), 0)
        XCTAssertEqual(int(drops[0]["oseq_to"]), 0)
        XCTAssertEqual(int(drops[0]["n"]), 1)
        // 阶段 2：上限 0 → q → p1 → p0 依次驱逐；当前 OPEN 段永不驱逐
        await h.work { e in
            e.effective.config.localCapBytes = 0
            e.evictIfNeeded()
        }
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.client.debugOpenSegmentPath!))
        drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.map { $0["reason"] as? String }, ["backfill_evicted", "quarantine_evicted", "buffer_overflow", "buffer_overflow"])
        XCTAssertEqual(drops.map { int($0["oseq_from"]) }, [0, 1, 2, 3])
        XCTAssertTrue(drops.allSatisfy { $0["session_id"] as? String == sid })
        XCTAssertTrue(drops.allSatisfy { int($0["last_ack_age_ms"]) == -1 })
        // 墓碑随下一个 primary 批上报，服务端校验通过
        await h.work { $0.effective.config.localCapBytes = Limits.localCapBytesDefault }
        h.client.log(.warn, "carrier")
        await h.seal()
        let env = try XCTUnwrap(h.envelopes().first?.1)
        XCTAssertEqual((env["drops"] as? [Any])?.count, 4)
        let results = try runValidator([env])
        XCTAssertEqual(results.first?["ok"] as? Bool, true, "\(results)")
        XCTAssertEqual(int((results.first?["stats"] as? [String: Any])?["dropsN"]), 1 + 1 + 1 + 1)
    }

    /// 低磁盘（ADR 0010）：余量额度只收紧 RETAINED 段与 p2；刚物化的 error 批留着并照常上传（修复前：上传前被驱逐、0 请求）。
    func testLowDiskKeepsObligationBatchAndUploads() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.debug, "retained")
        await h.seal()
        h.platform.available = 10 * 1024 * 1024
        h.client.log(.info, "ctx")
        h.client.log(.error, "boom")
        await h.sealAndDrain(.error)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        let env = try XCTUnwrap(decodeEnvelope(XCTUnwrap(h.transport.batchRequests.first?.body)))
        XCTAssertTrue(lines(of: env).contains { $0["msg"] as? String == "boom" })
        XCTAssertTrue(lines(of: env).contains { $0["ctx"] as? Bool == true }, "先物化（带 ctx）再驱逐")
        XCTAssertEqual(h.outboxFiles(), [])
        let sealed = ((try? FileManager.default.contentsOfDirectory(atPath: h.sessionDir().path)) ?? []).filter { $0.hasSuffix(".sealed") }
        XCTAssertEqual(sealed, [], "RETAINED 段按余量额度驱逐")
        XCTAssertEqual(h.readJSONL("drops.jsonl").count, 0, "无义务，不记墓碑")
    }

    /// 低磁盘：RETAINED 段与 p2 被驱逐（p2 记 backfill_evicted），q / p1 / p0 只受硬上限约束；
    /// 超过 local_cap_bytes 时仍按 q → p1 → p0 驱逐并记墓碑。
    func testLowDiskEvictsOnlyNonObligationThenHardCapOrder() async throws {
        let h = await prepare()
        let dir = h.sessionDir()
        let sealedSegs = { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".sealed") } }
        XCTAssertEqual(sealedSegs().count, 6)
        h.platform.available = 10 * 1024 * 1024
        await h.work { $0.evictIfNeeded() }
        XCTAssertEqual(sealedSegs(), [])
        XCTAssertEqual(h.outboxFiles().map { String($0.prefix(2)) }.sorted(), ["p0", "p1", "q-"])
        XCTAssertEqual(h.readJSONL("drops.jsonl").map { $0["reason"] as? String }, ["backfill_evicted"])
        await h.work { e in
            e.effective.config.localCapBytes = 0
            e.evictIfNeeded()
        }
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.client.debugOpenSegmentPath!))
        let drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.map { $0["reason"] as? String }, ["backfill_evicted", "quarantine_evicted", "buffer_overflow", "buffer_overflow"])
        XCTAssertEqual(drops.map { int($0["oseq_from"]) }, [0, 1, 2, 3])
    }

    func testSegmentsOlderThanSevenDaysDeletedUnconditionally() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.debug, "old")
        await h.seal()
        let seg = h.sessionDir().appendingPathComponent("seg-000001.sealed")
        FS.touch(seg, wallMs: h.clock.wallMs() - 8 * 86_400_000)
        // 时钟对齐：mtime 用真实墙钟，把假时钟拨到真实时间
        let delta = Int64(Date().timeIntervalSince1970 * 1000) - h.clock.wallMs()
        h.clock.advance(delta)
        FS.touch(seg, wallMs: h.clock.wallMs() - 8 * 86_400_000)
        await h.work { $0.evictIfNeeded() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seg.path))
        XCTAssertEqual(h.readJSONL("drops.jsonl").count, 0)
    }

    /// drops.jsonl 超上限（ADR 0019 决定 4）：只做无损合并（同会话、同 reason、区间相接），n == 区间长度，
    /// 不跨会话、不跨 reason、绝不盖住输入里没有的 oseq；仍超出删最旧的（修复前：按 reason 并成 [min, max]，盖住真实缺口）。
    func testDropsFileCapOnlyLosslessMerge() async throws {
        let h = Harness(key: "")
        await h.settle()
        let sid = h.client.writer.currentSessionId
        let other = IDs.newV4()
        var entries: [DropEntry] = []
        var dropped = Set<String>()
        func add(_ s: String, _ o: Int64, _ reason: String = "buffer_overflow") {
            entries.append(DropEntry(sessionId: s, oseqFrom: o, oseqTo: o, n: 1, reason: reason, atMs: Int64(entries.count), lastAckAgeMs: -1))
            dropped.insert("\(s)|\(reason)|\(o)")
        }
        // 同会话 1100 条稀疏（间隔 3）；前 150 条各跟一条相接的（可无损合并）
        for i in 1...1100 {
            add(sid, Int64(i) * 3)
            if i <= 150 { add(sid, Int64(i) * 3 + 1) }
        }
        add(other, 4)                       // 数值上与 [3, 4] 相接，但属于别的会话
        add(sid, 5, "write_failed")         // 与 [3, 4] 相接，但 reason 不同
        let all = entries
        _ = await h.work { $0.appendDrops(all) }
        let drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.count, ClientConstants.dropsFileMaxEntries)
        for d in drops {
            let (f, t) = (int(d["oseq_from"]), int(d["oseq_to"]))
            XCTAssertEqual(int(d["n"]), t - f + 1, "n == 区间长度")
            for o in f...t {
                XCTAssertTrue(dropped.contains("\(d["session_id"] as! String)|\(d["reason"] as! String)|\(o)"), "盖住了输入里没有的 oseq \(o)")
            }
        }
        XCTAssertTrue(drops.contains { int($0["oseq_from"]) == 450 && int($0["oseq_to"]) == 451 && int($0["n"]) == 2 }, "相接的并成一条")
        XCTAssertTrue(drops.contains { $0["session_id"] as? String == other && int($0["oseq_from"]) == 4 }, "不跨会话")
        XCTAssertTrue(drops.contains { $0["reason"] as? String == "write_failed" && int($0["oseq_from"]) == 5 }, "不跨 reason")
        XCTAssertFalse(drops.contains { int($0["oseq_from"]) == 3 }, "仍超出：删最旧的")
    }

    /// 墓碑携带（ADR 0019 决定 2）：每批按文件顺序带最旧的、未在途的 100 条，各自会话与精确区间，不合并、不改写文件；
    /// 带不完的留给下一批（修复前：> 100 条先按 reason 合并并改写文件）。
    func testDropsCarriedUnmergedOldestFirst() async throws {
        let h = Harness(key: "")
        await h.settle()
        let sids = (0..<150).map { _ in IDs.newV4() }
        let entries = sids.enumerated().map { i, s in
            DropEntry(sessionId: s, oseqFrom: 5, oseqTo: 7, n: 3, reason: "buffer_overflow", atMs: Int64(i), lastAckAgeMs: -1)
        }
        _ = await h.work { $0.appendDrops(entries) }
        let file = h.root.appendingPathComponent("drops.jsonl")
        let before = try Data(contentsOf: file)
        h.client.log(.warn, "carrier 1")
        await h.seal()
        h.client.log(.warn, "carrier 2")
        await h.seal()
        XCTAssertEqual(try Data(contentsOf: file), before, "携带不改写文件")
        let envs = h.envelopes().map(\.1).sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
        XCTAssertEqual(envs.count, 2)
        let d1 = try XCTUnwrap(envs[0]["drops"] as? [[String: Any]])
        let d2 = try XCTUnwrap(envs[1]["drops"] as? [[String: Any]])
        XCTAssertEqual(d1.map { $0["session_id"] as? String }, Array(sids.prefix(100)))
        XCTAssertEqual(d2.map { $0["session_id"] as? String }, Array(sids.suffix(50)))
        XCTAssertTrue((d1 + d2).allSatisfy { int($0["oseq_from"]) == 5 && int($0["oseq_to"]) == 7 && int($0["n"]) == 3 })
        let results = try runValidator(envs)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    /// 终态携带（ADR 0019 决定 2）：每批按文件顺序带最旧的、未在途的 20 条，带不完的留给下一批；不再截断计数、不改写文件
    /// （修复前：> 20 条时最旧的被删除，只留 closed_sessions_dropped 计数）。2xx 后删除已报条目。
    func testTerminalsCarriedOldestFirstNeverDropped() async throws {
        let h = Harness(key: "")
        await h.settle()
        let closed = (1...30).map { i in
            ClosedSession(sessionId: IDs.newV4(), sessionNo: Int64(i), startedMs: Int64(i) * 1000, endedMs: Int64(i) * 1000 + 500,
                          lastSeq: 10, lastOseq: 2, exit: "clean_bg")
        }
        let file = h.root.appendingPathComponent("sessions.jsonl")
        FS.append(file, JSONL.encodeClosed(closed))
        let before = try Data(contentsOf: file)
        h.client.log(.warn, "carrier 1")
        await h.seal()
        h.client.log(.warn, "carrier 2")
        await h.seal()
        XCTAssertEqual(try Data(contentsOf: file), before, "携带不改写文件")
        let envs = h.envelopes().map(\.1).sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
        XCTAssertEqual(envs.count, 2)
        XCTAssertEqual((envs[0]["closed_sessions"] as? [[String: Any]])?.map { int($0["session_no"]) }, Array(1...20))
        XCTAssertEqual((envs[1]["closed_sessions"] as? [[String: Any]])?.map { int($0["session_no"]) }, Array(21...30))
        XCTAssertTrue(envs.allSatisfy { $0["closed_sessions_dropped"] == nil }, "信封不再出现 closed_sessions_dropped")
        // 2xx 后删除已报条目
        await h.enableUpload()
        await h.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(h.readJSONL("sessions.jsonl").count, 0)
    }

    /// sessions.jsonl 上限 1000 条（ADR 0019 决定 3）：追加后超出删最旧的未在途条目；在途（已嵌进出站箱批次）的不删。
    func testSessionsFileCapDropsOldestNotInFlight() async throws {
        let h = Harness(key: "")
        await h.settle()
        func closed(_ r: ClosedRange<Int>) -> [ClosedSession] {
            r.map { ClosedSession(sessionId: IDs.newV4(), sessionNo: Int64($0), startedMs: 1, endedMs: 2, lastSeq: 1, lastOseq: 1, exit: "clean_bg") }
        }
        let file = h.root.appendingPathComponent("sessions.jsonl")
        FS.append(file, JSONL.encodeClosed(closed(1...20)))
        h.client.log(.warn, "carrier")
        await h.seal()                                              // 1…20 在途
        FS.append(file, JSONL.encodeClosed(closed(21...1005)))
        let last = closed(1006...1006)[0]
        let ok = await h.work { $0.appendClosed(last) }
        XCTAssertTrue(ok)
        let nos = h.readJSONL("sessions.jsonl").map { int($0["session_no"]) }
        XCTAssertEqual(nos.count, ClientConstants.sessionsFileMaxEntries)
        XCTAssertEqual(Array(nos.prefix(20)), Array(1...20), "在途的不删")
        XCTAssertEqual(Array(nos.dropFirst(20).prefix(1)), [27], "删的是最旧的未在途条目 21…26")
        XCTAssertEqual(nos.last, 1006)
    }
}

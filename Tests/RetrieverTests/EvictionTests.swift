import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 容量与驱逐（方案 §3.8；宪法 R-5）。
final class EvictionTests: XCTestCase {
    /// 准备：RETAINED 段 ×2（无义务）、p2、q、p1、p0 各一。
    func prepare() async -> Harness {
        let h = Harness(key: "")
        await h.settle()
        for _ in 0..<2 {
            let seg = h.client.writer.snapshot.segNo
            while h.client.writer.snapshot.segNo == seg { h.client.log(.debug, String(repeating: "d", count: 300)) }
            await h.settle()
        }
        h.client.log(.debug, "backfill me")
        await h.seal()
        await h.work { e in
            // 让 backfill 只覆盖最后一段（前两段留作 RETAINED 驱逐对象）
            let cur = e.current!
            cur.cursor.ctxThroughSeq = cur.sealed[1].lastSeq
            e.materializeBackfill()
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

    func testDropsFileCappedAndMergedByReason() async throws {
        let h = Harness(key: "")
        await h.settle()
        let sid = h.client.writer.currentSessionId
        var entries: [DropEntry] = []
        for i in 1...1100 {
            let o = Int64(i) * 2
            let reason = i % 2 == 0 ? "write_failed" : "buffer_overflow"
            entries.append(DropEntry(sessionId: sid, oseqFrom: o, oseqTo: o, n: 1, reason: reason, atMs: Int64(i), lastAckAgeMs: -1))
        }
        let all = entries
        _ = await h.work { e in e.appendDrops(all) }
        let drops = h.readJSONL("drops.jsonl")
        XCTAssertLessThanOrEqual(drops.count, ClientConstants.dropsFileMaxEntries)
        XCTAssertEqual(drops.reduce(Int64(0)) { $0 + int($1["n"]) }, 1100, "合并计数不丢")
        XCTAssertEqual(Set(drops.map { $0["reason"] as? String }), ["write_failed", "buffer_overflow"])
        // 单批 ≤ 100 条，超出按 reason 合并
        h.client.log(.warn, "carrier")
        await h.seal()
        let env = try XCTUnwrap(h.envelopes().first?.1)
        let d = try XCTUnwrap(env["drops"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(d.count, Limits.dropsPerBatch)
        XCTAssertEqual(d.reduce(Int64(0)) { $0 + int($1["n"]) }, 1100)
        let results = try runValidator([env])
        XCTAssertEqual(results.first?["ok"] as? Bool, true, "\(results)")
    }

    func testClosedSessionsCappedAtTwenty() async throws {
        let h = Harness(key: "")
        await h.settle()
        let closed = (1...25).map { i in
            ClosedSession(sessionId: IDs.newV4(), sessionNo: Int64(i), startedMs: Int64(i) * 1000, endedMs: Int64(i) * 1000 + 500,
                          lastSeq: 10, lastOseq: 2, exit: "clean_bg")
        }
        FS.append(h.root.appendingPathComponent("sessions.jsonl"), JSONL.encodeClosed(closed))
        h.client.log(.warn, "carrier")
        await h.seal()
        let env = try XCTUnwrap(h.envelopes().first?.1)
        let cs = try XCTUnwrap(env["closed_sessions"] as? [[String: Any]])
        XCTAssertEqual(cs.count, Limits.closedSessionsPerBatch)
        XCTAssertEqual(int(env["closed_sessions_dropped"]), 5)
        XCTAssertEqual(Set(cs.map { int($0["session_no"]) }), Set(6...25))
        XCTAssertEqual(h.readJSONL("sessions.jsonl").count, 20, "更旧的 5 条已合并为计数")
        // 2xx 后删除已报条目
        await h.enableUpload()
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(h.readJSONL("sessions.jsonl").count, 0)
    }
}

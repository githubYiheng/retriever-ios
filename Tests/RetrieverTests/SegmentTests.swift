import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 段状态机与物化（方案 §3.4 / §3.5）。
final class SegmentTests: XCTestCase {
    func segFiles(_ h: Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.sessionDir().path)) ?? []).filter { $0.hasPrefix("seg-") }.sorted()
    }

    func header(_ url: URL) throws -> [String: Any] {
        let s = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.split(separator: "\n")[0].utf8)) as? [String: Any])
    }

    func testRotatesAt512KB() async throws {
        let h = Harness(key: "")
        await h.settle()
        var n = 0
        while segFiles(h).count < 2 {
            h.client.log(.debug, "fill " + String(repeating: "x", count: 200))
            n += 1
        }
        await h.settle()
        XCTAssertEqual(segFiles(h), ["seg-000001.sealed", "seg-000002.open"])
        let size = try XCTUnwrap(FS.size(h.sessionDir().appendingPathComponent("seg-000001.sealed")))
        XCTAssertGreaterThanOrEqual(size, Int64(Limits.segmentBytes))
        XCTAssertLessThan(size, Int64(Limits.segmentBytes + 400))
        XCTAssertEqual(int(try header(h.sessionDir().appendingPathComponent("seg-000002.open"))["seg_no"]), 2)
        // 全是 debug（非义务行）→ 不产生批次
        XCTAssertEqual(h.outboxFiles(), [])
        let cursor = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.sessionDir().appendingPathComponent("cursor.json"))) as? [String: Any])
        XCTAssertEqual(int(cursor["extracted_through_oseq"]), 0)
        XCTAssertEqual(cursor["last_state"] as? String, "fg")
    }

    func testSetUserSealsAndHeaderCarriesUser() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.setUser("early")         // 段内还没有行：直接改写 header，不封段
        h.client.log(.warn, "as early")
        h.client.setUser("u1")
        h.client.log(.warn, "as u1")
        h.client.setUser("u1")            // 值没变：不封段
        h.client.log(.warn, "still u1")
        h.client.setUser(nil)
        await h.settle()
        let files = segFiles(h)
        XCTAssertEqual(files, ["seg-000001.sealed", "seg-000002.sealed", "seg-000003.open"])
        XCTAssertEqual(try header(h.sessionDir().appendingPathComponent(files[0]))["user_id"] as? String, "early")
        XCTAssertEqual(try header(h.sessionDir().appendingPathComponent(files[1]))["user_id"] as? String, "u1")
        XCTAssertTrue(try header(h.sessionDir().appendingPathComponent(files[2]))["user_id"] is NSNull)
        let envs = h.envelopes().map(\.1).sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
        XCTAssertEqual(envs.count, 2)
        XCTAssertEqual(envs[0]["user_id"] as? String, "early")
        XCTAssertEqual(lines(of: envs[0]).map { $0["msg"] as? String }, ["as early"])
        XCTAssertEqual(envs[1]["user_id"] as? String, "u1")
        XCTAssertEqual(lines(of: envs[1]).map { $0["msg"] as? String }, ["as u1", "still u1"])
        XCTAssertEqual((envs[1]["mapping"] as? [String: Any])?["user_id"] as? String, "u1")
    }

    func testErrorDebounceTwoSecondsAndTenSecondSpacing() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.error, "e1")
        h.client.log(.debug, "after e1")
        await h.tick(advance: 1999)
        XCTAssertEqual(h.outboxFiles(), [])
        await h.tick(advance: 1)
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        // 第二个 error：距上次 error 封段不足 10 s → 推到 10 s
        await h.tick(advance: 1000)
        h.client.log(.error, "e2")
        await h.tick(advance: 2000)
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        await h.tick(advance: 6999)
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        await h.tick(advance: 1)
        XCTAssertEqual(h.outboxFiles("p0").count, 2)
    }

    func testFatalSealsImmediatelyWithoutUpload() async throws {
        let h = Harness()
        await h.settle()
        let before = h.transport.batchRequests.count
        h.client.log(.info, "ctx before fatal")
        h.client.log(.fatal, "crashing")
        // log() 返回时批已在出站箱（同步物化），且没有发起上传
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        XCTAssertEqual(h.transport.batchRequests.count, before)
        let e = try XCTUnwrap(h.envelopes("p0").first?.1)
        XCTAssertEqual(lines(of: e).map { $0["msg"] as? String }, ["ctx before fatal", "crashing"])
        XCTAssertEqual(lines(of: e).first?["ctx"] as? Bool, true)
    }

    func testWarnTimerFlushInterval() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.info, "not obligation")
        await h.tick(advance: 400_000)
        XCTAssertEqual(h.outboxFiles(), [], "没有义务行不封")
        h.client.log(.warn, "w")
        await h.tick(advance: 299_999)
        XCTAssertEqual(h.outboxFiles(), [])
        await h.tick(advance: 1)
        XCTAssertEqual(h.outboxFiles("p1").count, 1)
    }

    func testCtxAcrossSegmentsAndDedupedByCtxThroughSeq() async throws {
        let h = Harness(key: "")
        await h.settle()
        // 段 1 塞满 debug，段 2 再写 50 行 debug，然后 error
        while segFiles(h).count < 2 { h.client.log(.debug, "old " + String(repeating: "o", count: 300)) }
        let seg1Last = h.client.debugCounters.seq
        for i in 0..<50 { h.client.log(.debug, "new \(i)") }
        h.client.log(.error, "e1")
        await h.tick(advance: 2000)
        let e1 = try XCTUnwrap(h.envelopes("p0").first?.1)
        let ctx1 = lines(of: e1).filter { $0["ctx"] as? Bool == true }
        XCTAssertEqual(ctx1.count, Limits.ctxLinesDefault)
        XCTAssertTrue(ctx1.contains { int($0["seq"]) <= seg1Last }, "ctx 跨段取")
        XCTAssertTrue(ctx1.contains { int($0["seq"]) > seg1Last })
        XCTAssertGreaterThan(int(e1["ctx_truncated"]), 0)
        XCTAssertNil(ctx1.first { $0["oseq"] != nil })
        // 行按 seq 升序，ctx 与义务行交错
        let seqs = lines(of: e1).map { int($0["seq"]) }
        XCTAssertEqual(seqs, seqs.sorted())
        // 第二个 error 只带新的 ctx
        let through = int(e1["seq_to"])
        for i in 0..<5 { h.client.log(.info, "between \(i)") }
        h.client.log(.error, "e2")
        await h.tick(advance: 10_000)
        let all = h.envelopes("p0").map(\.1)
        XCTAssertEqual(all.count, 2)
        let e2 = try XCTUnwrap(all.first { int($0["oseq_from"]) == 2 })
        let ctx2 = lines(of: e2).filter { $0["ctx"] as? Bool == true }
        XCTAssertEqual(ctx2.map { $0["msg"] as? String }, (0..<5).map { "between \($0)" })
        XCTAssertTrue(ctx2.allSatisfy { int($0["seq"]) > through })
        XCTAssertEqual(int(e2["ctx_truncated"]), 0)
        let results = try runValidator(all)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    func testDailyCapMergesP1AndSplitsAt768KB() async throws {
        var o = Options()
        o.dailyBatchCap = 1
        let h = Harness(key: "", options: o)
        await h.settle()
        h.client.log(.warn, "first")
        await h.seal()
        XCTAssertEqual(h.outboxFiles("p1").count, 1)
        // 超出上限的 p1 推迟：每段 ~512 KB 的 warn，封 3 段
        let big = String(repeating: "w", count: 4000)
        for _ in 0..<3 {
            let seg = h.client.writer.snapshot.segNo
            while h.client.writer.snapshot.segNo == seg { h.client.log(.warn, big) }
            await h.settle()
        }
        XCTAssertEqual(h.outboxFiles().count, 1, "p1 被推迟合并")
        // p0 不受限，并把推迟的义务行一起物化（按 768 KB 切多批，oseq 首尾相接）
        h.client.log(.error, "boom")
        await h.seal(.error)
        let envs = h.envelopes().map(\.1).sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
        XCTAssertGreaterThanOrEqual(envs.count, 4)
        for i in 1..<envs.count { XCTAssertEqual(int(envs[i]["oseq_from"]), int(envs[i - 1]["oseq_to"]) + 1) }
        XCTAssertEqual(int(envs.last!["oseq_to"]), h.client.debugCounters.oseq)
        for e in envs {
            let size = try JSONSerialization.data(withJSONObject: e).count
            XCTAssertLessThanOrEqual(size, Limits.batchUncompressedBytesClient)
        }
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        let results = try runValidator(envs)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    func testFlushReturnsStoredAfterAck() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.info, "user tapped report")
        h.client.log(.warn, "problem")
        let r = await h.client.flush(includeContext: true)
        XCTAssertEqual(r, .stored)
        let e = try XCTUnwrap(h.transport.batchRequests.last.flatMap { decodeEnvelope($0.body!) })
        XCTAssertEqual(lines(of: e).first?["ctx"] as? Bool, true, "flush 视同 error：带 ctx")
        h.transport.defaultReply = .network
        h.client.log(.warn, "offline")
        let r2 = await h.client.flush()
        XCTAssertEqual(r2, .pending("backoff"))
        h.client.setEnabled(false)
        let r3 = await h.client.flush()
        XCTAssertEqual(r3, .pending("disabled"))
    }
}

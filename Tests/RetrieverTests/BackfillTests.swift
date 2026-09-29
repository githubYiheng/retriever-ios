import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// backfill（full_dump 生效；主代理 2026-09-29 裁决）：RETAINED 段中全部非义务行按段成批，不受 ctx_through_seq 限制。
final class BackfillTests: XCTestCase {
    func testBackfillIncludesLinesAlreadySentAsCtx() async throws {
        let h = Harness(key: "")
        await h.settle()
        for i in 0..<5 { h.client.log(.debug, "before error \(i)") }
        h.client.log(.error, "e")
        await h.tick(advance: 2000)
        let p0 = try XCTUnwrap(h.envelopes("p0").first?.1)
        XCTAssertEqual(lines(of: p0).filter { $0["ctx"] as? Bool == true }.count, 5)
        h.client.log(.info, "after")
        await h.seal()
        await h.work { $0.materializeBackfill() }
        let bfs = h.envelopes("p2").map(\.1).sorted { int($0["seq_from"]) < int($1["seq_from"]) }
        XCTAssertEqual(bfs.count, 2, "每段一批")
        XCTAssertEqual(lines(of: bfs[0]).map { $0["msg"] as? String }, (0..<5).map { "before error \($0)" }, "已作为 ctx 上传过的行也回传")
        XCTAssertEqual(lines(of: bfs[1]).map { $0["msg"] as? String }, ["after"])
        let iid = h.client.installId!
        let sid = h.client.writer.currentSessionId
        XCTAssertEqual(bfs[0]["batch_id"] as? String, IDs.batchId(installId: iid, sessionId: sid, kind: .backfill, n: 1))
        XCTAssertEqual(bfs[1]["batch_id"] as? String, IDs.batchId(installId: iid, sessionId: sid, kind: .backfill, n: 2))
        // ctx_through_seq 不被 backfill 推进；同一进程内不重复生成
        await h.work { $0.materializeBackfill() }
        XCTAssertEqual(h.outboxFiles("p2").count, 2)
        let results = try runValidator(bfs)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    func testOversizedSegmentSplitsBySeqWithThreePartName() async throws {
        let h = Harness(key: "")
        await h.settle()
        for i in 0..<30 { h.client.log(.debug, "d\(i) " + String(repeating: "x", count: 300)) }
        await h.seal()
        await h.work { $0.materializeBackfill(budget: 4096) }
        let parts = h.envelopes("p2").map(\.1).sorted { int($0["seq_from"]) < int($1["seq_from"]) }
        XCTAssertGreaterThan(parts.count, 1)
        let iid = h.client.installId!
        let sid = h.client.writer.currentSessionId
        var next: Int64 = 1
        for p in parts {
            XCTAssertEqual(int(p["seq_from"]), next, "按 seq 首尾相接")
            next = int(p["seq_to"]) + 1
            let name = "\(iid):\(sid):backfill:1:\(int(p["seq_from"]))"
            XCTAssertEqual(p["batch_id"] as? String, IDs.uuidv5(namespace: IDs.namespace, name: name))
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: p).count, 4096 + 400)
        }
        XCTAssertEqual(next, 31)
        let results = try runValidator(parts)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }
}

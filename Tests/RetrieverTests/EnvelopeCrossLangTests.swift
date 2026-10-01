import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 跨语言信封校验：Swift 物化出的 ≥ 6 种批都要过 packages/core 的 validateEnvelope（服务端同一份代码）。
final class EnvelopeCrossLangTests: XCTestCase {
    struct Expect {
        var name: String
        var env: [String: Any]
        var lines: Int
        var errors: Int
        var warn: Bool
    }

    func expect(_ name: String, _ env: [String: Any]) -> Expect {
        let ls = lines(of: env)
        let rank: [String: Int] = ["debug": 0, "info": 1, "warn": 2, "error": 3, "fatal": 4]
        let errors = ls.filter { (rank[$0["level"] as? String ?? ""] ?? 0) >= 3 && $0["ctx"] as? Bool != true }.count
        let warn = ls.contains { (rank[$0["level"] as? String ?? ""] ?? 0) >= 2 }
        return Expect(name: name, env: env, lines: ls.count, errors: errors, warn: warn)
    }

    func testMaterializedBatchesPassServerValidator() async throws {
        var cases: [Expect] = []

        // 1. 纯 warn
        do {
            let h = Harness(key: "")
            await h.settle()
            h.client.log(.info, "i")
            h.client.log(.warn, "w1", tag: "net", attrs: ["ms": .number(3200), "ok": .bool(false), "u": .string("/v1")])
            h.client.log(.warn, "w2 日志🐶")
            await h.seal()
            let e = try XCTUnwrap(h.envelopes().first?.1)
            XCTAssertEqual(lines(of: e).count, 2)
            XCTAssertNil(e["ctx_truncated"])
            cases.append(expect("pure_warn", e))
        }

        // 2 / 3. error 带 ctx 跨段；ctx 被字节预算截断
        do {
            let h = Harness(key: "")
            await h.settle()
            while h.client.writer.snapshot.segNo == 1 { h.client.log(.debug, "old " + String(repeating: "o", count: 2000)) }
            for i in 0..<10 { h.client.log(.info, "new \(i)") }
            struct Boom: Error {}
            h.client.log(.error, "failed", tag: "billing", error: Boom())
            await h.tick(advance: 2000)
            let e = try XCTUnwrap(h.envelopes("p0").first?.1)
            let ctx = lines(of: e).filter { $0["ctx"] as? Bool == true }
            XCTAssertGreaterThan(ctx.count, 10, "跨段")
            XCTAssertLessThan(ctx.count, Limits.ctxLinesDefault, "字节预算先到")
            XCTAssertGreaterThan(int(e["ctx_truncated"]), 0)
            let ctxBytes = ctx.reduce(0) { $0 + ((try? JSONSerialization.data(withJSONObject: $1).count) ?? 0) + 1 }
            XCTAssertLessThanOrEqual(ctxBytes, Limits.ctxBytesDefault + 2000)
            cases.append(expect("error_ctx_cross_segment_truncated", e))
        }

        // 4. drops / closed_sessions / mapping（旧会话恢复 + 墓碑 + 映射）
        do {
            let root = makeTempDir()
            let a = Harness(root: root, key: "")
            await a.settle()
            a.client.log(.info, "before crash")
            a.client.log(.warn, "a warn")
            let aSid = a.client.writer.currentSessionId
            // 墓碑记在另一个（更早的）会话名下：墓碑随下一个 primary 批上报、不限会话；记在 a 名下的话 oseq_to 会抬高
            // a 的恢复高水位（0.1.4），a 的恢复批会在缺口处切开，extras 与合成行就不在同一批里了
            let otherSid = IDs.newV4()
            _ = await a.work { e in
                e.appendDrops([DropEntry(sessionId: otherSid, oseqFrom: 7, oseqTo: 9, n: 3, reason: "buffer_overflow", atMs: 1, lastAckAgeMs: 86_400_000)])
            }
            a.client.simulateCrash()
            let b = Harness(root: root, key: "")   // 同一 root 再启动：a 的会话成了孤儿（last_state = fg）
            await b.settle()
            b.client.setUser("u_1024")
            b.client.log(.warn, "b warn")
            await b.seal()
            let envs = b.envelopes().map(\.1)
            let rec = try XCTUnwrap(envs.first { $0["session_id"] as? String == aSid })
            XCTAssertEqual((rec["closed_sessions"] as? [[String: Any]])?.first?["exit"] as? String, "unclean_fg")
            XCTAssertEqual((rec["drops"] as? [[String: Any]])?.count, 1)
            XCTAssertNil(rec["mapping"], "旧会话批不带 mapping")
            XCTAssertTrue(lines(of: rec).contains { $0["synthetic"] as? Bool == true })
            let cur = try XCTUnwrap(envs.first { $0["session_id"] as? String != aSid })
            XCTAssertEqual((cur["mapping"] as? [String: Any])?["user_id"] as? String, "u_1024")
            XCTAssertEqual(cur["user_id"] as? String, "u_1024")
            cases.append(expect("recovered_with_drops_closed", rec))
            cases.append(expect("with_mapping", cur))
        }

        // 5. 413 切分后的两半
        do {
            let h = Harness()
            await h.settle()
            h.transport.setScript([.status(413, ["reason": "too_large", "max_bytes": 1_048_576], [:])])
            h.client.log(.debug, "ctx")
            for i in 1...5 { h.client.log(.warn, "w\(i)") }
            await h.sealAndDrain()
            let halves = h.envelopes().map(\.1).sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
            XCTAssertEqual(halves.count, 2)
            XCTAssertEqual(int(halves[0]["oseq_to"]) + 1, int(halves[1]["oseq_from"]))
            cases.append(expect("split_413_a", halves[0]))
            cases.append(expect("split_413_b", halves[1]))
        }

        // 6. backfill（full_dump 生效）
        do {
            let h = Harness(key: "")
            await h.settle()
            for i in 0..<20 { h.client.log(i % 2 == 0 ? .debug : .info, "history \(i)") }
            h.client.log(.warn, "w")
            await h.seal()
            h.transport.configBody = ["etag": "e1", "ttl_s": 600, "full_dump": true, "full_dump_ttl_s": 3600]
            h.transport.defaultReply = .status(503, nil, [:])     // 不确认，批留在出站箱里供检查
            await h.enableUpload()
            let bf = try XCTUnwrap(h.envelopes("p2").first?.1)
            XCTAssertEqual(bf["kind"] as? String, "backfill")
            XCTAssertNil(bf["oseq_from"])
            XCTAssertEqual(lines(of: bf).count, 20)
            XCTAssertTrue(lines(of: bf).allSatisfy { $0["oseq"] == nil && $0["ctx"] == nil })
            // 生效后新写的 debug 行直接是义务行
            h.client.log(.debug, "now obligation")
            XCTAssertEqual(h.client.debugCounters.oseq, 2)
            cases.append(expect("backfill", bf))
        }

        // 7. fatal（只落盘）
        do {
            let h = Harness(key: "")
            await h.settle()
            h.client.log(.info, "last words")
            h.client.log(.fatal, "fatal", error: NSError(domain: "D", code: 1))
            await h.settle()   // fatal 的封段物化在后台（ADR 0020）
            cases.append(expect("fatal", try XCTUnwrap(h.envelopes("p0").first?.1)))
        }

        XCTAssertGreaterThanOrEqual(cases.count, 6)
        let results = try runValidator(cases.map(\.env))
        XCTAssertEqual(results.count, cases.count)
        for (c, r) in zip(cases, results) {
            XCTAssertEqual(r["ok"] as? Bool, true, "\(c.name): \(r)")
            let st = r["stats"] as? [String: Any] ?? [:]
            XCTAssertEqual(int(st["lines"]), Int64(c.lines), c.name)
            XCTAssertEqual(int(st["errors"]), Int64(c.errors), c.name)
            XCTAssertEqual(st["hasWarnOrAbove"] as? Bool, c.warn, c.name)
        }
        print("[validator]", zip(cases, results).map { "\($0.name)=\(($1["stats"] as? [String: Any])?["lines"] ?? "?")" }.joined(separator: " "))
    }
}

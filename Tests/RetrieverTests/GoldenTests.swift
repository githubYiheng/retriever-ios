import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// golden 向量（packages/core/golden）：三端与服务端逐字一致。
final class GoldenTests: XCTestCase {
    func testIdsUuidv5() throws {
        let g = try Repo.golden("ids.json")
        XCTAssertEqual(g["retriever_namespace"] as? String, IDs.namespace)
        let vs = try XCTUnwrap(g["uuidv5"] as? [[String: Any]])
        XCTAssertGreaterThan(vs.count, 0)
        for v in vs {
            XCTAssertEqual(IDs.uuidv5(namespace: v["namespace"] as! String, name: v["name"] as! String), v["expect"] as? String,
                           "\(v["name"] ?? "")")
        }
    }

    func testIdsBatchId() throws {
        let g = try Repo.golden("ids.json")
        for v in try XCTUnwrap(g["batch_id"] as? [[String: Any]]) {
            let kind = IDs.BatchKind(rawValue: v["kind"] as! String)!
            let n = int(v["n"])
            let iid = v["install_id"] as! String
            let sid = v["session_id"] as! String
            XCTAssertEqual(IDs.batchIdName(installId: iid, sessionId: sid, kind: kind, n: n), v["name"] as? String)
            XCTAssertEqual(IDs.batchId(installId: iid, sessionId: sid, kind: kind, n: n), v["expect"] as? String)
        }
        for v in try XCTUnwrap(g["batch_id_invalid"] as? [[String: Any]]) {
            let kind = IDs.BatchKind(rawValue: v["kind"] as! String)!
            // n 非整数（1.5）在 Swift 的 Int64 接口里不可表达：同样视为拒绝
            guard let n = JSONIn.int64(v["n"]) else { continue }
            XCTAssertNil(IDs.batchId(installId: v["install_id"] as! String, sessionId: v["session_id"] as! String, kind: kind, n: n),
                         "\(v["why"] ?? "")")
        }
    }

    /// backfill 切分 batch_id（三段 name）：与 `uuidv5(ns, "<install>:<session>:backfill:<seg_no>:<seq_from>")` 一致。
    func testBackfillSplitBatchIdName() {
        let iid = "3f2c9a4e-8b1d-4c7a-9e5f-0a1b2c3d4e5f"
        let sid = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        let bid = IDs.backfillSplitBatchId(installId: iid, sessionId: sid, segNo: 3, seqFrom: 1201)
        XCTAssertEqual(bid, IDs.uuidv5(namespace: IDs.namespace, name: "\(iid):\(sid):backfill:3:1201"))
        XCTAssertNotEqual(bid, IDs.batchId(installId: iid, sessionId: sid, kind: .backfill, n: 3))
        XCTAssertTrue(IDs.isUuid(bid!))
        XCTAssertNil(IDs.backfillSplitBatchId(installId: iid.uppercased(), sessionId: sid, segNo: 3, seqFrom: 1))
    }

    func testIdsUuidRegex() throws {
        let g = try Repo.golden("ids.json")
        for s in try XCTUnwrap(g["uuid_valid"] as? [String]) { XCTAssertTrue(IDs.isUuid(s), s) }
        for v in try XCTUnwrap(g["uuid_invalid"] as? [[String: Any]]) {
            XCTAssertFalse(IDs.isUuid(v["value"] as! String), "\(v["why"] ?? "")")
        }
        // 新生成的 v4 必须过 UUID_RE
        for _ in 0..<100 { XCTAssertTrue(IDs.isUuid(IDs.newV4())) }
    }

    func testClientDay() throws {
        let g = try Repo.golden("object-key.json")
        let vs = try XCTUnwrap(g["client_day"] as? [[String: Any]])
        XCTAssertGreaterThan(vs.count, 0)
        for v in vs {
            XCTAssertEqual(Day.clientDay(tsMinMs: int(v["ts_min_ms"]), createdMs: int(v["created_ms"])), v["expect"] as? String,
                           "\(v["name"] ?? "")")
        }
        for v in try XCTUnwrap(g["day_from_ms"] as? [[String: Any]]) {
            XCTAssertEqual(Day.fromMs(int(v["ms"])), v["expect"] as? String)
        }
    }

    func testConfigClamp() throws {
        let g = try Repo.golden("config.json")
        let vs = try XCTUnwrap(g["clamp"] as? [[String: Any]])
        XCTAssertEqual(vs.count, 53)
        for v in vs {
            let name = v["name"] as? String ?? ""
            let h = try XCTUnwrap(v["host"] as? [String: Any])
            let host = HostDefaults(uploadLevel: LogLevel(rawValue: h["uploadLevel"] as? String ?? "") ?? .warn,
                                    localLevel: (h["localLevel"] as? String).flatMap(LogLevel.init(rawValue:)),
                                    dailyBatchCap: JSONIn.int64(h["dailyBatchCap"]).map { Int($0) })
            let raw: Any? = (v["raw"] is NSNull) ? nil : v["raw"]
            let c = ConfigRules.clamp(raw, host: host)
            let e = try XCTUnwrap(v["expect"] as? [String: Any])
            XCTAssertEqual(c.etag, e["etag"] as? String, name)
            XCTAssertEqual(Int64(c.ttlS), int(e["ttl_s"]), name)
            XCTAssertEqual(c.uploadEnabled, e["upload_enabled"] as? Bool, name)
            XCTAssertEqual(c.uploadLevel.rawValue, e["upload_level"] as? String, name)
            XCTAssertEqual(c.localLevel.rawValue, e["local_level"] as? String, name)
            XCTAssertEqual(Int64(c.contextLines), int(e["context_lines"]), name)
            XCTAssertEqual(Int64(c.contextBytes), int(e["context_bytes"]), name)
            XCTAssertEqual(Int64(c.flushIntervalS), int(e["flush_interval_s"]), name)
            XCTAssertEqual(Int64(c.localCapBytes), int(e["local_cap_bytes"]), name)
            XCTAssertEqual(c.fullDump, e["full_dump"] as? Bool, name)
            XCTAssertEqual(Int64(c.fullDumpTtlS), int(e["full_dump_ttl_s"]), name)
            XCTAssertEqual(c.backfillNetworks, e["backfill_networks"] as? String, name)
            XCTAssertEqual(Int64(c.dailyBatchCap), int(e["daily_batch_cap"]), name)
            XCTAssertEqual(Set(e.keys).count, 13, name)
        }
    }

    /// 缓存过期后放大型字段回落（宪法 U-2）。
    func testExpiredCacheRevertsAmplifyingFields() {
        let host = HostDefaults(uploadLevel: .warn)
        var raw: [String: Any] = ["ttl_s": 60, "upload_level": "debug", "context_lines": 500, "context_bytes": 262144,
                                  "flush_interval_s": 30, "full_dump": true, "full_dump_ttl_s": 3600, "local_cap_bytes": 104857600]
        let cfg = ConfigRules.clamp(raw, host: host)
        let cache = ConfigCache(config: cfg, fetchedWallMs: 0, fetchedMonoMs: 1000)
        let live = ConfigCache.effective(cache, host: host, nowWall: 0, nowMono: 1000 + 59_000)
        XCTAssertTrue(live.fullDumpActive)
        XCTAssertEqual(live.uploadLevel, .debug)
        XCTAssertEqual(live.config.contextLines, 500)
        let exp = ConfigCache.effective(cache, host: host, nowWall: 0, nowMono: 1000 + 60_000)
        XCTAssertFalse(exp.fullDumpActive)
        XCTAssertEqual(exp.uploadLevel, .warn)
        XCTAssertEqual(exp.config.contextLines, Limits.ctxLinesDefault)
        XCTAssertEqual(exp.config.contextBytes, Limits.ctxBytesDefault)
        XCTAssertEqual(exp.config.flushIntervalS, Limits.flushIntervalSDefault)
        XCTAssertEqual(exp.config.localCapBytes, Limits.localCapBytesDefault)
        // 重启后（无单调基准）用墙钟兜底
        let cold = ConfigCache(config: cfg, fetchedWallMs: 5000, fetchedMonoMs: nil)
        XCTAssertTrue(ConfigCache.effective(cold, host: host, nowWall: 5000 + 30_000, nowMono: 0).fullDumpActive)
        XCTAssertFalse(ConfigCache.effective(cold, host: host, nowWall: 5000 + 61_000, nowMono: 0).fullDumpActive)
        raw["upload_level"] = "error"
        let quiet = ConfigCache(config: ConfigRules.clamp(raw, host: host), fetchedWallMs: 0, fetchedMonoMs: 0)
        // 高于宿主默认（更少上传）的级别过期后不回落（只回落放大型）
        XCTAssertEqual(ConfigCache.effective(quiet, host: host, nowWall: 0, nowMono: 999_999).uploadLevel, .error)
    }

    func testJSNumberFormatting() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-5, "-5"), (0.1, "0.1"), (123.456, "123.456"), (1e21, "1e+21"),
            (1e20, "100000000000000000000"), (1.5e-7, "1.5e-7"), (1e-7, "1e-7"), (0.000001, "0.000001"),
            (Double("123456789012345680000")!, "123456789012345680000"), (Double("9007199254740993")!, "9007199254740992"),
            (2.5e300, "2.5e+300"), (5e-324, "5e-324"), (-1.25, "-1.25"),
        ]
        for (d, s) in cases { XCTAssertEqual(JSONOut.jsNumber(d), s, "\(d)") }
    }
}

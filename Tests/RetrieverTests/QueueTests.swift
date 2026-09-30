import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 出站队列与响应分类（方案 §3.6 / §3.7；宪法 R-2 / R-3）。假 transport 按脚本回响应，断言队列动作。
final class QueueTests: XCTestCase {
    func env(_ r: HTTPRequest) -> [String: Any] { decodeEnvelope(r.body ?? Data()) ?? [:] }

    func testAckWithEchoDeletesFile() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.info, "ctx")
        h.client.log(.warn, "w1")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        XCTAssertEqual(h.outboxFiles(), [])
        let r = h.transport.batchRequests[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://logs-test.invalid/v1/batches")
        XCTAssertEqual(r.headers["Authorization"], "Bearer lk_test_demo_abc_12345678")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertEqual(r.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(r.headers["X-Rtv-Install"], h.client.installId)
        XCTAssertEqual(r.headers["X-Rtv-Sent-Ms"], String(h.clock.wallMs()))
        XCTAssertEqual(r.headers["X-Rtv-Sdk"], "retriever-ios/\(RetrieverVersion.current)")
        let e = env(r)
        XCTAssertEqual(e["kind"] as? String, "primary")
        XCTAssertEqual(int(e["oseq_from"]), 1)
        XCTAssertEqual(lines(of: e).count, 1, "纯 warn 批不带 ctx")
        XCTAssertEqual(lines(of: e).first?["msg"] as? String, "w1")
        let b = await h.work { $0.backoff }
        XCTAssertEqual(b.attempt, 0)
        XCTAssertEqual(b.lastAckMs, h.clock.wallMs())
        // mapping 块已被确认 → mapping.json
        let m = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.root.appendingPathComponent("mapping.json"))) as? [String: Any])
        XCTAssertTrue(m["user_id"] is NSNull)
        XCTAssertEqual(int(m["acked_ms"]), h.clock.wallMs())
    }

    func testEchoMismatchKeepsFileAndBacksOff() async throws {
        let h = Harness()
        await h.settle()
        h.transport.setScript([.echoWrong])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        XCTAssertEqual(h.outboxFiles().count, 1)
        let (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.attempt, 1)
        XCTAssertGreaterThanOrEqual(b.nextAtMonoMs - now, 800)
        XCTAssertLessThanOrEqual(b.nextAtMonoMs - now, 1200)
        XCTAssertEqual(b.reason, "echo_mismatch")
        // 退避期内不发（且相邻请求 ≥ 2 s）
        await h.tick(advance: 700)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        await h.tick(advance: 1300)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertEqual(h.outboxFiles(), [])
        // backoff.json 已持久化
        let bj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.root.appendingPathComponent("backoff.json"))) as? [String: Any])
        XCTAssertEqual(int(bj["attempt"]), 0)
    }

    func testUnauthorizedPausesOneHourThenDoubles() async throws {
        let h = Harness()
        await h.settle()
        h.transport.setScript([.status(401, ["reason": "key_invalid"], [:]), .status(403, ["reason": "app_disabled"], [:])])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        var (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedCategories, ["all"])
        XCTAssertEqual(b.pausedUntilMono - now, 3_600_000)
        XCTAssertEqual(h.outboxFiles().count, 1, "不删任何文件")
        // 照常写本地
        h.client.log(.warn, "still written")
        XCTAssertEqual(h.client.debugCounters.oseq, 2)
        await h.tick(advance: 3_599_000)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        await h.tick(advance: 1_000)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedUntilMono - now, 7_200_000)
        XCTAssertEqual(h.outboxFiles().count, 2, "warn 计时封出的第二批也在，均未删")
        // 暂停期间照常拉配置
        let cfgBefore = h.transport.configRequests.count
        await h.tick(advance: Int64(Limits.configPollIntervalS) * 1000)
        XCTAssertGreaterThan(h.transport.configRequests.count, cfgBefore)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        // 24 h 封顶
        for _ in 0..<6 {
            await h.work { e in
                e.backoff.pausedUntilMono = 0
                e.backoff.pausedCategories = []
            }
            h.transport.setScript([.status(401, ["reason": "key_invalid"], [:])])
            await h.tick(advance: Limits.minRequestSpacingMs)
        }
        (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedUntilMono - now, Limits.pause401MaxMs)
    }

    /// 非服务端表态的 401 / 403（空体、HTML、无 reason / reason 非字符串的 JSON）按「其它」：全局退避 + 计 fail，不暂停（ADR 0011）。
    func testUnauthorizedWithoutReasonIsOrdinaryBackoff() async throws {
        let cases: [(FakeTransport.Reply, String)] = [
            (.status(403, nil, [:]), "http_403"),
            (.raw(401, Data("<html><body>Access denied | Cloudflare</body></html>".utf8), ["content-type": "text/html"]), "http_401"),
            (.status(403, ["error": "x"], [:]), "http_403"),
            (.status(401, ["reason": 1], [:]), "http_401"),
        ]
        for (reply, reason) in cases {
            let h = Harness()
            await h.settle()
            h.transport.setScript([reply])
            h.client.log(.warn, "w")
            await h.sealAndDrain()
            XCTAssertEqual(h.transport.batchRequests.count, 1)
            let (b, now, fails) = await h.work { ($0.backoff, $0.clock.monoMs(), $0.fails.values.map(\.count)) }
            XCTAssertEqual(b.reason, reason)
            XCTAssertEqual(b.pausedCategories, [], reason)
            XCTAssertEqual(b.pausedUntilMono, 0, reason)
            XCTAssertEqual(b.attempt, 1)
            XCTAssertGreaterThanOrEqual(b.nextAtMonoMs - now, 800)
            XCTAssertLessThanOrEqual(b.nextAtMonoMs - now, 1200)
            XCTAssertEqual(fails, [1], "计毒批失败")
            XCTAssertEqual(h.outboxFiles().count, 1, "不删")
            // 约 1 s 退避（相邻请求另有 2 s 间隔）后重试并确认
            await h.tick(advance: Limits.minRequestSpacingMs)
            XCTAssertEqual(h.transport.batchRequests.count, 2, reason)
            XCTAssertEqual(h.outboxFiles(), [])
        }
    }

    /// 带 reason 的 401 / 403 仍暂停 1 h → 2 h；暂停到期后一次 2xx 确认复位倍增状态，再遇（未知 reason 的）403 从 1 h 起步。
    func testAuthPauseDoublingResetsAfterAck() async throws {
        let h = Harness()
        await h.settle()
        h.transport.setScript([.status(401, ["reason": "key_invalid"], [:]), .status(401, ["reason": "key_invalid"], [:]),
                               .echo, .status(403, ["reason": "some_future_reason"], [:])])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        var (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedCategories, ["all"])
        XCTAssertEqual(b.pausedUntilMono - now, 3_600_000)
        await h.tick(advance: 3_600_000)
        (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedUntilMono - now, 7_200_000)
        await h.tick(advance: 7_200_000)
        XCTAssertEqual(h.transport.batchRequests.count, 3)
        XCTAssertEqual(h.outboxFiles(), [])
        (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.reason, "")
        XCTAssertEqual(b.pausedCategories, [])
        XCTAssertEqual(b.pausedUntilMono, 0)
        XCTAssertEqual(b.pausedUntilMs, 0)
        let bj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.root.appendingPathComponent("backoff.json"))) as? [String: Any])
        XCTAssertEqual(bj["reason"] as? String, "")
        XCTAssertEqual(bj["paused_categories"] as? [String], [])
        h.clock.advance(Limits.minRequestSpacingMs)
        h.client.log(.warn, "w2")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 4)
        (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedCategories, ["all"])
        XCTAssertEqual(b.pausedUntilMono - now, 3_600_000, "确认后从 1 h 起步")
    }

    /// 读不出的批跳过、试下一个（不删、不隔离、不计 fail）；只剩读不出的 → 停在 unreadable；可读后照常发（发版前审查 A1）。
    func testUnreadableBatchIsSkippedNotRecursed() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "older")
        await h.seal()
        h.clock.advance(10)
        h.client.log(.warn, "newer")
        await h.seal()
        let names = h.outboxFiles()
        XCTAssertEqual(names.count, 2)
        let bad = h.outbox.appendingPathComponent(names[0])
        XCTAssertEqual(chmod(bad.path, 0), 0)
        await h.enableUpload()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        XCTAssertEqual(lines(of: env(try XCTUnwrap(h.transport.batchRequests.first))).first?["msg"] as? String, "newer")
        XCTAssertEqual(h.outboxFiles(), [names[0]], "读不出的留在出站箱")
        await h.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertEqual(h.client.debugLastStopReason, "unreadable")
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        let fails = await h.work { $0.fails.count }
        XCTAssertEqual(fails, 0, "不计 fail")
        XCTAssertEqual(h.outboxFiles(), [names[0]], "不删、不隔离")
        XCTAssertEqual(chmod(bad.path, 0o600), 0)
        await h.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testTooLargeSplitsIntoContiguousHalves() async throws {
        let h = Harness()
        await h.settle()
        h.transport.setScript([.status(413, ["reason": "too_large", "max_bytes": 1_048_576], [:]), .echo, .echo])
        for i in 1...6 { h.client.log(i == 5 ? .error : .warn, "w\(i)") }
        h.client.log(.debug, "ctx after")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        let original = env(h.transport.batchRequests[0])
        XCTAssertEqual(int(original["oseq_from"]), 1)
        XCTAssertEqual(int(original["oseq_to"]), 6)
        XCTAssertEqual(h.outboxFiles().count, 2)
        await h.tick(advance: 2000)
        await h.tick(advance: 2000)
        XCTAssertEqual(h.transport.batchRequests.count, 3)
        XCTAssertEqual(h.outboxFiles(), [])
        let a = env(h.transport.batchRequests[1])
        let b = env(h.transport.batchRequests[2])
        let halves = [a, b].sorted { int($0["oseq_from"]) < int($1["oseq_from"]) }
        XCTAssertEqual(int(halves[0]["oseq_from"]), 1)
        XCTAssertEqual(int(halves[0]["oseq_to"]), 3)
        XCTAssertEqual(int(halves[1]["oseq_from"]), 4)
        XCTAssertEqual(int(halves[1]["oseq_to"]), 6)
        let iid = h.client.installId!
        let sid = original["session_id"] as! String
        XCTAssertEqual(halves[0]["batch_id"] as? String, IDs.batchId(installId: iid, sessionId: sid, kind: .primary, n: 1))
        XCTAssertEqual(halves[1]["batch_id"] as? String, IDs.batchId(installId: iid, sessionId: sid, kind: .primary, n: 4))
        // ctx 跟着含 error 的那一半；p0 先发
        XCTAssertEqual(int(a["oseq_from"]), 4)
        XCTAssertTrue(lines(of: halves[1]).contains { $0["ctx"] as? Bool == true })
        XCTAssertFalse(lines(of: halves[0]).contains { $0["ctx"] as? Bool == true })
        let results = try runValidator([a, b])
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    func testRateLimitedInfoBackfillPausesOnlyThoseCategories() async throws {
        var o = Options()
        o.uploadLevel = .info
        let h = Harness(options: o)
        await h.settle()
        h.transport.setScript([.status(429, ["reason": "quota", "categories": ["info", "backfill"], "retry_after_s": 60], ["retry-after": "60"])])
        h.client.log(.info, "pure info")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        // backfill 批（debug 行在 info 模式下不是义务行）
        h.client.log(.debug, "debug 1")
        h.client.log(.debug, "debug 2")
        await h.seal()
        await h.work { $0.materializeBackfill() }
        XCTAssertEqual(h.outboxFiles("p2").count, 1)
        // p0 照发
        h.client.log(.error, "boom")
        await h.sealAndDrain()
        await h.tick(advance: 2000)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertTrue((env(h.transport.batchRequests[1])["lines"] as? [[String: Any]] ?? []).contains { $0["level"] as? String == "error" })
        await h.tick(advance: 2000)
        XCTAssertEqual(h.transport.batchRequests.count, 2, "info / backfill 仍暂停")
        XCTAssertEqual(h.outboxFiles("p1").count, 1)
        XCTAssertEqual(h.outboxFiles("p2").count, 1)
        let b = await h.work { $0.backoff }
        XCTAssertEqual(Set(b.pausedCategories), ["info", "backfill"])
        XCTAssertEqual(b.attempt, 0, "429 不计退避与毒批")
        await h.tick(advance: 73_000)
        await h.tick(advance: 2000)
        XCTAssertEqual(h.transport.batchRequests.count, 4)
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testRateLimitedAllPausesEverything() async throws {
        let h = Harness()
        await h.settle()
        h.transport.setScript([.status(429, ["reason": "rate", "categories": ["all"], "retry_after_s": 30], ["retry-after": "30"])])
        h.client.log(.error, "e")
        await h.sealAndDrain()
        let (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.pausedCategories, ["all"])
        XCTAssertGreaterThanOrEqual(b.pausedUntilMono - now, 24_000)
        XCTAssertLessThanOrEqual(b.pausedUntilMono - now, 36_000)
        await h.tick(advance: 23_000)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        await h.tick(advance: 14_000)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testServiceUnavailableBackoffCurve() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .status(503, ["reason": "storage"], [:])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        var curve: [Int64] = []
        for i in 0..<14 {
            let (b, now) = await h.work { ($0.backoff, $0.clock.monoMs()) }
            let base = min(Int64(1000) << Int64(i), Limits.backoffMaxMs)
            let wait = b.nextAtMonoMs - now
            curve.append(wait)
            XCTAssertGreaterThanOrEqual(wait, base * 8 / 10, "attempt \(i)")
            XCTAssertLessThanOrEqual(wait, base * 12 / 10, "attempt \(i)")
            XCTAssertEqual(b.attempt, i + 1)
            await h.tick(advance: max(wait, 2000))
            XCTAssertEqual(h.transport.batchRequests.count, i + 2)
        }
        print("[backoff] 503 curve (ms):", curve)
        XCTAssertEqual(h.outboxFiles("p1").count, 1, "503 不隔离、不删")
        // Retry-After 大于退避时取 Retry-After（钳制 1 s–1 h）
        await h.work { $0.backoff.attempt = 0 }
        h.transport.defaultReply = .status(503, ["reason": "storage", "retry_after_s": 120], ["retry-after": "120"])
        await h.tick(advance: Limits.backoffMaxMs * 2)
        let (b2, now2) = await h.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b2.nextAtMonoMs - now2, 120_000)
    }

    func testPoisonBatchQuarantinedAfterFiveFailuresWhenOthersSucceed() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "poison")
        await h.seal()
        h.clock.advance(10)
        h.client.log(.warn, "good")
        await h.seal()
        let names = h.outboxFiles()
        XCTAssertEqual(names.count, 2)
        let poisonId = String(names[0].dropFirst(3 + 13 + 1).dropLast(3))
        h.transport.responder = { bid in bid == poisonId ? .status(500, nil, [:]) : .echo }
        await h.enableUpload()
        for _ in 0..<30 {
            if !h.outboxFiles("q-").isEmpty { break }
            await h.tick(advance: Limits.backoffMaxMs + 1)
        }
        let poisonSends = h.transport.batchRequests.filter { FakeTransport.batchId($0.body) == poisonId }.count
        XCTAssertEqual(poisonSends, 5)
        XCTAssertEqual(h.outboxFiles("q-").count, 1)
        XCTAssertTrue(h.outboxFiles("q-")[0].contains(poisonId))
        XCTAssertEqual(h.outboxFiles("p").count, 0)
        // 隔离后不再发；24 h 后回到队列
        let before = h.transport.batchRequests.count
        await h.tick(advance: 3_600_000)
        XCTAssertEqual(h.transport.batchRequests.count, before)
    }

    func testAllFailingIsServerOutageNotPoison() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .status(500, nil, [:])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        for _ in 0..<8 { await h.tick(advance: Limits.backoffMaxMs + 1) }
        XCTAssertEqual(h.transport.batchRequests.count, 9)
        XCTAssertEqual(h.outboxFiles("p1").count, 1)
        XCTAssertEqual(h.outboxFiles("q-").count, 0)
    }

    func testMinimumSpacingTwoSeconds() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "a")
        await h.seal()
        h.client.log(.warn, "b")
        await h.seal()
        await h.enableUpload()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        await h.tick(advance: 1999)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        await h.tick(advance: 1)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testPriorityOrder() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "p1 older")
        await h.seal()
        h.client.log(.debug, "for backfill")
        await h.seal()
        await h.work { $0.materializeBackfill() }
        h.clock.advance(5)
        h.client.log(.error, "p0")
        await h.seal()
        h.clock.advance(5)
        h.client.log(.warn, "p1 newer")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().map { String($0.prefix(2)) }.sorted(), ["p0", "p1", "p1", "p2"])
        await h.enableUpload()
        for _ in 0..<4 { await h.tick(advance: 2000) }
        let order = h.transport.batchRequests.map { r -> String in
            let e = env(r)
            if e["kind"] as? String == "backfill" { return "p2" }
            return lines(of: e).filter { $0["ctx"] == nil }.first?["msg"] as? String ?? "?"
        }
        XCTAssertEqual(order, ["p0", "p1 older", "p1 newer", "p2"])
    }

    func testOfflineNetworkErrorBacksOffWithoutSpinning() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .network
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        // 退避期内反复 tick 不发请求
        for _ in 0..<5 { await h.tick(advance: 100) }
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        // 网络恢复信号：提前唤醒
        h.transport.defaultReply = .echo
        h.client.platformEvent(.networkRestored)
        await h.settle()
        await h.tick(advance: 2000)
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testBackoffPersistsAcrossRestartWithClamp() async throws {
        let h = Harness()
        await h.settle()
        await h.work { e in
            e.backoff.attempt = 12
            e.backoff.nextAtWallMs = e.clock.wallMs() + 3_600_000   // 时钟回拨等造成的远期
            e.persistBackoff()
        }
        let h2 = Harness(root: h.root, clock: h.clock)
        await h2.settle()
        let (b, now) = await h2.work { ($0.backoff, $0.clock.monoMs()) }
        XCTAssertEqual(b.attempt, 12)
        XCTAssertEqual(b.nextAtMonoMs - now, Limits.backoffMaxMs)
    }
}

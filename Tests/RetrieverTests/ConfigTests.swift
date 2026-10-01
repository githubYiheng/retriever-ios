import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 远程配置（方案 §5；宪法 U-1 / U-2）。
final class ConfigTests: XCTestCase {
    func testFetchHeadersAndApply() async throws {
        let t = FakeTransport()
        t.configBody = ["etag": "e1", "ttl_s": 600, "upload_level": "info", "local_level": "info", "flush_interval_s": 60]
        var o = Options()
        o.dailyBatchCap = 7
        let h = Harness(options: o, transport: t)
        await h.settle()
        h.client.setUser("张三 u/1")
        await h.tick(advance: Int64(Limits.configPollIntervalS) * 1000)
        let r = try XCTUnwrap(t.configRequests.last)
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://logs-test.invalid/v1/config")
        XCTAssertEqual(r.headers["Authorization"], "Bearer lk_test_demo_abc_12345678")
        XCTAssertEqual(r.headers["X-Rtv-Install"], h.client.installId)
        XCTAssertEqual(r.headers["X-Rtv-Sdk"], "retriever-ios/\(RetrieverVersion.current)")
        XCTAssertEqual(r.headers["X-Rtv-App-Version"], "1.2.3")
        XCTAssertEqual(r.headers["X-Rtv-Upload-Level"], "warn")
        XCTAssertEqual(r.headers["X-Rtv-Local-Level"], "debug")
        XCTAssertEqual(r.headers["X-Rtv-Daily-Batch-Cap"], "7")
        XCTAssertEqual(r.headers["X-Rtv-Local-Cap-Bytes"], String(20 * 1024 * 1024))
        XCTAssertEqual(r.headers["X-Rtv-User"], "%E5%BC%A0%E4%B8%89%20u%2F1")
        XCTAssertEqual(r.headers["X-Rtv-User"]?.removingPercentEncoding, "张三 u/1")
        // 生效：info 行成义务行，debug 行不写；公开只读级别同步
        XCTAssertEqual(h.client.effectiveLevels.upload, .info)
        XCTAssertEqual(h.client.effectiveLevels.local, .info)
        let before = h.client.debugCounters
        h.client.log(.debug, "filtered")
        h.client.log(.info, "obligation now")
        XCTAssertEqual(h.client.debugCounters.seq, before.seq + 1)
        XCTAssertEqual(h.client.debugCounters.oseq, before.oseq + 1)
        // 缓存到 config.json，重启后按墙钟兜底。缓存记着为谁拉的（user_id，盲审裁决 4）：重启时初始用户是 nil，
        // 所以先切回 nil（按新身份重拉、缓存 user_id = null），重启后才是同一身份、照用缓存
        h.client.setUser(nil)
        await h.settle()
        XCTAssertTrue(h.json("config.json")?.keys.contains("user_id") == true)
        XCTAssertTrue(h.json("config.json")?["user_id"] is NSNull)
        let h2 = Harness(root: h.root, clock: h.clock, transport: FakeTransport())
        await h2.settle()
        let eff = await h2.work { $0.effective }
        XCTAssertEqual(eff.uploadLevel, .info)
        XCTAssertEqual(eff.config.flushIntervalS, 60)
    }

    func testMalformedConfigFallsBackWithoutAmplifying() async throws {
        let t = FakeTransport()
        t.configBody = ["upload_level": "VERBOSE", "context_lines": "lots", "full_dump": "yes", "local_cap_bytes": -5]
        let h = Harness(transport: t)
        await h.settle()
        let eff = await h.work { $0.effective }
        XCTAssertEqual(eff.uploadLevel, .warn)
        XCTAssertFalse(eff.fullDumpActive)
        XCTAssertEqual(eff.config.contextLines, Limits.ctxLinesDefault)
        XCTAssertEqual(eff.config.localCapBytes, Limits.localCapBytesMin)
    }

    func testConfigEtagChangeInBatchResponseTriggersFetch() async throws {
        let t = FakeTransport()
        t.configBody = ["etag": "etag-0", "ttl_s": 1800]
        let h = Harness(transport: t)
        await h.settle()
        let n0 = t.configRequests.count
        h.client.log(.warn, "a")
        await h.sealAndDrain()
        XCTAssertEqual(t.configRequests.count, n0, "etag 未变不拉")
        t.configEtag = "etag-1"
        h.client.log(.warn, "b")
        await h.sealAndDrain()
        await h.tick(advance: 2000)
        await h.settle()
        XCTAssertEqual(t.configRequests.count, n0 + 1)
    }

    func testUploadDisabledWritesButDoesNotSend() async throws {
        let t = FakeTransport()
        t.configBody = ["etag": "x", "upload_enabled": false]
        let h = Harness(transport: t)
        await h.settle()
        h.client.log(.warn, "kept locally")
        await h.sealAndDrain()
        XCTAssertEqual(t.batchRequests.count, 0)
        XCTAssertEqual(h.outboxFiles().count, 1)
        let r = await h.client.flush()
        XCTAssertEqual(r, .pending("paused"))
        XCTAssertEqual(h.outboxFiles().count, 2, "flush 的批也只落盘")
        // 恢复：upload_enabled 变化触发封段并排空
        t.configBody = ["etag": "y", "upload_enabled": true]
        h.client.log(.warn, "more")
        await h.tick(advance: Int64(Limits.configPollIntervalS) * 1000)
        await h.tick(advance: 2000)
        await h.tick(advance: 2000)
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(t.batchRequests.count, 3)
    }

    /// 拉配置在途期间调度器不空转（发版前审查 A2）：发起即记尝试时刻；任何候选已到期时定时器也至少睡 1 s。
    func testConfigInFlightDoesNotSpinScheduler() async throws {
        // 发起即记：configRequest() 构造出请求后，轮询立即不到期
        do {
            let h = Harness()
            await h.settle()
            let (built, due) = await h.work { e -> (Bool, Bool) in
                e.lastConfigFetchMono = nil
                let r = e.configRequest()
                return (r != nil, e.configPollDue(nowMono: e.clock.monoMs()))
            }
            XCTAssertTrue(built)
            XCTAssertFalse(due)
        }
        // 地板（纯函数）
        XCTAssertEqual(RetrieverClient.timerDelayMs(next: 100, now: 5_000), ClientConstants.schedulerMinDelayMs)
        XCTAssertEqual(RetrieverClient.timerDelayMs(next: 5_000, now: 5_000), 1_000)
        XCTAssertEqual(RetrieverClient.timerDelayMs(next: 65_000, now: 5_000), 60_000)

        // 启动时的配置请求挂起（在途）
        let t = FakeTransport()
        t.configHang = true
        let h = Harness(transport: t)
        await waitFor { t.hangingCount == 1 && !h.clock.timerSleepRequests.isEmpty }
        XCTAssertEqual(t.hangingCount, 1)
        XCTAssertEqual(h.clock.timerSleepRequests, [Int64(Limits.configPollIntervalS) * 1000], "在途期间下一次唤醒在 30 min 后，不在过去")
        // 在途超过 30 min（真实里有请求超时，这里人为挂着）：轮询候选落到过去，定时器仍睡满地板
        h.clock.advance(Int64(Limits.configPollIntervalS) * 1000 + 60_000)
        let c = h.client
        await c.onWork { c.tick() }
        await waitFor { h.clock.timerSleepRequests.count >= 2 }
        XCTAssertEqual(h.clock.timerSleepRequests.dropFirst().first, ClientConstants.schedulerMinDelayMs)
        XCTAssertTrue(h.clock.timerSleepRequests.allSatisfy { $0 >= ClientConstants.schedulerMinDelayMs })
        XCTAssertEqual(t.configRequests.count, 1, "在途时不重复拉")
        t.cancelAll()
        await h.settle()
    }

    /// setUser 值变化 → 立即按新身份拉配置；有在途请求时不并发，在途结束后再拉一次；同值不拉（ADR 0019 决定 12）。
    /// 修复前：setUser 不拉配置，启动那次在途请求还会吞掉新请求。
    func testSetUserRefetchesConfigAfterInFlight() async throws {
        let t = FakeTransport()
        t.configHang = true
        let h = Harness(transport: t)
        await waitFor { t.hangingCount == 1 }
        XCTAssertEqual(t.configRequests.count, 1)
        XCTAssertNil(t.configRequests[0].headers["X-Rtv-User"])
        h.client.setUser("U")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(t.configRequests.count, 1, "在途时不并发")
        t.configHang = false
        t.cancelAll()                                   // 放行启动那次
        await h.settle()
        XCTAssertEqual(t.configRequests.count, 2)
        XCTAssertEqual(t.configRequests.last?.headers["X-Rtv-User"], "U")
        h.client.setUser("U")
        await h.settle()
        XCTAssertEqual(t.configRequests.count, 2, "同值不重拉")
        h.client.setUser("V")
        await h.settle()
        XCTAssertEqual(t.configRequests.count, 3, "空段改写 header（不封段）也算身份变化")
        XCTAssertEqual(t.configRequests.last?.headers["X-Rtv-User"], "V")
    }

    /// 配置属于请求时的身份：A 的响应在切到 B 之后才到 → 丢弃（不缓存、不生效）并按 B 重拉；A 的 full_dump 从未作用于 B。
    func testStaleIdentityResponseDiscarded() async throws {
        let t = FakeTransport()
        let h = Harness(transport: t)
        await h.settle()
        h.client.setUser("A")
        await h.settle()
        t.configBody = ["etag": "a", "full_dump": true, "full_dump_ttl_s": 3600]
        t.configHold = true
        h.client.fetchConfig()
        await waitFor { t.heldConfigCount == 1 }
        XCTAssertEqual(t.configRequests.last?.headers["X-Rtv-User"], "A")
        h.client.setUser("B")
        t.configBody = ["etag": "b"]
        t.configHold = false
        t.releaseHeldConfigs()                          // A 的响应（full_dump）此刻才到
        await h.settle()
        let eff = await h.work { $0.effective }
        XCTAssertFalse(eff.fullDumpActive, "A 的覆盖不作用于 B")
        XCTAssertEqual(eff.config.etag, "b", "按 B 重拉的响应生效")
        XCTAssertEqual(t.configRequests.last?.headers["X-Rtv-User"], "B")
        XCTAssertEqual(h.outboxFiles("p2"), [], "full_dump 从未生效（没有 backfill）")
        XCTAssertEqual(h.json("config.json")?["config"].flatMap { ($0 as? [String: Any])?["etag"] as? String }, "b", "旧身份的响应没被缓存")
    }

    /// 身份变化的那一刻缓存按过期处理：上一个用户的放大型覆盖（full_dump、低上传级别）立即回落，不等新配置回来。
    func testSetUserExpiresAmplifyingConfig() async throws {
        let t = FakeTransport()
        t.configBody = ["etag": "fd", "ttl_s": 1800, "full_dump": true, "full_dump_ttl_s": 3600, "upload_level": "debug"]
        let h = Harness(transport: t)
        await h.settle()
        h.client.setUser("A")
        await h.settle()
        let before = await h.work { $0.effective }
        XCTAssertTrue(before.fullDumpActive)
        XCTAssertEqual(h.client.effectiveLevels.upload, .debug)
        t.configHang = true
        h.client.setUser("B")
        let after = await h.work { $0.effective }
        XCTAssertFalse(after.fullDumpActive, "身份一变，放大型字段立即回落")
        XCTAssertEqual(after.uploadLevel, .warn)
        XCTAssertEqual(h.client.effectiveLevels.upload, .warn)
        t.configHang = false
        t.cancelAll()
        await h.settle()
    }

    /// 身份变化只回落放大上传的字段、不动 local_cap（ADR 0019 决定 12）：远程 local_cap_bytes = 宿主默认 × 2、出站箱义务批
    /// 超过宿主默认时，setUser 不驱逐、不记 buffer_overflow；身份过期标志只在内存，config.json 不变。真正的 TTL 过期照旧回落并驱逐（宪法 U-2）。
    /// 修复前：身份过期借道「把拉取时刻往前推一个 TTL」，local_cap 跟着回落，换个用户就删掉还没上传的义务批。
    func testSetUserDoesNotEvictOnCapFallback() async throws {
        let hostCap = Limits.localCapBytesMin
        let t = FakeTransport()
        t.configBody = ["etag": "big", "ttl_s": 1800, "local_cap_bytes": 2 * hostCap, "upload_enabled": false]
        var o = Options()
        o.localCapBytes = hostCap
        let h = Harness(options: o, transport: t)
        await h.settle()
        let eff0 = await h.work { $0.effective }
        XCTAssertEqual(eff0.config.localCapBytes, 2 * hostCap)
        // 不可压缩的 warn 行（义务行，upload_enabled = false 只落盘）：出站箱批总量超过宿主默认
        func boxBytes() -> Int { h.outboxFiles().reduce(0) { $0 + Int(FS.size(h.outbox.appendingPathComponent($1)) ?? 0) } }
        var n = 0
        repeat {
            for _ in 0..<50 {
                var r = [UInt8](repeating: 0, count: 2250)
                arc4random_buf(&r, r.count)
                h.client.log(.warn, Data(r).base64EncodedString())
            }
            n += 50
            await h.settle()
        } while boxBytes() < hostCap + hostCap / 8 && n < 4000
        await h.seal()
        XCTAssertGreaterThan(boxBytes(), hostCap)
        XCTAssertEqual(h.readJSONL("drops.jsonl").count, 0, "远程上限内：义务批全在")
        let before = h.outboxFiles()
        let cfgFile = try Data(contentsOf: h.root.appendingPathComponent("config.json"))
        t.configHang = true                                 // 新身份的配置迟迟不回：缓存停在「身份过期」
        h.client.setUser("b")
        let eff1 = await h.work { $0.effective }
        XCTAssertTrue(eff1.expired, "身份一变按过期处理")
        XCTAssertEqual(eff1.config.localCapBytes, 2 * hostCap, "local_cap 不随身份回落")
        XCTAssertEqual(h.outboxFiles(), before, "没有批被删")
        XCTAssertFalse(h.readJSONL("drops.jsonl").contains { $0["reason"] as? String == "buffer_overflow" })
        XCTAssertEqual(try Data(contentsOf: h.root.appendingPathComponent("config.json")), cfgFile, "身份过期不落盘")
        // 真正的 TTL 过期：local_cap 回落宿主默认，超出的义务批照旧按 buffer_overflow 驱逐
        t.configBody = nil                                  // 此后的拉取 404，缓存不被刷新
        t.configHang = false
        t.cancelAll()
        await h.settle()
        await h.tick(advance: 1800 * 1000)
        let eff2 = await h.work { $0.effective }
        XCTAssertEqual(eff2.config.localCapBytes, hostCap)
        XCTAssertTrue(h.readJSONL("drops.jsonl").contains { $0["reason"] as? String == "buffer_overflow" })
        XCTAssertLessThan(h.outboxFiles().count, before.count)
    }

    /// 不看网络类型（ADR 0009）：backfill 批与其它批走同一套队列 / 退避规则，生成后照常上传。
    func testBackfillUploadsLikeOtherBatches() async throws {
        let t = FakeTransport()
        let h = Harness(key: "", transport: t)
        await h.settle()
        h.client.log(.debug, "history")
        await h.seal()
        t.configBody = ["etag": "fd", "full_dump": true, "full_dump_ttl_s": 3600]
        await h.enableUpload()
        XCTAssertEqual(t.batchRequests.count, 1, "backfill 不等网络，照常上传")
        let env = try XCTUnwrap(decodeEnvelope(try XCTUnwrap(t.batchRequests[0].body)))
        XCTAssertEqual(env["kind"] as? String, "backfill")
        XCTAssertEqual(h.outboxFiles(), [])
    }
}

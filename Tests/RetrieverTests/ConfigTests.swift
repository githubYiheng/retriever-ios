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
        // 缓存到 config.json，重启后按墙钟兜底
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

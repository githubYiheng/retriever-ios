import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 生命周期（方案 §3.9）：进后台封段 + 排空包在 beginBackgroundTask 里；过期回调取消在途请求并 end（「过期必 end」）。
final class LifecycleTests: XCTestCase {
    func cursor(_ h: Harness) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.sessionDir().appendingPathComponent("cursor.json"))) as? [String: Any])
    }

    func waitUntil(_ cond: @escaping () -> Bool) async {
        var n = 0
        while !cond() && n < 500 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            n += 1
        }
    }

    func testBackgroundExpirationCancelsInFlightAndEndsTask() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .hang
        h.client.log(.warn, "w")
        h.client.platformEvent(.didEnterBackground)
        let token = try XCTUnwrap(h.platform.begunTokens.first)
        await waitUntil { h.transport.hangingCount == 1 }
        XCTAssertEqual(h.transport.hangingCount, 1, "排空已在途")
        XCTAssertEqual(h.platform.endedTokens, [])
        // 系统回调过期
        h.platform.expire(token)
        XCTAssertEqual(h.platform.endedTokens, [token], "过期必 end")
        XCTAssertGreaterThanOrEqual(h.transport.cancelCount, 1)
        await h.settle()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.platform.endedTokens, [token], "每个令牌只 end 一次")
        XCTAssertEqual(h.outboxFiles().count, 1, "取消的请求不删批")
        XCTAssertEqual(try cursor(h)["last_state"] as? String, "bg")
        // 上传锁已释放
        let fd = open(h.root.appendingPathComponent("upload.lock").path, O_RDWR)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        close(fd)
        // 回前台：写 last_state，重新排空
        h.transport.defaultReply = .echo
        h.client.platformEvent(.willEnterForeground)
        await h.settle()
        await h.tick(advance: Limits.backoffMaxMs)
        XCTAssertEqual(try cursor(h)["last_state"] as? String, "fg")
        XCTAssertEqual(h.outboxFiles(), [])
    }

    func testBackgroundDrainCompletesThenEndsOnce() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.warn, "w")
        h.client.platformEvent(.didEnterBackground)
        let token = try XCTUnwrap(h.platform.begunTokens.first)
        await waitUntil { h.platform.endedTokens == [token] }
        XCTAssertEqual(h.platform.endedTokens, [token])
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(h.transport.batchRequests.count, 1)
        // 迟到的过期回调不会再 end 一次
        h.platform.expire(token)
        XCTAssertEqual(h.platform.endedTokens, [token])
    }

    func testBackgroundWithoutObligationDoesNotSeal() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.info, "just info")
        h.client.platformEvent(.didEnterBackground)
        await h.settle()
        XCTAssertEqual(h.client.writer.snapshot.segNo, 1)
        XCTAssertEqual(h.transport.batchRequests.count, 0)
    }

    func testBackgroundLastStateMeansCleanExitOnNextLaunch() async throws {
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        a.client.log(.warn, "w")
        a.client.platformEvent(.didEnterBackground)
        await a.settle()
        let aSid = a.client.writer.currentSessionId
        a.client.simulateCrash()
        let b = Harness(root: root, key: "")
        await b.settle()
        let closed = b.readJSONL("sessions.jsonl").first { $0["session_id"] as? String == aSid }
        XCTAssertEqual(closed?["exit"] as? String, "clean_bg")
        // 后台被杀是常态：不合成 unclean_exit
        XCTAssertFalse(b.envelopes().contains { lines(of: $0.1).contains { $0["synthetic"] as? Bool == true } })
    }

    func testBackgroundDrainsSeveralBatchesAcrossSpacing() async throws {
        let h = Harness(key: "")
        await h.settle()
        for i in 0..<3 {
            h.client.log(.warn, "w\(i)")
            await h.seal()
        }
        h.client.log(.warn, "in open segment")
        await h.work { $0.key = "lk_test_demo_abc_12345678" }
        h.client.platformEvent(.didEnterBackground)
        let token = try XCTUnwrap(h.platform.begunTokens.first)
        await waitUntil { h.platform.endedTokens == [token] }
        XCTAssertEqual(h.platform.endedTokens, [token])
        XCTAssertEqual(h.transport.batchRequests.count, 4, "3 个旧批 + 进后台封出的 1 批，间隔 2 s 就地等待")
        XCTAssertEqual(h.outboxFiles(), [])
    }
}

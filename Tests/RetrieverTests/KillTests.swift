import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 真杀进程验收 R-1（方案 §3.11）：子进程写 N 行后 SIGKILL，重启后断言 N 行全部识别、oseq 连续、出站箱正确、
/// sessions.jsonl 有 unclean_fg 且合成 error 已封段。
final class KillTests: XCTestCase {
    static var helperURL: URL {
        // xctest bundle 与可执行 product 在同一个构建目录
        Bundle(for: KillTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("RetrieverKillHelper")
    }

    func runHelper(root: URL, n: Int, torn: Bool) throws -> (seq: Int64, oseq: Int64) {
        let p = Process()
        p.executableURL = KillTests.helperURL
        p.arguments = ["--root", root.path, "--n", String(n)] + (torn ? ["--torn"] : [])
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGKILL)
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let seq = Int64(parts[0].dropFirst(4))!
        let oseq = Int64(parts[1].dropFirst(5))!
        return (seq, oseq)
    }

    /// 读旧会话全部段里的行。
    func allLines(_ sessionDir: URL) -> [[String: Any]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir.path)) ?? []).filter { $0.hasPrefix("seg-") }.sorted()
        var out: [[String: Any]] = []
        for n in names {
            let s = try! String(contentsOf: sessionDir.appendingPathComponent(n), encoding: .utf8)
            for (i, l) in s.split(separator: "\n").enumerated() where i > 0 {
                out.append(try! JSONSerialization.jsonObject(with: Data(l.utf8)) as! [String: Any])
            }
        }
        return out
    }

    func oldSession(_ root: URL, current: String) -> (String, URL) {
        let proc = root.appendingPathComponent("proc-main")
        let sid = try! FileManager.default.contentsOfDirectory(atPath: proc.path).first { $0 != current && $0.count == 36 }!
        return (sid, proc.appendingPathComponent(sid))
    }

    func testKillThenRecover() async throws {
        let root = makeTempDir("rtv-kill")
        let (seq, oseq) = try runHelper(root: root, n: 5000, torn: false)
        XCTAssertEqual(seq, 5000)
        XCTAssertEqual(oseq, 500)

        let h = Harness(root: root, key: "")
        await h.settle()
        let (sid, dir) = oldSession(root, current: h.client.writer.currentSessionId)

        // 全部段已封，无残留 .open
        let segs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("seg-") }
        XCTAssertTrue(segs.allSatisfy { $0.hasSuffix(".sealed") }, "\(segs)")

        // 5000 行全部识别 + 合成 error（seq / oseq 接着编）
        let ls = allLines(dir)
        XCTAssertEqual(ls.count, 5001)
        XCTAssertEqual(ls.map { int($0["seq"]) }, Array(1...5001))
        let oseqs = ls.compactMap { $0["oseq"] as? NSNumber }.map(\.int64Value)
        XCTAssertEqual(oseqs, Array(1...501))
        let synth = ls.last!
        XCTAssertEqual(synth["tag"] as? String, "rtv.unclean_exit")
        XCTAssertEqual(synth["synthetic"] as? Bool, true)
        XCTAssertEqual(synth["level"] as? String, "error")
        XCTAssertEqual(synth["msg"] as? String, "process ended while foregrounded")

        // 会话终态
        let closed = h.readJSONL("sessions.jsonl").filter { $0["session_id"] as? String == sid }
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?["exit"] as? String, "unclean_fg")
        XCTAssertEqual(int(closed.first?["last_seq"]), 5001)
        XCTAssertEqual(int(closed.first?["last_oseq"]), 501)

        // 出站箱：旧会话 primary 批 oseq 区间首尾相接覆盖 1..501，合成 error 在带 ctx 的 p0 批里
        let envs = h.envelopes().filter { $0.1["session_id"] as? String == sid }
        let ranges = envs.map { (int($0.1["oseq_from"]), int($0.1["oseq_to"])) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(ranges.first?.0, 1)
        XCTAssertEqual(ranges.last?.1, 501)
        for i in 1..<max(ranges.count, 1) where ranges.count > 1 { XCTAssertEqual(ranges[i].0, ranges[i - 1].1 + 1) }
        let p0 = try XCTUnwrap(envs.first { e in lines(of: e.1).contains { $0["tag"] as? String == "rtv.unclean_exit" } })
        XCTAssertTrue(p0.0.hasPrefix("p0-"))
        let ctx = lines(of: p0.1).filter { $0["ctx"] as? Bool == true }
        XCTAssertEqual(ctx.count, Limits.ctxLinesDefault)
        XCTAssertTrue((p0.1["closed_sessions"] as? [[String: Any]] ?? []).contains { $0["session_id"] as? String == sid })

        // 服务端校验器逐个通过
        let results = try runValidator(envs.map(\.1))
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }

        // 重启第二次：不再重复合成、不重复写终态
        let h2 = Harness(root: root, key: "")
        await h2.settle()
        XCTAssertEqual(allLines(dir).count, 5001)
        XCTAssertEqual(h2.readJSONL("sessions.jsonl").filter { $0["session_id"] as? String == sid }.count, 1)
        XCTAssertEqual(h2.envelopes().filter { $0.1["session_id"] as? String == sid }.count, envs.count)
    }

    func testTornLastLine() async throws {
        let root = makeTempDir("rtv-torn")
        let (seq, oseq) = try runHelper(root: root, n: 3000, torn: true)
        XCTAssertEqual(seq, 3000)
        XCTAssertEqual(oseq, 300)
        let h = Harness(root: root, key: "")
        await h.settle()
        let (sid, dir) = oldSession(root, current: h.client.writer.currentSessionId)
        let ls = allLines(dir)
        // 残行被截掉：3000 行完整 + 合成 error 的 seq 跳过残行占用的 3001
        XCTAssertEqual(ls.count, 3001)
        XCTAssertEqual(ls.dropLast().map { int($0["seq"]) }, Array(1...3000))
        XCTAssertEqual(int(ls.last?["seq"]), 3002)
        XCTAssertEqual(int(ls.last?["oseq"]), 302)
        // 残行 oseq 301 记 corrupt 墓碑
        let drops = h.readJSONL("drops.jsonl").filter { $0["session_id"] as? String == sid }
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?["reason"] as? String, "corrupt")
        XCTAssertEqual(int(drops.first?["oseq_from"]), 301)
        XCTAssertEqual(int(drops.first?["oseq_to"]), 301)
        // 出站箱覆盖 1..300 与 302（缺口处切批）
        let envs = h.envelopes().filter { $0.1["session_id"] as? String == sid }
        let covered = envs.flatMap { lines(of: $0.1).compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, Array(1...300) + [302])
        let results = try runValidator(envs.map(\.1))
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    /// 同一 root 上另一个还活着的实例（同进程名的扩展误配等）：它的会话目录锁着，恢复流程不动它。
    func testLiveSessionIsNotRecovered() async throws {
        let root = makeTempDir("rtv-live")
        let a = Harness(root: root, key: "")
        await a.settle()
        a.client.log(.warn, "a alive")
        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertNotNil(a.client.debugOpenSegmentPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.client.debugOpenSegmentPath!), "a 的 .open 段没被封")
        XCTAssertEqual(b.readJSONL("sessions.jsonl").count, 0)
        a.client.log(.warn, "a still writes")
        XCTAssertEqual(a.client.debugCounters.oseq, 2)
        // a 死后，下一次启动才恢复它（b 仍活着，不动）
        let aSid = a.client.writer.currentSessionId
        a.client.simulateCrash()
        let c = Harness(root: root, key: "")
        await c.settle()
        let closed = c.readJSONL("sessions.jsonl")
        XCTAssertEqual(closed.map { $0["session_id"] as? String }, [aSid])
        XCTAssertEqual(closed.first?["exit"] as? String, "unclean_fg")
        XCTAssertEqual(int(closed.first?["last_oseq"]), 3, "2 行 warn + 合成 error")
    }
}

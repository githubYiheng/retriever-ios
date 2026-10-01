import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// configure 之前 / 收编中途真杀进程（ADR 0023；简报 §11 D / E），沿用 RetrieverKillHelper。
final class PreconfigureKillTests: XCTestCase {
    /// 跑 helper（共享入口、root 注入），等它被 SIGKILL。
    func run(_ root: URL, _ extra: [String], n: Int) throws {
        let p = Process()
        p.executableURL = KillTests.helperURL
        p.arguments = ["--root", root.path, "--n", String(n)] + extra
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationReason, .uncaughtSignal, text)
        XCTAssertEqual(p.terminationStatus, SIGKILL)
        XCTAssertTrue(text.contains("lines=\(n)"))
    }

    func runOutput(_ root: URL, _ extra: [String], n: Int) throws -> String {
        let p = Process()
        p.executableURL = KillTests.helperURL
        p.arguments = ["--root", root.path, "--n", String(n)] + extra
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationReason, .uncaughtSignal, text)
        XCTAssertEqual(p.terminationStatus, SIGKILL)
        return text
    }

    /// helper 写的行：i % 50 == 0 → error，% 10 → warn，偶数 → info，奇数 → debug。
    func expected(n: Int, upload: LogLevel) -> (all: Int, oblig: Int) {
        var ob = 0
        for i in 1...n {
            let l: LogLevel = i % 50 == 0 ? .error : (i % 10 == 0 ? .warn : (i % 2 == 0 ? .info : .debug))
            if l >= upload { ob += 1 }
        }
        return (n, ob)
    }

    func kinds(_ root: URL, _ current: String) -> [(String, [[String: Any]])] {
        let proc = root.appendingPathComponent("proc-main")
        return FS.list(proc).filter { IDs.isUuid($0) && $0 != current }.map { ($0, segmentLines(proc.appendingPathComponent($0))) }
    }

    /// D：configure 之前进程被杀 → 下次启动收编为独立会话：行数相等、按当时（收编实例的）级别判定、无 rtv.unclean_exit、用户边界正确。
    func testD_KilledBeforeConfigureAdoptedAsOwnSession() async throws {
        let root = makeTempDir("rtv-prekill")
        let n = 400
        try run(root, ["--preconfigure", "--user", "u-kill"], n: n)
        let pre = FS.list(root.appendingPathComponent("pre"))
        XCTAssertEqual(pre.count, 1, "pre 文件成了孤儿")
        XCTAssertFalse(FS.exists(root.appendingPathComponent("install.json")), "configure 之前什么都没建")

        var o = Options()
        o.uploadLevel = .info
        let h = Harness(root: root, key: "", options: o)
        await h.settle()
        XCTAssertEqual(FS.list(root.appendingPathComponent("pre")), [], "收编提交：pre 文件删除")
        let olds = kinds(root, h.client.writer.currentSessionId)
        XCTAssertEqual(olds.count, 1, "独立会话")
        let (sid, ls) = olds[0]
        let (all, ob) = expected(n: n, upload: .info)
        XCTAssertEqual(ls.count, all, "行数相等")
        XCTAssertEqual(ls.map { int($0["seq"]) }, (1...Int64(all)).map { $0 })
        XCTAssertEqual(ls.compactMap { ($0["oseq"] as? NSNumber)?.int64Value }, (1...Int64(ob)).map { $0 }, "按收编时的 INFO 判定")
        XCTAssertFalse(ls.contains { $0["tag"] as? String == "rtv.unclean_exit" }, "没有前后台记录：不合成崩溃行")
        let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("proc-main/\(sid)/meta.json"))) as? [String: Any])
        XCTAssertNil(meta["pre"])
        XCTAssertEqual(meta["process"] as? String, "main")
        XCTAssertGreaterThan(int(meta["session_no"]), int(h.client.engine.current!.meta.sessionNo) - 1, "session_no 收编时才分配")
        let closed = try XCTUnwrap(h.readJSONL("sessions.jsonl").first { $0["session_id"] as? String == sid })
        XCTAssertEqual(closed["exit"] as? String, "unknown")
        XCTAssertEqual(int(closed["last_oseq"]), Int64(ob))
        // 物化：义务行全部进批、首尾相接；用户边界（第 200 行之前 setUser）
        let envs = h.envelopes().map(\.1).filter { $0["session_id"] as? String == sid }
        let covered = envs.flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, (1...Int64(ob)).map { $0 })
        XCTAssertEqual(Set(envs.map { ($0["user_id"] as? String) ?? "nil" }), ["nil", "u-kill"])
        let results = try runValidator(envs)
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }

    /// E：收编中途被杀（meta.pre 已写未写行 / 写了一部分 / 全写完未 unlink）→ 重启后从 pre 文件重做：不重不丢；
    /// 被杀之前没有任何批进出站箱。
    func testE_KilledMidAdoptionRedoneWithoutDupOrLoss() async throws {
        // adopt_after_commit：unlink（提交点）之后、清 meta.pre 之前被杀 —— 所指文件已不在 = 已提交，按普通会话恢复、不重做
        for point in ["adopt_begin", "adopt_mid", "adopt_before_commit", "adopt_after_commit"] {
            let committed = point == "adopt_after_commit"
            let root = makeTempDir("rtv-adoptkill")
            let n = 300
            try run(root, ["--adopt-crash", point], n: n)
            XCTAssertEqual(FS.list(root.appendingPathComponent("outbox")).filter { $0.hasSuffix(".gz") }, [], "\(point)：恢复之前无批次进出站箱")
            XCTAssertEqual(FS.list(root.appendingPathComponent("pre")).count, committed ? 0 : 1, "\(point)：pre 文件提交前始终在")
            let proc = root.appendingPathComponent("proc-main")
            let killed = try XCTUnwrap(FS.list(proc).first(where: IDs.isUuid))
            let meta0 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: proc.appendingPathComponent("\(killed)/meta.json"))) as? [String: Any])
            XCTAssertNotNil(meta0["pre"], "\(point)：meta.pre 指着 pre 文件")

            let h = Harness(root: root, key: "")
            await h.settle()
            XCTAssertEqual(FS.list(root.appendingPathComponent("pre")), [], point)
            let ls = segmentLines(proc.appendingPathComponent(killed))
            let host = ls.filter { $0["tag"] as? String == "kill" }
            XCTAssertEqual(host.count, n, "\(point)：不丢")
            XCTAssertEqual(Set(host.compactMap { $0["msg"] as? String }).count, n, "\(point)：不重")
            XCTAssertEqual(ls.map { int($0["seq"]) }, (1...Int64(ls.count)).map { $0 }, "\(point)：重做 = 从 seq 1 重新编号")
            let (_, ob) = expected(n: n, upload: .warn)
            // 重做保留前后台记录：被杀时在前台（helper 的平台恒为前台）且未收尾 → 有且只有一条 rtv.unclean_exit，排在重做出的行之后
            let synth = ls.filter { $0["tag"] as? String == "rtv.unclean_exit" }
            XCTAssertEqual(synth.count, 1, "\(point)：有且只有一条 rtv.unclean_exit")
            XCTAssertEqual(ls.last?["tag"] as? String, "rtv.unclean_exit", point)
            XCTAssertEqual(ls.compactMap { ($0["oseq"] as? NSNumber)?.int64Value }, (1...Int64(ob + 1)).map { $0 }, "\(point)：oseq 连续")
            let closed = try XCTUnwrap(h.readJSONL("sessions.jsonl").first { $0["session_id"] as? String == killed })
            XCTAssertEqual(closed["exit"] as? String, "unclean_fg", point)
            let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: proc.appendingPathComponent("\(killed)/meta.json"))) as? [String: Any])
            if !committed { XCTAssertNil(meta["pre"], "\(point)：重做提交后清掉 meta.pre") }
            XCTAssertEqual(meta["session_id"] as? String, killed, "\(point)：收编进同一个会话")
            let envs = h.envelopes().map(\.1).filter { $0["session_id"] as? String == killed }
            let covered = envs.flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
            XCTAssertEqual(covered, (1...Int64(ob + 1)).map { $0 }, "\(point)：物化不重不丢")
            XCTAssertEqual(FS.list(proc).filter(IDs.isUuid).count, 2, "\(point)：没有另建孤儿会话")
        }
    }

    /// 收编期间宿主还在写（r = 1 行进 pre 文件）时被杀：重做后 configure 之前的行与收编期间的行都在、各一次，排在一起按序；
    /// 前台崩溃照常合成 rtv.unclean_exit。
    func testE_KilledWhileHostWritesDuringAdoption() async throws {
        let root = makeTempDir("rtv-holdwrite")
        let n = 120
        let m = 40
        let text = try runOutput(root, ["--adopt-hold-write", String(m)], n: n)
        XCTAssertTrue(text.contains("post=\(m)"), text)
        let h = Harness(root: root, key: "")
        await h.settle()
        XCTAssertEqual(FS.list(root.appendingPathComponent("pre")), [])
        let proc = root.appendingPathComponent("proc-main")
        let killed = try XCTUnwrap(FS.list(proc).filter(IDs.isUuid).first { $0 != h.client.writer.currentSessionId })
        let ls = segmentLines(proc.appendingPathComponent(killed))
        let msgs = ls.filter { $0["tag"] as? String == "kill" }.compactMap { $0["msg"] as? String }
        XCTAssertEqual(msgs, (1...n).map { "pre \($0)" } + (1...m).map { "post \($0)" }, "不重不丢、按写入顺序")
        XCTAssertEqual(ls.filter { $0["tag"] as? String == "rtv.unclean_exit" }.count, 1)
        let oseqs = ls.compactMap { ($0["oseq"] as? NSNumber)?.int64Value }
        XCTAssertEqual(oseqs, (1...Int64(oseqs.count)).map { $0 }, "oseq 连续")
    }
}

import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 启动恢复里的待报状态（ADR 0019 决定 1 / 13）：终态只为有义务行的会话写；零行的会话目录直接删；段读不出的会话留到下次重试。
final class RecoveryTests: XCTestCase {
    func bgPlatform() -> FakePlatform {
        let p = FakePlatform()
        p.foreground = false
        return p
    }

    func sessionDirs(_ root: URL) -> [String] {
        FS.list(root.appendingPathComponent("proc-main")).filter(IDs.isUuid).sorted()
    }

    /// 真实的后台会话 S1（warn 已上传确认，恢复时无批可物化，终态只能等载体批）+ 25 个空后台会话：
    /// 空会话不写终态、目录直接删，载体批带上 S1 的终态（修复前：26 条终态里最旧的 S1 被挤掉并从文件删除）。
    func testRealTerminalSurvivesEmptySessions() async throws {
        let root = makeTempDir()
        let clock = FakeClock()
        let a = Harness(root: root, clock: clock, platform: bgPlatform())
        await a.settle()
        a.client.log(.warn, "real")
        await a.sealAndDrain()
        XCTAssertEqual(a.outboxFiles(), [])
        let s1 = a.client.writer.currentSessionId
        a.client.simulateCrash()
        for _ in 0..<25 {
            clock.advance(1000)
            let e = Harness(root: root, key: "", clock: clock, platform: bgPlatform())
            await e.settle()
            e.client.simulateCrash()
        }
        clock.advance(1000)
        let h = Harness(root: root, key: "", clock: clock, platform: bgPlatform())
        await h.settle()
        let closed = h.readJSONL("sessions.jsonl")
        XCTAssertEqual(closed.map { $0["session_id"] as? String }, [s1])
        XCTAssertFalse(closed.contains { int($0["last_oseq"]) == 0 }, "没有义务行的会话不写终态")
        XCTAssertEqual(sessionDirs(root), [s1, h.client.writer.currentSessionId].sorted(), "空会话目录都删了")
        h.client.log(.warn, "carrier")
        await h.seal()
        let env = try XCTUnwrap(h.envelopes().first { $0.1["session_id"] as? String == h.client.writer.currentSessionId }?.1)
        XCTAssertEqual((env["closed_sessions"] as? [[String: Any]])?.map { $0["session_id"] as? String }, [s1])
        XCTAssertEqual((env["closed_sessions"] as? [[String: Any]])?.first?["exit"] as? String, "clean_bg")
    }

    /// 零行的会话（段里只有 header）恢复时目录直接删、不写终态；0.1.x 留下的已收尾空会话目录同样清掉（不再滞留到 7 天年龄驱逐）。
    func testZeroLineSessionDirRemovedOnRecovery() async throws {
        let root = makeTempDir()
        let a = Harness(root: root, key: "", platform: bgPlatform())
        await a.settle()
        let aDir = a.sessionDir()
        a.client.simulateCrash()
        // 0.1.x 形态：已收尾（closed_ms）、只有 header 的段、meta 无 install_id
        let legacySid = IDs.newV4()
        let legacy = root.appendingPathComponent("proc-main").appendingPathComponent(legacySid)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let dev = Device(os: "macos", osVersion: "26.0", model: "Mac-test", appVersion: "1.2.3", build: "45", locale: "zh_CN", sdk: "retriever-ios/0.1.4")
        try Data(SessionMeta(sessionId: legacySid, sessionNo: 1, startedMs: 1, device: dev, process: "main").encode())
            .write(to: legacy.appendingPathComponent("meta.json"))
        try Data(Cursor(lastState: "bg", lastStateMs: 1, closedMs: 2).encode()).write(to: legacy.appendingPathComponent("cursor.json"))
        try Data(SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode()).write(to: legacy.appendingPathComponent("seg-000001.sealed"))

        let b = Harness(root: root, key: "", platform: bgPlatform())
        await b.settle()
        XCTAssertFalse(FS.exists(aDir))
        XCTAssertFalse(FS.exists(legacy))
        XCTAssertEqual(sessionDirs(root), [b.client.writer.currentSessionId])
        XCTAssertEqual(b.readJSONL("sessions.jsonl").count, 0)
        XCTAssertEqual(b.outboxFiles(), [])
    }

    /// 恢复时墓碑没写成（drops.jsonl 追加失败：磁盘满等）：不打「已收尾」、不物化（游标不越过缺口），下次启动重试并补写墓碑；
    /// 终态与合成行都不重复（修复前：墓碑写失败照样打 closed_ms、游标越过缺口，缺口从此无人解释）。
    func testDropsAppendFailureRetriesNextLaunch() async throws {
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        for i in 1...3 { a.client.log(.warn, "w\(i)") }
        let sid = a.client.writer.currentSessionId
        let seg = URL(fileURLWithPath: try XCTUnwrap(a.client.debugOpenSegmentPath))
        a.client.simulateCrash()
        // 撕裂的第 4 行（oseq 4）：恢复时记 corrupt 墓碑
        XCTAssertTrue(FS.append(seg, Array("{\"seq\":4,\"oseq\":4,\"ts\":1,\"level\":\"warn\",\"msg\":\"to".utf8)))
        // drops.jsonl 是个目录：追加必然失败
        let drops = root.appendingPathComponent("drops.jsonl")
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: false)

        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertNil(b.json("proc-main/\(sid)/cursor.json")?["closed_ms"], "墓碑没写成：不打收尾标记")
        XCTAssertTrue(b.readJSONL("sessions.jsonl").contains { $0["session_id"] as? String == sid }, "终态照写")
        XCTAssertFalse(b.envelopes().contains { $0.1["session_id"] as? String == sid }, "游标不越过缺口：本次不物化")
        b.client.simulateCrash()

        try FileManager.default.removeItem(at: drops)
        let c = Harness(root: root, key: "")
        await c.settle()
        let d = c.readJSONL("drops.jsonl").filter { $0["session_id"] as? String == sid }
        XCTAssertEqual(d.count, 1, "重试补写墓碑")
        XCTAssertEqual(d.first?["reason"] as? String, "corrupt")
        XCTAssertEqual(int(d.first?["oseq_from"]), 4)
        XCTAssertEqual(int(d.first?["oseq_to"]), 4)
        XCTAssertNotNil(c.json("proc-main/\(sid)/cursor.json")?["closed_ms"])
        XCTAssertEqual(c.readJSONL("sessions.jsonl").filter { $0["session_id"] as? String == sid }.count, 1, "终态不重复")
        let covered = c.envelopes().filter { $0.1["session_id"] as? String == sid }
            .flatMap { lines(of: $0.1).compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, [1, 2, 3, 5], "3 行 warn + 合成 error（不重复合成）")
    }

    /// 恢复时段文件读不出（ADR 0019 决定 13）：不推进 cursor、不删目录、不写终态、不合成行，整个会话留到下次启动；
    /// 可读后照常恢复（修复前：跳过读不出的段，合成行写进同名新段把它覆盖，义务行无墓碑消失）。
    func testUnreadableSegmentKeepsSessionForRetry() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        for i in 1...3 { a.client.log(.warn, "w\(i)") }
        let aSid = a.client.writer.currentSessionId
        let dir = a.sessionDir()
        let seg = dir.appendingPathComponent("seg-000001.open")
        a.client.simulateCrash()
        XCTAssertEqual(chmod(seg.path, 0), 0)
        defer { chmod(seg.path, 0o600) }

        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertTrue(FS.exists(seg), "段原样留着")
        XCTAssertNil(b.json("proc-main/\(aSid)/cursor.json")?["closed_ms"], "没有收尾")
        XCTAssertFalse(b.readJSONL("sessions.jsonl").contains { $0["session_id"] as? String == aSid }, "不写终态")
        XCTAssertFalse(b.envelopes().contains { $0.1["session_id"] as? String == aSid })
        b.client.simulateCrash()

        XCTAssertEqual(chmod(seg.path, 0o600), 0)
        let c = Harness(root: root, key: "")
        await c.settle()
        let closed = try XCTUnwrap(c.readJSONL("sessions.jsonl").first { $0["session_id"] as? String == aSid })
        XCTAssertEqual(closed["exit"] as? String, "unclean_fg")
        XCTAssertEqual(int(closed["last_oseq"]), 4, "3 行 warn + 合成 error")
        let covered = c.envelopes().filter { $0.1["session_id"] as? String == aSid }
            .flatMap { lines(of: $0.1).compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, [1, 2, 3, 4])
    }
}

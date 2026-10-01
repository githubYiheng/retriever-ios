import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 与 Android 0.3.0 盲审对齐的 6 项（`docs/audit/2026-10-01-host-misuse/blind-review-android-0.3.0.md` 末尾「与 iOS 不一致的地方」）。
final class AndroidParityTests: XCTestCase {
    let dev = Device(os: "macos", osVersion: "26.0", model: "Mac-test", appVersion: "1.2.3", build: "45", locale: "zh_CN", sdk: "s")

    func dir(_ sh: SharedHarness) -> URL {
        sh.client.root.appendingPathComponent("proc-main/\(sh.client.writer.currentSessionId)")
    }

    // MARK: 1. 从不 configure 的宿主：旧 pre 文件有界

    func testStalePreFilesBoundedBeforeCreatingOwn() async throws {
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.preDir, withIntermediateDirectories: true)
        var names: [String] = []
        for i in 0..<10 {                                           // 10 个、每个 100 KB：个数超 8
            let n = PreName.make()
            let url = sh.preDir.appendingPathComponent(n)
            try Data(repeating: 0x41, count: 100_000).write(to: url)
            FS.touch(url, wallMs: 1_000_000 + Int64(i) * 1000)        // i 越小越旧
            names.append(n)
        }
        let live = sh.preDir.appendingPathComponent(PreName.make())
        try Data(repeating: 0x42, count: 10).write(to: live)
        FS.touch(live, wallMs: 1)                                   // 最旧，但有活持有者
        let fd = open(live.path, O_RDONLY)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }
        sh.shared.log(.info, "first")
        let left = Set(sh.preFiles())
        XCTAssertFalse(left.contains(names[0]))
        XCTAssertFalse(left.contains(names[1]), "从最旧的删起")
        XCTAssertTrue(Set(names[2...]).isSubset(of: left), "删到 8 个为止")
        XCTAssertTrue(left.contains(live.lastPathComponent), "别的活进程的不碰")
        XCTAssertEqual(left.count, 8 + 1 + 1, "8 个旧的 + 活进程的 + 本进程新建的")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 0, "不计数")

        // 总量超 4 MB：3 × 1.5 MB → 删最旧的一个
        let sh2 = SharedHarness()
        try FileManager.default.createDirectory(at: sh2.preDir, withIntermediateDirectories: true)
        var big: [String] = []
        for i in 0..<3 {
            let n = PreName.make()
            try Data(repeating: 0x41, count: 1_500_000).write(to: sh2.preDir.appendingPathComponent(n))
            FS.touch(sh2.preDir.appendingPathComponent(n), wallMs: 1_000_000 + Int64(i) * 1000)
            big.append(n)
        }
        sh2.shared.log(.info, "x")
        XCTAssertEqual(Set(sh2.preFiles()).intersection(big), Set(big[1...]))
    }

    // MARK: 2. 收编中途 root 消失：从头重放进新会话，不计数、不丢

    func testRootVanishesMidAdoptionReplaysIntoNewSession() async throws {
        let sh = SharedHarness()
        for i in 0..<6 { sh.shared.log(.warn, "p\(i)") }
        let root = sh.defaultRoot
        let fired = Box<Bool>()
        RetrieverTestHooks.setAdoptionHook { p in
            if p == "adopt_mid" && fired.value == nil {
                fired.set(true)
                try? FileManager.default.removeItem(at: root)        // 收编写了一半时删 root
            }
        }
        defer { RetrieverTestHooks.setAdoptionHook(nil) }
        sh.configure(key: "")
        await sh.settle()
        await sh.client.tickNow()
        XCTAssertEqual(fired.value, true)
        XCTAssertFalse(sh.client.writer.isAdopting, "重放后已提交")
        let ls = segmentLines(dir(sh))
        XCTAssertEqual(ls.filter { $0["synthetic"] as? Bool != true }.compactMap { $0["msg"] as? String },
                       (0..<6).map { "p\($0)" }, "全部 pre 行恰好一次出现在新会话")
        XCTAssertTrue(ls.contains { $0["tag"] as? String == "rtv.root_vanished" })
        XCTAssertFalse(ls.contains { $0["tag"] as? String == "rtv.pre_init_dropped" })
        XCTAssertEqual(sh.shared.droppedCountForTesting, 0, "计数为 0")
    }

    // MARK: 3. 孤儿拿到锁之后确认它还在

    func testLockedButUnlinkedPreFileIsDetected() throws {
        let d = makeTempDir("rtv-unlinked")
        let url = d.appendingPathComponent(PreName.make())
        try Data("{\"pre\":1}\n".utf8).write(to: url)
        let r = try XCTUnwrap(PreReader(url: url))
        XCTAssertFalse(r.isUnlinked)
        unlink(url.path)                                             // 别的进程收编完删掉了
        XCTAssertEqual(flock(r.descriptor, LOCK_EX | LOCK_NB), 0, "锁照样拿得到（锁的是已删的 inode）")
        XCTAssertTrue(r.isUnlinked, "拿到锁后 fstat 看 st_nlink == 0 → 放弃")
    }

    // MARK: 4. configure 之前的用户切换记录写失败 → 标满

    func testUserRecordWriteFailureMarksPreFileFull() async throws {
        let sh = SharedHarness()
        sh.shared.log(.warn, "a")
        Faults.failPreAppends(under: sh.preDir)
        sh.shared.setUser("u")
        Faults.clearPreAppendFaults(under: sh.preDir)
        sh.shared.log(.warn, "b")                                    // 不能挂到 nil 用户名下：计数
        XCTAssertEqual(sh.shared.droppedCountForTesting, 1)
        sh.configure(key: "")
        await sh.settle()
        let ls = segmentLines(dir(sh))
        XCTAssertEqual(ls.filter { $0["synthetic"] as? Bool != true }.compactMap { $0["msg"] as? String }, ["a"])
        XCTAssertEqual(int((ls.first { $0["tag"] as? String == "rtv.pre_init_dropped" }?["attrs"] as? [String: Any])?["count"]), 1)
        XCTAssertEqual(sh.client.writer.currentUser, "u", "最终用户对齐")
    }

    // MARK: 5. 收编时每条记录取当前的 redact 钩子

    func testRedactSwappedMidAdoptionAppliesImmediately() async throws {
        let sh = SharedHarness()
        for i in 0..<4 { sh.shared.log(.warn, "p\(i)") }
        let shared = sh.shared
        let fired = Box<Bool>()
        RetrieverTestHooks.setAdoptionHook { p in
            if p == "adopt_mid" && fired.value == nil {
                fired.set(true)
                var o = Options()
                o.redact = { l in var x = l; x.msg = "B:" + x.msg; return x }
                shared.configure(key: "", baseURL: SharedHarness.url, options: o)
            }
        }
        defer { RetrieverTestHooks.setAdoptionHook(nil) }
        sh.configure(key: "") { $0.redact = { l in var x = l; x.msg = "A:" + x.msg; return x } }
        await sh.settle()
        let msgs = segmentLines(dir(sh)).filter { $0["synthetic"] as? Bool != true }.compactMap { $0["msg"] as? String }
        XCTAssertEqual(msgs, ["A:p0", "B:p1", "B:p2", "B:p3"])
    }

    // MARK: 6. 收编未提交时 startup 照常（当前会话靠闸门保护）

    func testUncommittedAdoptionDoesNotBlockStartup() async throws {
        let sh = SharedHarness()
        // 死掉的旧会话：已封段里有未物化的义务行
        let oldSid = IDs.newV4()
        let od = sh.defaultRoot.appendingPathComponent("proc-main/\(oldSid)")
        try FileManager.default.createDirectory(at: od, withIntermediateDirectories: true)
        try Data(SessionMeta(sessionId: oldSid, sessionNo: 1, startedMs: 1, device: dev, process: "main", installId: nil).encode())
            .write(to: od.appendingPathComponent("meta.json"))
        try Data(Cursor(extractedThroughOseq: 0, ctxThroughSeq: 0, lastState: "bg", lastStateMs: 1).encode())
            .write(to: od.appendingPathComponent("cursor.json"))
        try Data((String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode(), as: UTF8.self)
                  + "{\"seq\":1,\"oseq\":1,\"ts\":1,\"level\":\"warn\",\"msg\":\"old\"}\n").utf8)
            .write(to: od.appendingPathComponent("seg-000001.sealed"))
        for i in 0..<5 { sh.shared.log(.warn, "p\(i)") }
        sh.shared.log(.fatal, "pf")                                  // 收编中换段：有封段任务，提交前不得物化
        Faults.failPreCommits(under: sh.preDir)
        defer { Faults.clearPreCommitFaults(under: sh.preDir) }
        sh.configure()
        await sh.settle()
        await sh.client.tickNow()
        let c = sh.client
        XCTAssertTrue(c.writer.isAdopting, "提交被注入持续失败")
        let sent = sh.transport.batchRequests.compactMap { decodeEnvelope($0.body ?? Data()) }
        XCTAssertTrue(sent.contains { $0["session_id"] as? String == oldSid }, "旧会话照常恢复并上传")
        XCTAssertFalse(sent.contains { $0["session_id"] as? String == c.writer.currentSessionId }, "当前会话零上传")
        XCTAssertFalse(sh.envelopes().contains { $0["session_id"] as? String == c.writer.currentSessionId }, "当前会话零物化")
        XCTAssertGreaterThan(sh.transport.configRequests.count, 0, "照常拉配置")
        c.log(.warn, "during")                                       // 收编中：进 pre 文件
        // 失败解除：收编提交、行数相等，之后才封段物化
        Faults.clearPreCommitFaults(under: sh.preDir)
        await c.tickNow()
        await c.tickNow()
        XCTAssertFalse(c.writer.isAdopting)
        let msgs = segmentLines(dir(sh)).filter { $0["synthetic"] as? Bool != true }.compactMap { $0["msg"] as? String }
        XCTAssertEqual(msgs, (0..<5).map { "p\($0)" } + ["pf", "during"])
        sh.clock.advance(Limits.minRequestSpacingMs)                // 相邻请求间隔（旧会话的批刚发过）
        await c.tickNow()
        let mine = sh.transport.batchRequests.compactMap { decodeEnvelope($0.body ?? Data()) }
            .filter { $0["session_id"] as? String == c.writer.currentSessionId }
        XCTAssertTrue(mine.flatMap { lines(of: $0) }.contains { $0["msg"] as? String == "pf" }, "提交后 fatal 段物化上传")
    }
}

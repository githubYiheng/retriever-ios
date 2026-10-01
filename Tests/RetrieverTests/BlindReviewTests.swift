import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 0.3.0 盲审（`docs/audit/2026-10-01-host-misuse/blind-review-ios-0.3.0.md`）的复现实验与修复裁决 1–12。
final class BlindReviewTests: XCTestCase {
    let dev = Device(os: "macos", osVersion: "26.0", model: "Mac-test", appVersion: "1.2.3", build: "45", locale: "zh_CN", sdk: "s")

    /// 一个死掉的旧会话：已封段里有未物化的义务行（游标 0）。
    func oldSession(_ root: URL, lines: [String], ageDays: Int64 = 0, clock: FakeClock) throws -> String {
        let sid = IDs.newV4()
        let dir = root.appendingPathComponent("proc-main/\(sid)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(SessionMeta(sessionId: sid, sessionNo: 1, startedMs: 1, device: dev, process: "main", installId: nil).encode())
            .write(to: dir.appendingPathComponent("meta.json"))
        try Data(Cursor(extractedThroughOseq: 0, ctxThroughSeq: 0, lastState: "bg", lastStateMs: 1).encode())
            .write(to: dir.appendingPathComponent("cursor.json"))
        var seg = String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode(), as: UTF8.self)
        for (i, m) in lines.enumerated() { seg += "{\"seq\":\(i + 1),\"oseq\":\(i + 1),\"ts\":\(i + 1),\"level\":\"warn\",\"msg\":\"\(m)\"}\n" }
        let url = dir.appendingPathComponent("seg-000001.sealed")
        try Data(seg.utf8).write(to: url)
        if ageDays > 0 { FS.touch(url, wallMs: clock.wallMs() - ageDays * 86_400_000) }
        return sid
    }

    func covered(_ sh: SharedHarness, _ sid: String) -> [String] {
        sh.envelopes().filter { $0["session_id"] as? String == sid }
            .flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { $0["msg"] as? String } }
    }

    // MARK: 🔴1 恢复旧会话之前不驱逐（E6 / E7）

    func testE6_LowDiskPreconfigureFatalDoesNotEvictOldSessionSilently() async throws {
        let sh = SharedHarness()
        sh.platform.available = 0                                   // 低磁盘：软上限 ≈ 0
        let sid = try oldSession(sh.defaultRoot, lines: ["o1", "o2"], clock: sh.clock)
        sh.shared.log(.fatal, "pre fatal")                          // 收编中换段
        sh.configure(key: "")
        await sh.settle()
        let drops = (try? String(contentsOf: sh.defaultRoot.appendingPathComponent("drops.jsonl"), encoding: .utf8)) ?? ""
        let got = covered(sh, sid)
        XCTAssertTrue(got == ["o1", "o2"] || drops.contains(sid), "旧段的义务行进了批（或有墓碑）：\(got) / \(drops)")
        XCTAssertEqual(got, ["o1", "o2"])
    }

    func testE7_StaleOldSegmentRecoveredBeforeAgeEviction() async throws {
        let sh = SharedHarness()
        let sid = try oldSession(sh.defaultRoot, lines: ["old"], ageDays: 8, clock: sh.clock)
        sh.shared.log(.warn, "a")
        sh.shared.setUser("u")
        sh.shared.log(.warn, "b")
        sh.configure(key: "")
        await sh.settle()
        XCTAssertEqual(covered(sh, sid), ["old"], "8 天前的旧段先恢复物化、再按年龄删")
        XCTAssertFalse(FS.exists(sh.defaultRoot.appendingPathComponent("proc-main/\(sid)/seg-000001.sealed")))
    }

    /// 收编未提交期间的上限变化 / tick 也不驱逐（evictIfNeeded 总闸门）。
    func testEvictionGatedUntilRecoveryDone() async throws {
        let h = Harness(key: "")
        await h.settle()
        let gated = await h.work { e -> Bool in
            e.evictionAllowed = false
            e.effective.config.localCapBytes = 0
            e.evictIfNeeded()
            return e.evictionAllowed
        }
        XCTAssertFalse(gated)
        h.client.log(.warn, "x")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().count, 1, "闸门关着：上限 0 也不驱逐")
    }

    // MARK: 🔴2 1 MB 只管 configure 之前的行（E1）

    func testE1_PostConfigureLinesDuringAdoptionNotCappedByFullPreFile() async throws {
        let sh = SharedHarness()
        while sh.shared.droppedCountForTesting == 0 { sh.shared.log(.info, String(repeating: "x", count: 4000)) }
        let dropped = sh.shared.droppedCountForTesting
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        RetrieverTestHooks.setAdoptionHook { p in
            if p == "adopt_begin" {
                entered.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
        }
        defer { RetrieverTestHooks.setAdoptionHook(nil) }
        sh.configure(key: "") { $0.uploadLevel = .info }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for i in 0..<20 { sh.shared.log(.error, "post \(i)") }       // configure 之后、收编跑完之前
        XCTAssertEqual(sh.shared.droppedCountForTesting, dropped, "r = 1 的行不受 1 MB 限制：不计数")
        gate.signal()
        await sh.settle()
        let dir = sh.client.root.appendingPathComponent("proc-main/\(sh.client.writer.currentSessionId)")
        let post = segmentLines(dir).filter { ($0["msg"] as? String)?.hasPrefix("post ") == true }
        XCTAssertEqual(post.count, 20, "20 条全部落盘并进会话")
        XCTAssertTrue(post.allSatisfy { $0["oseq"] != nil })
    }

    // MARK: 🔴3 临时 writer 写失败不提交

    func testTempWriterFailureDoesNotCommit() async throws {
        let root = makeTempDir("rtv-tmpfail")
        let preDir = root.appendingPathComponent("pre")
        try FileManager.default.createDirectory(at: preDir, withIntermediateDirectories: true)
        let pre = preDir.appendingPathComponent(PreName.make())
        var bytes = PreFile.header(startedMs: 100, process: "main", device: dev)
        for i in 0..<3 { bytes += PreFile.r0 + LineEncoder.encode(LogLine(ts: 100 + Int64(i), level: .warn, msg: "orphan \(i)")).body }
        try Data(bytes).write(to: pre)
        let size = try XCTUnwrap(FS.size(pre))
        Faults.failSegmentOpens(under: root)
        defer { Faults.clearSegmentFaults(under: root) }
        // 第 1 次启动：孤儿收编写失败 → 不提交（pre 文件原样，会话只剩 meta，meta.pre 指着它）
        let a = Harness(root: root, key: "")
        await a.settle()
        XCTAssertEqual(FS.size(pre), size)
        let proc = root.appendingPathComponent("proc-main")
        let orphanSid = try XCTUnwrap(FS.list(proc).filter(IDs.isUuid).first { sid in
            (try? SessionMeta.decode([UInt8](Data(contentsOf: proc.appendingPathComponent("\(sid)/meta.json")))))??.pre == pre.lastPathComponent
        })
        XCTAssertEqual(FS.list(proc.appendingPathComponent(orphanSid)).filter { Segments.parseName($0) != nil }, [])
        a.client.simulateCrash()
        // 第 2 次启动：重做也写失败 → 仍不提交
        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertEqual(FS.size(pre), size)
        XCTAssertFalse(b.readJSONL("sessions.jsonl").contains { $0["session_id"] as? String == orphanSid }, "未提交：不当普通会话恢复")
        b.client.simulateCrash()
        // 第 3 次启动（盘恢复）：重做成功，行数相等
        Faults.clearSegmentFaults(under: root)
        let c = Harness(root: root, key: "")
        await c.settle()
        XCTAssertFalse(FS.exists(pre))
        XCTAssertEqual(segmentLines(proc.appendingPathComponent(orphanSid)).compactMap { $0["msg"] as? String },
                       ["orphan 0", "orphan 1", "orphan 2"])
    }

    // MARK: 🟠4 配置缓存记用户（E2）

    func testE2_PreconfigureSetUserExpiresOtherUsersCache() async throws {
        func prime() async -> (URL, FakeClock) {
            let sh = SharedHarness()
            sh.transport.configEcho = true
            sh.transport.configBody = ["etag": "a", "upload_level": "debug"]      // 远程明确给（不在 from_host）
            sh.shared.setUser("A")
            sh.configure()
            await sh.settle()
            XCTAssertEqual(sh.client.engine.configCache?.userId, "A")
            sh.client.simulateCrash()
            return (sh.base, sh.clock)
        }
        func launch(_ base: URL, _ clock: FakeClock, user: String) async -> [[String: Any]] {
            let t = FakeTransport()
            t.configHold = true                                                  // 离线：新配置不回
            let sh = SharedHarness(base: base, clock: clock, transport: t)
            sh.shared.setUser(user)
            sh.shared.log(.info, "i1")
            sh.configure()
            await sh.settle()
            sh.client.log(.info, "i2")
            let dir = sh.client.root.appendingPathComponent("proc-main/\(sh.client.writer.currentSessionId)")
            t.cancelAll()
            return segmentLines(dir).filter { ["i1", "i2"].contains($0["msg"] as? String ?? "") }
        }
        let (b1, c1) = await prime()
        let asB = await launch(b1, c1, user: "B")
        XCTAssertEqual(asB.count, 2)
        XCTAssertTrue(asB.allSatisfy { $0["oseq"] == nil }, "A 的放大覆盖不作用于 B")
        let (b2, c2) = await prime()
        let asA = await launch(b2, c2, user: "A")
        XCTAssertTrue(asA.allSatisfy { $0["oseq"] != nil }, "同一用户：缓存照用")
        let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: b2.appendingPathComponent("default/config.json"))) as? [String: Any])
        XCTAssertEqual(cfg["user_id"] as? String, "A")
    }

    // MARK: 🟠5 flush 兜底计时器先于一切等待（E5）

    func testE5_FlushTimerFiresWhileWorkQueueBlocked() async throws {
        let h = Harness()
        await h.settle()
        h.client.setFlushWindowForTesting(300)
        let release = await blockWork(h.client, seconds: 1.5)
        let t0 = nowNs()
        let r = await h.client.flush()
        let ms = elapsedMs(since: t0)
        release()
        XCTAssertEqual(r, .pending("timeout"))
        XCTAssertLessThan(ms, 1000, "约 300 ms 返回，不等 work 队列")
        await h.settle()
    }

    // MARK: 6 rtv.pre_init_dropped 强制写入、强制义务

    func testPreInitDroppedIgnoresHostLevels() async throws {
        let sh = SharedHarness()
        sh.shared.counter.add(level: .info, ts: 7)
        sh.configure(key: "") { $0.localLevel = .error; $0.uploadLevel = .fatal }
        await sh.settle()
        let dir = sh.client.root.appendingPathComponent("proc-main/\(sh.client.writer.currentSessionId)")
        let rep = try XCTUnwrap(segmentLines(dir).first { $0["tag"] as? String == "rtv.pre_init_dropped" })
        XCTAssertNotNil(rep["oseq"], "强制义务")
        // 禁用：不写，计数留着；重新启用后下一次调度写出
        let sh2 = SharedHarness()
        sh2.shared.setEnabled(false)
        sh2.shared.counter.add(level: .error, ts: 9)
        sh2.configure(key: "")
        await sh2.settle()
        XCTAssertEqual(sh2.shared.droppedCountForTesting, 1)
        sh2.client.setEnabled(true)
        await sh2.client.tickNow()
        XCTAssertEqual(sh2.shared.droppedCountForTesting, 0)
        let dir2 = sh2.client.root.appendingPathComponent("proc-main/\(sh2.client.writer.currentSessionId)")
        XCTAssertTrue(segmentLines(dir2).contains { $0["tag"] as? String == "rtv.pre_init_dropped" })
    }

    // MARK: 7 驱逐：先记墓碑、再删

    func testEvictionTombstoneFirst() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "a")
        await h.seal()
        h.clock.advance(1)
        h.client.log(.warn, "b")
        await h.seal()
        let files = h.outboxFiles()
        XCTAssertEqual(files.count, 2)
        Faults.failDirLocks(under: h.root)
        defer { Faults.clearDirLockFaults(under: h.root) }
        await h.work { e in
            e.effective.config.localCapBytes = 0
            e.evictIfNeeded()
        }
        XCTAssertEqual(h.outboxFiles(), files, "墓碑写不成：不删")
        XCTAssertFalse(FS.exists(h.root.appendingPathComponent("drops.jsonl")))
        Faults.clearDirLockFaults(under: h.root)
        await h.work { e in
            e.effective.config.localCapBytes = 0
            e.evictIfNeeded()
        }
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(h.readJSONL("drops.jsonl").map { $0["reason"] as? String }, ["buffer_overflow", "buffer_overflow"])
    }

    // MARK: 8 「已提交」三态

    func testPreStatErrorIsNeitherRedoneNorRecovered() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let root = makeTempDir("rtv-stat")
        let preDir = root.appendingPathComponent("pre")
        try FileManager.default.createDirectory(at: preDir, withIntermediateDirectories: true)
        let name = PreName.make()
        var bytes = PreFile.header(startedMs: 1, process: "main", device: dev)
        bytes += PreFile.r0 + LineEncoder.encode(LogLine(ts: 1, level: .warn, msg: "p")).body
        try Data(bytes).write(to: preDir.appendingPathComponent(name))
        let sid = IDs.newV4()
        let dir = root.appendingPathComponent("proc-main/\(sid)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = SessionMeta(sessionId: sid, sessionNo: 5, startedMs: 1, device: dev, process: "main", installId: nil)
        meta.pre = name
        try Data(meta.encode()).write(to: dir.appendingPathComponent("meta.json"))
        let seg = String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode(), as: UTF8.self)
            + "{\"seq\":1,\"oseq\":1,\"ts\":1,\"level\":\"warn\",\"msg\":\"partial\"}\n"
        try Data(seg.utf8).write(to: dir.appendingPathComponent("seg-000001.open"))
        XCTAssertEqual(chmod(preDir.path, 0o600), 0)                 // 不可搜索：stat(pre/x) 得 EACCES
        defer { chmod(preDir.path, 0o700) }
        let a = Harness(root: root, key: "")
        await a.settle()
        XCTAssertTrue(FS.exists(dir.appendingPathComponent("seg-000001.open")), "判不清：不重做、不恢复（段原样）")
        XCTAssertFalse(a.readJSONL("sessions.jsonl").contains { $0["session_id"] as? String == sid })
        a.client.simulateCrash()
        XCTAssertEqual(chmod(preDir.path, 0o700), 0)
        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertEqual(segmentLines(dir).compactMap { $0["msg"] as? String }, ["p"], "可判定后从 pre 文件重做")
    }

    // MARK: 9 configure 之前的 purge

    func testPreconfigurePurgeKeepsLaterLines() async throws {
        let sh = SharedHarness()
        sh.shared.log(.warn, "before")
        let done = Box<Bool>()
        sh.shared.purgeLocal { done.set(true) }
        sh.shared.log(.warn, "after")                               // purge 返回之后写的：在新 root 的新 pre 文件里
        await waitFor { done.value == true }
        let files = sh.preFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(preRecords(sh.preDir.appendingPathComponent(files[0])).dropFirst().count, 1)
        XCTAssertTrue(preRecords(sh.preDir.appendingPathComponent(files[0]))[1].contains("\"msg\":\"after\""))
    }

    /// 改名失败（root 所在目录只读）：逐项删除在后台、删完再回调；purge 之后新写的 pre 文件不被删。
    func testPreconfigurePurgeFallbackInBackground() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let sh = SharedHarness()
        sh.shared.log(.warn, "before")
        try FileManager.default.createDirectory(at: sh.defaultRoot.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sh.base.path, 0o500), 0)
        defer { chmod(sh.base.path, 0o700) }
        let done = Box<Bool>()
        let t0 = nowNs()
        sh.shared.purgeLocal { done.set(true) }
        XCTAssertLessThan(elapsedMs(since: t0), 500)
        sh.shared.log(.warn, "after")
        await waitFor { done.value == true }
        XCTAssertEqual(done.value, true)
        XCTAssertFalse(FS.exists(sh.defaultRoot.appendingPathComponent("outbox")), "旧内容删掉")
        let files = sh.preFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(preRecords(sh.preDir.appendingPathComponent(files[0])).contains { $0.contains("\"msg\":\"after\"") })
    }

    // MARK: 10 pre 文件建文件即加锁

    func testPreFileLockedAtCreation() async throws {
        let sh = SharedHarness()
        sh.shared.log(.info, "x")
        let url = sh.preDir.appendingPathComponent(sh.preFiles()[0])
        XCTAssertFalse(FS.withFreeFileLock(url), "建文件时已持锁")
    }

    // MARK: 12 bootstrap 重试时保留待写的合成行

    func testInstallRepairedNoteSurvivesBootstrapRetry() async throws {
        let root = makeTempDir("rtv-note")
        let a = Harness(root: root, key: "")
        await a.settle()
        a.client.log(.warn, "x")
        a.client.simulateCrash()
        try Data("garbage".utf8).write(to: root.appendingPathComponent("install.json"))
        Faults.failMetaWrites(under: root)
        defer { Faults.clearMetaFaults(under: root) }
        let b = Harness(root: root, key: "")
        XCTAssertNil(b.client.installId, "meta 写不成：bootstrap 失败")
        Faults.clearMetaFaults(under: root)
        await b.tick(advance: 5_000)
        await b.settle()
        XCTAssertNotNil(b.client.installId)
        XCTAssertTrue(b.openSegmentLines().contains { $0["tag"] as? String == "rtv.install_repaired" }, "证据没丢")
    }

    // MARK: ForegroundTracker 状态机（注入的通知源 / 主线程读取）

    final class FakeSource: ForegroundSource, @unchecked Sendable {
        let lock = NSLock()
        var available = true
        var isMainThread = false
        var app: Bool? = true
        var mainQueue: [@Sendable () -> Void] = []
        var handler: (@Sendable (ForegroundNote) -> Void)?
        func readForeground() -> Bool? { lock.lock(); defer { lock.unlock() }; return app }
        func onMain(_ f: @escaping @Sendable () -> Void) { lock.lock(); mainQueue.append(f); lock.unlock() }
        func observe(_ h: @escaping @Sendable (ForegroundNote) -> Void) { lock.lock(); handler = h; lock.unlock() }
        func runMain() { lock.lock(); let q = mainQueue; mainQueue = []; lock.unlock(); q.forEach { $0() } }
        func post(_ n: ForegroundNote) { lock.lock(); let h = handler; lock.unlock(); h?(n) }
        func setApp(_ v: Bool?) { lock.lock(); app = v; lock.unlock() }
    }

    final class Sink: PlatformEventSink, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        func platformEvent(_ e: PlatformEvent) { lock.lock(); events.append("\(e)"); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testTrackerOffMainStartsUnknownThenResolvesOnMain() {
        let src = FakeSource()
        src.setApp(false)
        let t = ForegroundTracker(source: src)
        let sink = Sink()
        t.subscribe(sink)
        t.install()
        XCTAssertNil(t.state, "非主线程触达：先记未知，不是前台")
        src.runMain()
        XCTAssertEqual(t.state, false, "主线程补读真实状态")
        XCTAssertEqual(sink.all, ["foregroundStateChanged(false)"])
        t.install()
        XCTAssertNil(src.mainQueue.first, "只装一次")
    }

    func testTrackerOnMainReadsImmediatelyAndFollowsNotifications() {
        let src = FakeSource()
        src.isMainThread = true
        let t = ForegroundTracker(source: src)
        let sink = Sink()
        t.subscribe(sink)
        t.install()
        XCTAssertEqual(t.state, true)
        src.post(.didEnterBackground)
        XCTAssertEqual(t.state, false)
        src.post(.willEnterForeground)
        XCTAssertEqual(t.state, true)
        src.setApp(false)
        src.post(.willResignActive)                                  // 重读真实状态
        XCTAssertEqual(t.state, false)
        src.setApp(nil)
        src.post(.didBecomeActive)                                   // 读不到：保持原值
        XCTAssertEqual(t.state, false)
        src.setApp(true)
        src.post(.didBecomeActive)
        XCTAssertEqual(t.state, true)
        XCTAssertEqual(sink.all, ["foregroundStateChanged(true)", "didEnterBackground", "willEnterForeground",
                                  "foregroundStateChanged(false)", "foregroundStateChanged(true)"])
    }

    func testTrackerUnavailableInExtensions() {
        let src = FakeSource()
        src.available = false
        src.isMainThread = true
        let t = ForegroundTracker(source: src)
        t.install()
        XCTAssertNil(t.state)
        XCTAssertNil(src.handler, "扩展里不观察")
    }
}

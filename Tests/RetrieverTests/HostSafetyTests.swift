import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 对宿主的承诺（ADR 0020 决定 1 / 2）：宿主线程永不等待 SDK 后台线程；`setEnabled` 落盘、跨重启与进程有效。
/// 「不阻塞」类用例把引擎的 work 队列堵 3 s，断言宿主侧调用远早于此返回（上限放宽到 500 ms，负载高时不偶发）。
final class HostSafetyTests: XCTestCase {
    // MARK: 宿主线程不等待（决定 1）

    /// fatal：行在返回前已落盘、段已换；封段与物化投递到后台，引擎忙时也立即返回（修复前：work.sync 等到引擎空闲）。
    func testFatalReturnsWhileEngineBusy() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.info, "context")
        let release = await blockWork(h.client)
        let t0 = nowNs()
        h.client.log(.fatal, "dying")
        XCTAssertLessThan(elapsedMs(since: t0), 500, "引擎被堵 3 s，fatal 不等")
        XCTAssertEqual(h.client.writer.snapshot.segNo, 2, "段已换")
        XCTAssertEqual(h.outboxFiles(), [], "封段物化还在后台排队")
        release()
        await h.settle()
        XCTAssertEqual(h.outboxFiles("p0").count, 1)
        XCTAssertTrue(FS.exists(h.sessionDir().appendingPathComponent("seg-000001.sealed")))
        let e = try XCTUnwrap(h.envelopes("p0").first?.1)
        XCTAssertEqual(lines(of: e).map { $0["msg"] as? String }, ["context", "dying"])
    }

    /// purgeLocal：调用线程只取消在途请求并置「清空中」，立即返回；排在前面的排空不再取批；
    /// 完成回调里 installId 已是新值、root 已清（修复前：onWorkSync 等到引擎空闲）。
    func testPurgeReturnsImmediately() async throws {
        let h = Harness(key: "")
        await h.settle()
        let oldId = try XCTUnwrap(h.client.installId)
        h.client.log(.warn, "to purge")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().count, 1)
        await h.work { $0.key = "lk_test_demo_abc_12345678" }
        let release = await blockWork(h.client)
        h.client.kickDrain()                              // 排空排在清空前面
        let inCallback = Box<String>()
        let c = h.client
        let t0 = nowNs()
        c.purgeLocal { inCallback.set(c.installId ?? "") }
        XCTAssertLessThan(elapsedMs(since: t0), 500, "引擎被堵 3 s，purgeLocal 不等")
        XCTAssertEqual(h.client.installId, oldId, "返回时清空尚未完成")
        release()
        await waitFor { inCallback.value != nil }
        await h.settle()
        let newId = try XCTUnwrap(inCallback.value)
        XCTAssertNotEqual(newId, oldId, "回调里 installId 已变")
        XCTAssertEqual(h.client.installId, newId)
        XCTAssertEqual(h.transport.batchRequests.count, 0, "排在前面的排空没把要清的批发出去")
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(FS.list(h.root.appendingPathComponent("proc-main")), [h.client.writer.currentSessionId])
        XCTAssertEqual(purgeSiblings(h.root), [])
    }

    /// 清空期间宿主照常写（ADR 0019 决定 9）：任何删除都发生在替代物（新 root、新 install、新会话）提交之后——
    /// 每一行 log() 都落在旧会话或新会话里（占了 seq），没有一行返回空结果；回调看到新 installId 之后写的行全在新会话里。
    /// 旧会话段先做硬链接留底：改名出去的旧 root 删掉后仍能读回写进旧会话的行（这些行按设计随旧状态一起删除）。
    /// 修复前：先放弃写入侧会话、删完旧 root 才建新会话，其间的 log() 既不落盘也不占 seq（静默丢）。
    func testLogDuringPurgeIsNotSilentlyDropped() async throws {
        let h = Harness(key: "")
        await h.settle()
        let c = h.client
        let oldId = try XCTUnwrap(c.installId)
        let oldSid = c.writer.currentSessionId
        let link = makeTempDir("rtv-link").appendingPathComponent("old-seg")
        try FileManager.default.linkItem(at: h.sessionDir().appendingPathComponent("seg-000001.open"), to: link)
        let release = await blockWork(c)
        let done = Box<Bool>()
        c.purgeLocal { done.set(true) }
        release()
        // 清空进行中持续写（至少 50 行），直到完成回调；之后再写 10 行
        var n = 0
        var afterChange: [String] = []
        func logOne() {
            if c.installId != oldId { afterChange.append("m\(n)") }
            c.log(.warn, "m\(n)")
            n += 1
        }
        while !(done.value == true && n >= 50) && n < 5000 {
            logOne()
            usleep(100)
        }
        await waitFor { done.value == true }
        XCTAssertEqual(done.value, true)
        for _ in 0..<10 { logOne() }
        await h.settle()
        XCTAssertNotEqual(c.installId, oldId)
        XCTAssertNotEqual(c.writer.currentSessionId, oldSid, "写入侧已切到新会话")
        let old = try String(contentsOf: link, encoding: .utf8).split(separator: "\n").dropFirst()
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let fresh = h.openSegmentLines()
        let msgs = { (ls: [[String: Any]]) in ls.compactMap { $0["msg"] as? String } }
        XCTAssertEqual(msgs(Array(old)) + msgs(fresh), (0..<n).map { "m\($0)" }, "每一行都占了 seq：前一段在旧会话、其余在新会话，没有空结果")
        XCTAssertEqual(fresh.map { int($0["seq"]) }, (1...Int64(fresh.count)).map { $0 }, "新会话从 seq 1 连续")
        XCTAssertGreaterThanOrEqual(fresh.count, afterChange.count)
        XCTAssertTrue(Set(afterChange).isSubset(of: Set(msgs(fresh))), "看到新 installId 之后写的行全在新会话")
        XCTAssertEqual(purgeSiblings(h.root), [], "改名出去的旧 root 已删")
    }

    /// 换 root 的 configure：旧实例只投递收尾、不等待；共享锁内不等，另一个线程的 log() 不被挂住（修复前：持锁 work.sync）。
    func testConfigureRootChangeDoesNotBlock() async throws {
        let base = makeTempDir("rtv-shared")
        let clock = FakeClock()
        let shared = SharedClient(rootFor: { base.appendingPathComponent($0 ?? "default") },
                                  make: { root, key, url, options, enabled in
                                      RetrieverClient(root: root, key: key, baseURL: url, options: options, clock: clock,
                                                      transport: FakeTransport(), platform: FakePlatform(), enabled: enabled)
                                  })
        let url = URL(string: "https://logs-test.invalid")!
        shared.configure(key: "", baseURL: url, options: Options())
        let old = shared.client()
        await old.settle()
        old.log(.warn, "old root")
        let release = await blockWork(old)
        var o = Options()
        o.appGroup = "group.test"
        let cfgMs = Box<Double>()
        let opts = o
        DispatchQueue.global().async {
            let t0 = nowNs()
            shared.configure(key: "", baseURL: url, options: opts)
            cfgMs.set(elapsedMs(since: t0))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let t1 = nowNs()
        shared.client().log(.warn, "meanwhile")
        XCTAssertLessThan(elapsedMs(since: t1), 500, "别的线程的 log() 不被换 root 挂住")
        await waitFor { cfgMs.value != nil }
        XCTAssertLessThan(try XCTUnwrap(cfgMs.value), 500, "configure 不等旧实例的后台收尾")
        let fresh = shared.client()
        XCTAssertFalse(fresh === old)
        XCTAssertEqual(fresh.root.path, base.appendingPathComponent("group.test").path)
        release()
        await old.settle()
        await fresh.settle()
        // 旧实例的收尾在后台完成：段已封、义务行已物化
        let oldOutbox = FS.list(base.appendingPathComponent("default/outbox")).filter { $0.hasSuffix(".gz") }
        XCTAssertEqual(oldOutbox.count, 1)
    }

    // MARK: setEnabled 落盘（决定 2）

    /// 禁用跨重启：同一 root 重建后仍禁用，log() 不占 seq，0 次上传、0 次拉配置；重新启用删标记、排空、拉配置
    /// （修复前：只改内存，重启回到启用）。
    func testDisabledPersistsAcrossRestart() async throws {
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        a.client.log(.warn, "queued")
        await a.seal()
        a.client.setEnabled(false)
        await a.settle()
        XCTAssertFalse(a.client.isEnabled)
        XCTAssertTrue(FS.exists(disabledMarker(root)), "标记在 root 同级")
        XCTAssertFalse(FS.exists(root.appendingPathComponent(".disabled")))
        a.client.simulateCrash()

        let b = Harness(root: root)
        await b.settle()
        XCTAssertFalse(b.client.isEnabled)
        b.client.log(.error, "not written")
        XCTAssertEqual(b.client.debugCounters.seq, 0)
        await b.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertEqual(b.transport.batchRequests.count, 0)
        XCTAssertEqual(b.transport.configRequests.count, 0)
        XCTAssertEqual(b.client.debugLastStopReason, "disabled")
        XCTAssertEqual(b.outboxFiles().count, 1)
        XCTAssertFalse(b.envelopes().contains { lines(of: $0.1).contains { $0["synthetic"] as? Bool == true } }, "禁用时恢复不合成行")

        b.client.setEnabled(true)
        XCTAssertTrue(b.client.isEnabled)
        XCTAssertFalse(FS.exists(disabledMarker(root)))
        await b.settle()
        XCTAssertEqual(b.transport.batchRequests.count, 1)
        XCTAssertGreaterThan(b.transport.configRequests.count, 0)
        b.client.log(.warn, "written again")
        XCTAssertEqual(b.client.debugCounters.seq, 1)
    }

    /// 禁用期间不拉配置：轮询到期、回前台都不发（修复前：照常带 install_id / user_id 拉配置）。
    func testDisabledStopsConfigPoll() async throws {
        let h = Harness()
        await h.settle()
        h.client.setUser("u1")
        await h.settle()
        h.client.setEnabled(false)
        await h.settle()
        let n0 = h.transport.configRequests.count
        await h.tick(advance: 31 * 60_000)
        h.client.platformEvent(.willEnterForeground)
        await h.settle()
        h.client.setUser("u2")
        await h.settle()
        XCTAssertEqual(h.transport.configRequests.count, n0)
    }

    /// 禁用状态下清空：新 install_id；0 次请求；标记在 root 外面，照样在、照样禁用。
    func testPurgeWhileDisabled() async throws {
        let h = Harness()
        await h.settle()
        h.client.setEnabled(false)
        await h.settle()
        let oldId = h.client.installId
        let (b0, c0) = (h.transport.batchRequests.count, h.transport.configRequests.count)
        let newId = await purgeAndWait(h.client)
        await h.settle()
        XCTAssertNotEqual(newId, oldId)
        XCTAssertEqual(h.transport.batchRequests.count, b0)
        XCTAssertEqual(h.transport.configRequests.count, c0, "禁用时清空后不拉配置")
        XCTAssertTrue(FS.exists(disabledMarker(h.root)))
        XCTAssertFalse(h.client.isEnabled)
    }

    /// setEnabled(false) 之前已排进引擎队列的取批与拉配置：上传 / 拉配置的开关读宿主设的那一个（调用返回即生效），
    /// 不读引擎队列上滞后的副本——放行后 0 次上传、0 次拉配置（修复前：排在前面的决策仍按副本「启用」发出请求）。
    func testDisableStopsAlreadyQueuedDrainAndConfig() async throws {
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "queued")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().count, 1)
        let c = h.client
        let release = await blockWork(c)
        c.reconfigure(key: "lk_test_demo_abc_12345678", baseURL: URL(string: "https://logs-test.invalid")!, options: Options())
        c.kickDrain()
        c.fetchConfig()
        try? await Task.sleep(nanoseconds: 50_000_000)    // 取批、拉配置都已排进 work 队列，在禁用之前
        c.setEnabled(false)
        release()
        await h.settle()
        XCTAssertEqual(h.transport.batchRequests.count, 0)
        XCTAssertEqual(h.transport.configRequests.count, 0)
        XCTAssertEqual(h.client.debugLastStopReason, "disabled")
        XCTAssertEqual(h.outboxFiles().count, 1)
    }

    /// 多进程：A 禁用后，同一 root 的 B 在下一次决策时就看到标记，停传、停拉配置；B 的写入要到它自己调用或重启才停。
    func testMarkerSeenAcrossProcesses() async throws {
        let root = makeTempDir()
        var oa = Options()
        oa.processName = "main"
        var ob = Options()
        ob.processName = "ext"
        let a = Harness(root: root, key: "", options: oa)
        await a.settle()
        a.client.log(.warn, "shared outbox")
        await a.seal()
        let b = Harness(root: root, key: "", options: ob)
        await b.settle()
        a.client.setEnabled(false)
        await a.settle()
        await b.enableUpload(options: ob)
        XCTAssertEqual(b.transport.batchRequests.count, 0)
        XCTAssertEqual(b.transport.configRequests.count, 0)
        XCTAssertEqual(b.client.debugLastStopReason, "disabled")
        XCTAssertTrue(b.client.isEnabled)
        b.client.log(.warn, "b still writes")
        XCTAssertEqual(b.client.debugCounters.seq, 1)
    }

    /// 标记写失败（root 所在目录只读）：内存照样禁用；恢复写权限后下一次调度 tick 写成。
    func testMarkerWriteRetry() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let parent = makeTempDir("rtv-ro")
        let root = parent.appendingPathComponent("r")
        let h = Harness(root: root, key: "")
        await h.settle()
        XCTAssertEqual(chmod(parent.path, 0o500), 0)
        defer { chmod(parent.path, 0o700) }
        h.client.setEnabled(false)
        await h.settle()
        XCTAssertFalse(FS.exists(disabledMarker(root)))
        XCTAssertFalse(h.client.isEnabled, "标记没写成也照样禁用")
        h.client.log(.warn, "not written")
        XCTAssertEqual(h.client.debugCounters.seq, 0)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        await h.tick(advance: ClientConstants.markerRetryMs)
        XCTAssertTrue(FS.exists(disabledMarker(root)))
    }

    /// 持久禁用后每次启动都是一个空会话：不写终态、目录直接删，sessions.jsonl 不增长（ADR 0019 决定 1）。
    func testEmptySessionsNotRecorded() async throws {
        let root = makeTempDir()
        var h = Harness(root: root, key: "")
        await h.settle()
        h.client.setEnabled(false)
        await h.settle()
        for _ in 0..<20 {
            h.client.simulateCrash()
            h = Harness(root: root, key: "")
            await h.settle()
        }
        XCTAssertEqual(h.readJSONL("sessions.jsonl").count, 0)
        XCTAssertEqual(FS.list(root.appendingPathComponent("proc-main")), [h.client.writer.currentSessionId])
    }

    /// configure 之前的禁用：懒建的默认实例落盘；换 root 时禁用状态带到新实例并落盘到新 root 旁，新实例不上传。
    func testDisabledCarriedAcrossRootChange() async throws {
        let base = makeTempDir("rtv-shared")
        let clock = FakeClock()
        let transport = FakeTransport()
        let shared = SharedClient(rootFor: { base.appendingPathComponent($0 ?? "default") },
                                  make: { root, key, url, options, enabled in
                                      RetrieverClient(root: root, key: key, baseURL: url, options: options, clock: clock,
                                                      transport: transport, platform: FakePlatform(), enabled: enabled)
                                  })
        shared.client().setEnabled(false)
        await shared.client().settle()
        XCTAssertTrue(FS.exists(disabledMarker(base.appendingPathComponent("default"))))
        var o = Options()
        o.appGroup = "group.test"
        shared.configure(key: "lk_test_demo_abc_12345678", baseURL: URL(string: "https://logs-test.invalid")!, options: o)
        let fresh = shared.client()
        await fresh.settle()
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertTrue(FS.exists(disabledMarker(base.appendingPathComponent("group.test"))))
        XCTAssertEqual(transport.configRequests.count, 0)
        XCTAssertEqual(transport.batchRequests.count, 0)
        // 反向：新 root 旁有上次留下的标记，但宿主在 configure 之前显式 setEnabled(true) → 带过去、删新 root 的标记
        fresh.setEnabled(true)
        o.appGroup = "group.other"
        try Data().write(to: disabledMarker(base.appendingPathComponent("group.other")))
        shared.configure(key: "lk_test_demo_abc_12345678", baseURL: URL(string: "https://logs-test.invalid")!, options: o)
        let other = shared.client()
        await other.settle()
        XCTAssertTrue(other.isEnabled)
        XCTAssertFalse(FS.exists(disabledMarker(base.appendingPathComponent("group.other"))))
    }
}

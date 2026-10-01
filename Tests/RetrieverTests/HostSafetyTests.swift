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
        _ = await h.work { $0.setTarget(key: "lk_test_demo_abc_12345678", baseURL: $0.baseURL) }
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

    /// 第二次 configure 改 appGroup（ADR 0023 决定 5：实例身份只认首次）：不换实例、不等引擎（引擎被堵 3 s 也立即返回），
    /// 另一个线程的 log() 不被挂住，行继续进原会话，留合成 warn `rtv.reconfigure_ignored`。
    /// 0.2.0 的同名用例测的是「换 root → shutdown 旧实例 + 建新实例」不阻塞；该路径已删除，改为断言忽略且不阻塞。
    func testConfigureRootChangeDoesNotBlock() async throws {
        let sh = SharedHarness()
        sh.configure(key: "")
        let c = sh.client
        await c.settle()
        c.log(.warn, "first root")
        let release = await blockWork(c)
        let cfgMs = Box<Double>()
        let shared = sh.shared
        DispatchQueue.global().async {
            var o = Options()
            o.appGroup = "group.test"
            let t0 = nowNs()
            shared.configure(key: "", baseURL: SharedHarness.url, options: o)
            cfgMs.set(elapsedMs(since: t0))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let t1 = nowNs()
        sh.shared.log(.warn, "meanwhile")
        XCTAssertLessThan(elapsedMs(since: t1), 500, "别的线程的 log() 不被挂住")
        await waitFor { cfgMs.value != nil }
        XCTAssertLessThan(try XCTUnwrap(cfgMs.value), 500, "configure 不等引擎")
        XCTAssertTrue(sh.client === c, "不换实例")
        XCTAssertEqual(c.root.path, sh.defaultRoot.path)
        release()
        await c.settle()
        let ls = segmentLines(c.engine.current!.dir)
        XCTAssertEqual(ls.compactMap { $0["msg"] as? String }.filter { ["first root", "meanwhile"].contains($0) }, ["first root", "meanwhile"])
        let ign = ls.filter { $0["tag"] as? String == "rtv.reconfigure_ignored" }
        XCTAssertEqual(ign.count, 1)
        XCTAssertEqual((ign.first?["attrs"] as? [String: Any])?["field"] as? String, "app_group")
        XCTAssertFalse(FS.exists(sh.base.appendingPathComponent("group.test")), "没在新 root 建任何东西")
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

    /// configure 之前的 setEnabled（ADR 0023：此时没有实例，文件级落盘）：false → 默认 root 旁的标记立即写成；configure 到
    /// 另一个 root（appGroup）时显式值交给实例、落盘到新 root 旁，实例不写不传。反向：configure 之前显式 true → 删掉新 root 的旧标记。
    /// 0.2.0 的同名用例测的是懒建实例换 root 时的交接；懒建实例已删除，改为测 configure 之前的文件级语义与交接。
    func testDisabledCarriedAcrossRootChange() async throws {
        let sh = SharedHarness()
        sh.shared.setEnabled(false)
        XCTAssertFalse(sh.shared.isEnabled)
        XCTAssertTrue(FS.exists(disabledMarker(sh.defaultRoot)), "configure 之前立即落盘")
        sh.shared.log(.error, "not written")
        XCTAssertEqual(sh.preFiles(), [], "禁用：零写入")
        sh.configure { $0.appGroup = "group.test" }
        let c = sh.client
        await c.settle()
        XCTAssertFalse(c.isEnabled)
        XCTAssertTrue(FS.exists(disabledMarker(sh.base.appendingPathComponent("group.test"))))
        XCTAssertEqual(sh.transport.configRequests.count, 0)
        XCTAssertEqual(sh.transport.batchRequests.count, 0)

        // 反向：新 root 旁有上次留下的标记，宿主在 configure 之前显式 setEnabled(true) → 交给实例、删新 root 的标记
        let sh2 = SharedHarness()
        try FileManager.default.createDirectory(at: sh2.base, withIntermediateDirectories: true)
        try Data().write(to: disabledMarker(sh2.base.appendingPathComponent("group.other")))
        sh2.shared.setEnabled(true)
        sh2.configure { $0.appGroup = "group.other" }
        await sh2.settle()
        XCTAssertTrue(sh2.client.isEnabled)
        XCTAssertFalse(FS.exists(disabledMarker(sh2.base.appendingPathComponent("group.other"))))
    }
}

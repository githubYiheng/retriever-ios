import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 宿主误用加固（ADR 0024；简报 §4.4–4.6 / §7 / §8 / §9；§11 N、P、Q、R、S）。
final class HardeningTests: XCTestCase {
    // MARK: N. 读失败、段消失、root 消失、目录锁

    /// 物化时段读不出（非 ENOENT）：不推进游标、不写批；可读后下一次物化一并带上（修复前：推进游标，义务行静默丢）。
    func testN_SegmentReadFailureDoesNotAdvanceCursor() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let h = Harness(key: "")
        await h.settle()
        h.client.log(.warn, "a")
        h.client.log(.warn, "b")
        let open = try XCTUnwrap(h.client.debugOpenSegmentPath)
        XCTAssertEqual(chmod(open, 0), 0)
        await h.seal()
        XCTAssertEqual(h.outboxFiles(), [])
        let cur = await h.work { $0.current!.cursor.extractedThroughOseq }
        XCTAssertEqual(cur, 0, "读失败不推进")
        XCTAssertEqual(chmod(h.sessionDir().appendingPathComponent("seg-000001.sealed").path, 0o600), 0)
        h.client.log(.warn, "c")
        await h.seal()
        let e = try XCTUnwrap(h.envelopes().first?.1)
        XCTAssertEqual(lines(of: e).map { $0["msg"] as? String }, ["a", "b", "c"])
    }

    /// 段文件确已不存在：先对它的义务区间记墓碑（corrupt）、再推进游标，后面的行照常成批。
    func testN_MissingSegmentTombstonedThenAdvanced() async throws {
        var o = Options()
        o.dailyBatchCap = 1
        let h = Harness(key: "", options: o)
        await h.settle()
        h.client.log(.warn, "first")
        await h.seal()
        XCTAssertEqual(h.outboxFiles().count, 1)
        h.client.log(.warn, "deferred")                        // 日上限：p1 推迟，段已封、游标不动
        await h.seal()
        XCTAssertEqual(h.outboxFiles().count, 1)
        try FileManager.default.removeItem(at: h.sessionDir().appendingPathComponent("seg-000002.sealed"))
        h.client.log(.error, "err")
        await h.seal()
        let drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?["reason"] as? String, "corrupt")
        XCTAssertEqual(int(drops.first?["oseq_from"]), 2)
        XCTAssertEqual(int(drops.first?["oseq_to"]), 2)
        let p0 = try XCTUnwrap(h.envelopes("p0").first?.1)
        XCTAssertEqual(int(p0["oseq_from"]), 3)
        let cur = await h.work { $0.current!.cursor.extractedThroughOseq }
        XCTAssertEqual(cur, 3)
    }

    /// root 在运行中被删：封段时发现段文件已被 unlink → 重新 bootstrap（新 install）+ 合成 warn `rtv.root_vanished`；
    /// 写进被删 inode 的行计数，以 `rtv.pre_init_dropped` 上报。
    func testN_RootDeletedRebootstraps() async throws {
        let h = Harness(key: "")
        await h.settle()
        let oldId = try XCTUnwrap(h.client.installId)
        h.client.log(.warn, "before")
        try FileManager.default.removeItem(at: h.root)
        h.client.log(.error, "into deleted inode")
        await h.sealAndDrain()
        XCTAssertNotNil(h.client.installId)
        XCTAssertNotEqual(h.client.installId, oldId, "root 没了：新 install")
        let ls = h.openSegmentLines()
        let rv = try XCTUnwrap(ls.first { $0["tag"] as? String == "rtv.root_vanished" })
        XCTAssertEqual(rv["msg"] as? String, "session directory vanished; new session started")
        XCTAssertEqual(rv["synthetic"] as? Bool, true)
        let rep = try XCTUnwrap(ls.first { $0["tag"] as? String == "rtv.pre_init_dropped" })
        XCTAssertEqual(int((rep["attrs"] as? [String: Any])?["count"]), 2)
        XCTAssertEqual(int((rep["attrs"] as? [String: Any])?["error_count"]), 1)
        h.client.log(.warn, "after")
        XCTAssertTrue(h.openSegmentLines().contains { $0["msg"] as? String == "after" })
    }

    /// 只有会话目录被删：换段时 open 得 ENOENT → 重新 bootstrap（同一 install、新会话）+ `rtv.root_vanished`。
    func testN_SessionDirDeletedDetectedOnRotate() async throws {
        let h = Harness(key: "")
        await h.settle()
        let iid = h.client.installId
        let oldSid = h.client.writer.currentSessionId
        try FileManager.default.removeItem(at: h.sessionDir())
        h.client.log(.fatal, "rotates into missing dir")
        await h.settle()
        XCTAssertEqual(h.client.installId, iid)
        XCTAssertNotEqual(h.client.writer.currentSessionId, oldSid)
        XCTAssertTrue(h.openSegmentLines().contains { $0["tag"] as? String == "rtv.root_vanished" })
    }

    /// 目录锁拿不到（打不开目录）：不执行临界区（修复前：不加锁直接执行）。
    func testN_DirLockUnavailableSkipsCriticalSection() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let h = Harness(key: "")
        await h.settle()
        XCTAssertEqual(chmod(h.root.path, 0o300), 0)            // 可写可搜索、不可读：open(O_RDONLY) 失败
        defer { chmod(h.root.path, 0o700) }
        var ran = false
        XCTAssertNil(FS.withDirLock(h.root) { ran = true })
        XCTAssertFalse(ran)
        let ok = await h.work { $0.appendDrops([DropEntry(sessionId: IDs.newV4(), oseqFrom: 1, oseqTo: 1, n: 1, reason: "corrupt", atMs: 1, lastAckAgeMs: -1)]) }
        XCTAssertFalse(ok)
        XCTAssertEqual(chmod(h.root.path, 0o700), 0)
        XCTAssertFalse(FS.exists(h.root.appendingPathComponent("drops.jsonl")))
    }

    // MARK: P. 换 key

    func testP_KeyChangeClearsAuthPauseAndResendsMapping() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.warn, "first")
        await h.sealAndDrain()
        let fp0 = await h.work { $0.mapping?.keyFp }
        XCTAssertNotNil(fp0)
        h.transport.setScript([.status(401, ["reason": "key_revoked"], [:])])
        h.clock.advance(Limits.minRequestSpacingMs)
        h.client.log(.warn, "second")
        await h.sealAndDrain()
        XCTAssertEqual(h.client.debugLastStopReason, "paused")
        let n = h.transport.batchRequests.count
        h.client.reconfigure(key: "lk_test_demo_new_87654321", baseURL: URL(string: "https://logs-test.invalid")!, options: Options())
        await h.settle()
        await h.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertGreaterThan(h.transport.batchRequests.count, n, "暂停清掉、立即可传")
        let last = try XCTUnwrap(h.transport.batchRequests.last)
        XCTAssertEqual(last.headers["Authorization"], "Bearer lk_test_demo_new_87654321")
        XCTAssertNil(decodeEnvelope(last.body!)?["mapping"], "换 key 之前物化的批不带（映射在物化时附上）")
        XCTAssertEqual(h.outboxFiles(), [])
        // 换 key 之后物化的第一批重新带映射（未确认）
        h.client.log(.warn, "third")
        await h.sealAndDrain()
        await h.tick(advance: Limits.minRequestSpacingMs)
        let next = try XCTUnwrap(h.transport.batchRequests.last)
        XCTAssertNotNil(decodeEnvelope(next.body!)?["mapping"], "映射标为未确认：重发")
        let fp1 = await h.work { $0.mapping?.keyFp }
        XCTAssertEqual(fp1, ConfigRules.keyFingerprint("lk_test_demo_new_87654321"), "确认后记新指纹")
        let bo = try XCTUnwrap(h.json("backoff.json"))
        XCTAssertEqual(bo["key_fp"] as? String, ConfigRules.keyFingerprint("lk_test_demo_new_87654321"))
    }

    /// 旧 key 的在途请求回 401 / 403：不暂停新 key、不计失败；批留着用新 key 重发。
    func testP_StaleKey401DoesNotPauseNewKey() async throws {
        let h = Harness()
        await h.settle()
        h.client.log(.warn, "w")
        await h.seal()
        let (name, oldFp) = await h.work { e in (e.metas.keys.first!, e.keyFp) }
        let (reason, fails, kept) = await h.work { e -> (String, Int, Bool) in
            e.setTarget(key: "lk_test_demo_new_87654321", baseURL: e.baseURL)
            e.inFlight = name
            _ = e.handleResponse(name: name, response: HTTPResponse(status: 401, body: Data("{\"reason\":\"key_revoked\"}".utf8)), keyFp: oldFp)
            return (e.backoff.reason, e.fails[name]?.count ?? 0, e.metas[name] != nil)
        }
        XCTAssertFalse(reason.hasPrefix("auth:"))
        XCTAssertEqual(fails, 0)
        XCTAssertTrue(kept)
    }

    // MARK: Q. 节流

    func testQ_FatalBurstSealsOnceThenMerges() async throws {
        let h = Harness(key: "")
        await h.settle()
        for i in 0..<100 { h.client.log(.fatal, "f\(i)") }
        await h.settle()
        XCTAssertEqual(h.client.writer.snapshot.segNo, 2, "1 次立即换段")
        XCTAssertEqual(h.outboxFiles().count, 1)
        XCTAssertEqual(h.client.writer.snapshot.segLines, 99, "其余照常逐行落盘")
        await h.tick(advance: Limits.errorSealMinIntervalMs)
        XCTAssertEqual(h.outboxFiles().count, 2, "并入 error 去抖封段")
        // 窗口过后的 fatal 又能立即换段
        h.client.log(.fatal, "later")
        await h.settle()
        XCTAssertEqual(h.outboxFiles().count, 3)
    }

    func testQ_FlushBurstOneMarker() async throws {
        let h = Harness()
        await h.settle()
        h.client.setFlushWindowForTesting(1500)
        h.transport.defaultReply = .hang
        let c = h.client
        let results = await withTaskGroup(of: FlushResult.self) { g -> [FlushResult] in
            for _ in 0..<100 { g.addTask { await c.flush() } }
            var out: [FlushResult] = []
            for await r in g { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 100)
        XCTAssertEqual(Set(results.map { "\($0)" }).count, 1, "同一结果")
        h.transport.cancelAll()
        await h.settle()
        let markers = segmentLines(h.sessionDir()).filter { $0["tag"] as? String == "rtv.flush" }
        XCTAssertEqual(markers.count, 1, "1 条标记行")
        // 之后有新的义务行：新的 flush 追加新的标记
        h.transport.defaultReply = .echo
        h.client.log(.warn, "new")
        _ = await h.client.flush()
        XCTAssertEqual(segmentLines(h.sessionDir()).filter { $0["tag"] as? String == "rtv.flush" }.count, 2)
    }

    /// flush 等待中被禁用 → "disabled"。
    func testQ_FlushDisabledWhileWaiting() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .hang
        h.client.setFlushWindowForTesting(3000)
        let c = h.client
        async let r = c.flush()
        await waitFor { h.transport.hangingCount == 1 }
        c.setEnabled(false)
        h.transport.cancelAll()
        let got = await r
        XCTAssertEqual(got, .pending("disabled"))
    }

    // MARK: R. 按位置判定

    func testR_AttrsLookalikesDoNotFoolPriorityOrSplitOrRecovery() async throws {
        var o = Options()
        o.uploadLevel = .info
        let h = Harness(key: "", options: o)
        await h.settle()
        let fake: [String: AttrValue] = ["a": .number(1), "ctx": .bool(true), "level": .string("error"), "synthetic": .bool(true),
                                         "tag": .string("rtv.unclean_exit")]
        h.client.log(.info, "x", attrs: fake)
        h.client.log(.info, "y")
        await h.seal()
        let name = try XCTUnwrap(h.outboxFiles().first)
        XCTAssertTrue(name.hasPrefix("p1-"), "attrs 里的 level:error 不把批抬成 p0")
        let meta = await h.work { $0.metas[name]! }
        XCTAssertFalse(meta.hasError)
        // 413 切分：attrs 里的 ctx:true 不让义务行被当成上下文
        _ = await h.work { $0.split413(name) }
        let ranges = h.envelopes().map { (int($0.1["oseq_from"]), int($0.1["oseq_to"])) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(ranges.map { $0.0 }, [1, 2], "两条义务行各成半批")
        // 恢复判重：最后一行 attrs 里有 tag / synthetic 的同名键，不算已合成
        h.client.log(.warn, "last", attrs: fake)
        let sid = h.client.writer.currentSessionId
        h.client.simulateCrash()
        let h2 = Harness(root: h.root, key: "")
        await h2.settle()
        let last = try XCTUnwrap(segmentLines(h.root.appendingPathComponent("proc-main/\(sid)")).last)
        XCTAssertEqual(last["tag"] as? String, "rtv.unclean_exit")
        XCTAssertEqual(last["msg"] as? String, "process ended while foregrounded")
    }

    // MARK: S. redact 改 ts、空用户、SDK 自己取消的请求

    func testS_RedactCannotChangeTsAndEmptyUserIsNil() async throws {
        let box = Box<Int64>()
        box.set(-1)
        var o = Options()
        o.redact = { l in var x = l; x.ts = box.value!; return x }
        let h = Harness(key: "", options: o)
        await h.settle()
        h.client.log(.warn, "neg")
        box.set(1 << 60)
        h.client.log(.warn, "huge")
        let ls = h.openSegmentLines()
        XCTAssertEqual(ls.map { int($0["ts"]) }, [h.clock.wallMs(), h.clock.wallMs()])
        h.client.setUser("u")
        h.client.setUser("")
        XCTAssertNil(h.client.writer.currentUser)
        h.client.setUser(" \t ")
        XCTAssertNil(h.client.writer.currentUser)
        XCTAssertEqual(Text.sanitizeUserId("\u{1}\u{2}"), nil)
        XCTAssertEqual(Text.sanitizeUserId(" a "), " a ", "非空白的值原样保留")
    }

    func testS_SdkCancelledRequestNotCountedAsFailure() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .hang
        h.client.log(.warn, "w")
        h.client.platformEvent(.didEnterBackground)
        let token = try XCTUnwrap(h.platform.begunTokens.first)
        await waitFor { h.transport.hangingCount == 1 }
        h.platform.expire(token)                                // 后台到期：SDK 取消在途请求
        await h.settle()
        let fails = await h.work { $0.fails.values.map(\.count).reduce(0, +) }
        XCTAssertEqual(fails, 0, "SDK 自己取消的请求不计毒批失败")
        let bo = await h.work { $0.backoff }
        XCTAssertEqual(bo.attempt, 0, "也不推高退避（盲审裁决 11）")
        XCTAssertEqual(bo.nextAtMonoMs, 0)
        XCTAssertEqual(h.outboxFiles().count, 1)
    }
}

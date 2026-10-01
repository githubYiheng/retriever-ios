import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// configure 之前没有实例（ADR 0023；简报 §1 / §4.1–4.3 / §11 A–M、O）。全部走共享入口（`SharedClient` = 静态 `Retriever.*` 的实现），
/// 不碰进程级单例（它的 root 在真实的 Application Support 里、传输是真网络）。
final class PreconfigureTests: XCTestCase {
    func currentDir(_ sh: SharedHarness, process: String = "main") -> URL {
        sh.client.root.appendingPathComponent("proc-\(process)").appendingPathComponent(sh.client.writer.currentSessionId)
    }

    /// 非合成行（宿主写的）。
    func hostLines(_ dir: URL) -> [[String: Any]] {
        segmentLines(dir).filter { $0["synthetic"] as? Bool != true }
    }

    // MARK: A. 按本次 configure 判定

    func testA_PreconfigureLinesJudgedByThisConfigure() async throws {
        func run(_ edit: @escaping (inout Options) -> Void) async -> (SharedHarness, [[String: Any]], [Int64]) {
            let sh = SharedHarness()
            var ts: [Int64] = []
            for (lvl, m) in [(LogLevel.debug, "d"), (.info, "i"), (.warn, "w"), (.error, "e")] {
                ts.append(sh.clock.wallMs())
                sh.shared.log(lvl, m)
                sh.clock.advance(7)
            }
            XCTAssertNil(sh.shared.instanceForTesting, "configure 之前没有实例")
            XCTAssertEqual(sh.preFiles().count, 1)
            sh.configure(key: "", edit)
            await sh.settle()
            return (sh, hostLines(currentDir(sh)), ts)
        }
        // configure(INFO)：info 及以上有 oseq 且从 1 连续；ts 保持写入时刻
        let (sh, ls, ts) = await run { $0.uploadLevel = .info }
        XCTAssertEqual(ls.map { $0["msg"] as? String }, ["d", "i", "w", "e"])
        XCTAssertNil(ls[0]["oseq"])
        XCTAssertEqual(ls.dropFirst().map { int($0["oseq"]) }, [1, 2, 3])
        XCTAssertEqual(ls.map { int($0["seq"]) }, [1, 2, 3, 4])
        XCTAssertEqual(ls.map { int($0["ts"]) }, ts)
        XCTAssertEqual(sh.preFiles(), [], "提交 = unlink pre 文件")
        XCTAssertNil(sh.sessions().last?.meta["pre"], "提交后清掉 meta.pre")
        // configure(ERROR)：warn 无 oseq
        let (_, ls2, _) = await run { $0.uploadLevel = .error }
        XCTAssertEqual(ls2.map { $0["oseq"] == nil }, [true, true, true, false])
        XCTAssertEqual(int(ls2[3]["oseq"]), 1)
        // configure(localLevel = INFO)：debug 行不出现
        let (_, ls3, _) = await run { $0.localLevel = .info }
        XCTAssertEqual(ls3.map { $0["msg"] as? String }, ["i", "w", "e"])
        XCTAssertEqual(ls3.map { int($0["seq"]) }, [1, 2, 3], "过滤掉的行不占 seq")
    }

    /// configure 之前的入口：级别读默认、没有 install、flush 回 paused；适配器早过滤按全收。
    func testA_PreconfigureEntryPointsCreateNothing() async throws {
        let sh = SharedHarness()
        XCTAssertEqual(sh.shared.uploadLevel, .warn)
        XCTAssertEqual(sh.shared.localLevel, .debug)
        XCTAssertNil(sh.shared.installId)
        XCTAssertNil(sh.shared.supportCode)
        XCTAssertTrue(sh.shared.isEnabled)
        let r = await sh.shared.flush()
        XCTAssertEqual(r, .pending("paused"))
        sh.shared.log(.fatal, "fatal before configure")
        XCTAssertNil(sh.shared.instanceForTesting)
        XCTAssertEqual(FS.list(sh.defaultRoot), ["pre"], "只有 pre 目录：不建 install / 会话 / 出站箱")
        XCTAssertEqual(sh.transport.requests.count, 0)
        XCTAssertEqual(sh.platform.begunTokens, [])
        let recs = preRecords(sh.preDir.appendingPathComponent(sh.preFiles()[0]))
        XCTAssertEqual(recs.count, 2)
        XCTAssertTrue(recs[0].hasPrefix("{\"pre\":1,\"started_ms\":\(sh.clock.wallMs()),\"process\":\"main\",\"device\":{\"os\":\"macos\""))
        XCTAssertTrue(recs[1].hasPrefix("{\"r\":0,\"ts\":\(sh.clock.wallMs()),\"level\":\"fatal\",\"msg\":\"fatal before configure\""))
    }

    // MARK: B. redact

    func testB_PreconfigureLinesPassRedactOnAdoption() async throws {
        let sh = SharedHarness()
        let t0 = sh.clock.wallMs()
        sh.shared.log(.info, "card 4111 here")
        sh.shared.log(.info, "drop me")
        sh.shared.log(.warn, String(repeating: "长", count: 3000))          // 截断：truncated 标记要保留
        sh.shared.log(.warn, "plain", attrs: ["n": .int(9_007_199_254_740_993), "f": .number(1.5), "b": .bool(true)])
        let shared = sh.shared
        let seen = Box<[String]>()
        seen.set([])
        sh.configure(key: "") { o in
            o.redact = { l in
                seen.set((seen.value ?? []) + [l.tag ?? l.msg])
                shared.log(.error, "logged from redact")          // 重入：忽略，不死锁
                if l.msg == "drop me" { return nil }
                var x = l
                x.msg = x.msg.replacingOccurrences(of: "4111", with: "<card>")
                x.ts = -5                                          // 改 ts 无效
                return x
            }
        }
        await sh.settle()
        let ls = hostLines(currentDir(sh))
        XCTAssertEqual(ls.count, 3)
        XCTAssertEqual(ls[0]["msg"] as? String, "card <card> here")
        XCTAssertEqual(int(ls[0]["ts"]), t0)
        XCTAssertEqual(ls[1]["truncated"] as? Bool, true, "truncated 与原值取或")
        XCTAssertEqual((ls[2]["attrs"] as? [String: Any])?["n"] as? String, "9007199254740993")
        XCTAssertFalse(ls.contains { $0["msg"] as? String == "logged from redact" })
        XCTAssertEqual(ls.map { int($0["seq"]) }, [1, 2, 3])
    }

    /// 合成行不经 redact（收编中由 SDK 追加进 pre 文件的 `r` = 1 记录原样收编）；无钩子时行体字节不变。
    func testB_SyntheticNotRedactedAndBytesUnchangedWithoutHook() async throws {
        let sh = SharedHarness()
        sh.shared.log(.warn, "a \"quoted\" \\ line\nwith ctl \u{1}", tag: "t", attrs: ["k": .string("v"), "x": .number(0.1)])
        sh.shared.log(.info, "second")
        let pre = sh.preDir.appendingPathComponent(sh.preFiles()[0])
        let bodies = preRecords(pre).dropFirst().map { String($0.dropFirst("{\"r\":0,".count)) }
        sh.configure(key: "") { $0.uploadLevel = .info }
        await sh.settle()
        let dir = currentDir(sh)
        let raw = FS.list(dir).filter { Segments.parseName($0) != nil }.sorted().flatMap { n in
            (try! String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)).split(separator: "\n").dropFirst().map(String.init)
        }
        // 前缀 {"seq":N,"oseq":M, 之后与 pre 记录的行体逐字节相同
        let stripped = raw.map { l -> String in
            let r = l.range(of: "\"ts\":")!
            return String(l[r.lowerBound...])
        }
        XCTAssertEqual(stripped, bodies)

        // 合成行：收编中写的 rtv.reconfigure_ignored 进 pre 文件（r = 1），不过钩子
        let sh2 = SharedHarness()
        sh2.shared.log(.info, "x")
        let seen = Box<[String]>()
        seen.set([])
        sh2.configure(key: "") { o in
            o.redact = { l in seen.set((seen.value ?? []) + [l.tag ?? ""]); return l }
        }
        let release = await blockWork(sh2.client)
        sh2.configure(key: "") { $0.processName = "other" }        // 收编还没跑：合成行进 pre 文件
        release()
        await sh2.settle()
        let ls = segmentLines(currentDir(sh2))
        let ign = try XCTUnwrap(ls.first { $0["tag"] as? String == "rtv.reconfigure_ignored" })
        XCTAssertEqual(ign["synthetic"] as? Bool, true)
        XCTAssertFalse(seen.value!.contains("rtv.reconfigure_ignored"), "合成行不经 redact")
    }

    // MARK: C. 用户边界与封段期限

    func testC_PreconfigureSetUserBoundaries() async throws {
        let sh = SharedHarness()
        sh.shared.log(.warn, "a")
        sh.shared.setUser("u1")
        sh.shared.log(.warn, "b")
        sh.shared.setUser("u2")
        sh.shared.setUser("u2")
        sh.shared.log(.warn, "c")
        sh.configure(key: "")
        await sh.settle()
        sh.shared.log(.warn, "d")
        let dir = currentDir(sh)
        var byUser: [String] = []
        for n in FS.list(dir).filter({ Segments.parseName($0) != nil }).sorted() {
            let ls = (try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)).split(separator: "\n")
            let h = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ls[0].utf8)) as? [String: Any])
            let user = (h["user_id"] as? String) ?? "nil"
            for l in ls.dropFirst() {
                let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
                byUser.append("\(user):\(o["msg"] as? String ?? "")")
            }
        }
        XCTAssertEqual(byUser, ["nil:a", "u1:b", "u2:c", "u2:d"])
        XCTAssertEqual(sh.client.writer.currentUser, "u2")
    }

    /// configure 之前写 error：收编后在去抖时间内封段；fatal：立即封段。
    func testC_PreconfigureErrorDebouncedFatalImmediate() async throws {
        let sh = SharedHarness()
        sh.shared.log(.info, "ctx")
        sh.shared.log(.error, "boom")
        sh.configure(key: "")
        await sh.settle()
        XCTAssertEqual(sh.outboxFiles(), [], "去抖期内还没封")
        sh.clock.advance(Limits.errorDebounceMs)
        await sh.client.tickNow()
        let e = try XCTUnwrap(sh.envelopes().first)
        XCTAssertTrue(sh.outboxFiles()[0].hasPrefix("p0-"))
        XCTAssertEqual(lines(of: e).map { $0["msg"] as? String }, ["ctx", "boom"])

        let sh2 = SharedHarness()
        sh2.shared.log(.fatal, "dead")
        sh2.configure(key: "")
        await sh2.settle()
        XCTAssertEqual(sh2.outboxFiles().count, 1, "fatal：收编提交后立即封段物化")
        XCTAssertTrue(FS.exists(currentDir(sh2).appendingPathComponent("seg-000001.sealed")))
    }

    // MARK: F. configure 之前什么都不做

    func testF_NothingHappensBeforeConfigureThenConfiguredCapApplies() async throws {
        func layout(_ sh: SharedHarness) throws -> URL {
            let outbox = sh.defaultRoot.appendingPathComponent("outbox")
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            for i in 0..<21 {
                var r = [UInt8](repeating: 0, count: 1024 * 1024)
                arc4random_buf(&r, r.count)
                try Data(r).write(to: outbox.appendingPathComponent("p1-\(1_790_000_000_000 + i)-\(IDs.newV4()).gz"))
            }
            // 一个死掉的旧会话（有义务行、未收尾）
            let old = sh.defaultRoot.appendingPathComponent("proc-main/\(IDs.newV4())")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            let meta = SessionMeta(sessionId: old.lastPathComponent, sessionNo: 1, startedMs: 1, device: Device(os: "macos", osVersion: "1",
                                   model: "m", appVersion: "1", build: "1", locale: "x", sdk: "retriever-ios/0.2.0"), process: "main", installId: nil)
            try Data(meta.encode()).write(to: old.appendingPathComponent("meta.json"))
            try Data((String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode(), as: UTF8.self)
                      + "{\"seq\":1,\"oseq\":1,\"ts\":1,\"level\":\"warn\",\"msg\":\"old\"}\n").utf8)
                .write(to: old.appendingPathComponent("seg-000001.open"))
            return old
        }
        let sh = SharedHarness()
        let old = try layout(sh)
        let before = sh.outboxFiles()
        for i in 0..<50 { sh.shared.log(.error, "pre \(i)") }
        XCTAssertEqual(sh.outboxFiles(), before, "零驱逐")
        XCTAssertEqual(FS.list(old).sorted(), ["meta.json", "seg-000001.open"], "不恢复旧会话")
        XCTAssertFalse(FS.exists(sh.defaultRoot.appendingPathComponent("sessions.jsonl")))
        XCTAssertFalse(FS.exists(sh.defaultRoot.appendingPathComponent("install.json")))
        XCTAssertEqual(sh.transport.requests.count, 0, "零联网")
        XCTAssertEqual(sh.platform.begunTokens, [], "零后台作业")
        sh.configure(key: "") { $0.localCapBytes = 50 * 1024 * 1024 }
        await sh.settle()
        XCTAssertTrue(Set(before).isSubset(of: Set(sh.outboxFiles())), "按 50 MB：一个没驱逐")
        XCTAssertTrue(FS.exists(old.appendingPathComponent("seg-000001.sealed")), "configure 之后才恢复旧会话")

        // 对照：同样的布局按默认 20 MB 会驱逐（证明上面不是因为没算到）
        let sh2 = SharedHarness()
        _ = try layout(sh2)
        let before2 = sh2.outboxFiles()
        sh2.configure(key: "")
        await sh2.settle()
        XCTAssertLessThan(Set(before2).intersection(Set(sh2.outboxFiles())).count, before2.count)
    }

    // MARK: G. 计数与上报

    /// pre 文件 1 MB 上限：之后的行计数，收编后合成 warn `rtv.pre_init_dropped` 的四项正确；禁用期间不计；合成行不经 redact。
    func testG_PreFileCapCountsAndReports() async throws {
        let sh = SharedHarness()
        var counted: [(LogLevel, Int64)] = []
        for i in 0..<320 {
            let lvl: LogLevel = i % 7 == 0 ? .error : .info
            let before = sh.shared.droppedCountForTesting
            let ts = sh.clock.wallMs()
            sh.shared.log(lvl, String(repeating: "x", count: 4000) + " \(i)")
            if sh.shared.droppedCountForTesting > before { counted.append((lvl, ts)) }
            sh.clock.advance(3)
        }
        let size = try XCTUnwrap(FS.size(sh.preDir.appendingPathComponent(sh.preFiles()[0])))
        XCTAssertLessThanOrEqual(size, ClientConstants.preFileMaxBytes)
        XCTAssertGreaterThan(size, ClientConstants.preFileMaxBytes - 5000)
        XCTAssertGreaterThan(counted.count, 50)
        // 禁用期间不计
        sh.shared.setEnabled(false)
        sh.shared.log(.error, "disabled")
        XCTAssertEqual(sh.shared.droppedCountForTesting, Int64(counted.count))
        sh.shared.setEnabled(true)
        let seen = Box<[String]>()
        seen.set([])
        sh.configure(key: "") { o in o.redact = { l in seen.set((seen.value ?? []) + [l.tag ?? ""]); return l } }
        await sh.settle()
        let ls = segmentLines(currentDir(sh))
        let rep = try XCTUnwrap(ls.first { $0["tag"] as? String == "rtv.pre_init_dropped" })
        XCTAssertEqual(rep["msg"] as? String, "lines dropped before a session was available")
        XCTAssertEqual(rep["level"] as? String, "warn")
        XCTAssertEqual(rep["synthetic"] as? Bool, true)
        let a = try XCTUnwrap(rep["attrs"] as? [String: Any])
        XCTAssertEqual(int(a["count"]), Int64(counted.count))
        XCTAssertEqual(int(a["error_count"]), Int64(counted.filter { $0.0 == .error }.count))
        XCTAssertEqual(int(a["first_ts"]), counted.first!.1)
        XCTAssertEqual(int(a["last_ts"]), counted.last!.1)
        XCTAssertEqual(sh.shared.droppedCountForTesting, 0, "上报后清零")
        XCTAssertFalse(seen.value!.contains("rtv.pre_init_dropped"))
        XCTAssertEqual(ls.filter { $0["synthetic"] as? Bool != true }.count, 320 - counted.count)
    }

    /// 写失败（目录不可写）：不重试、不缓存，计数；configure 后上报。
    func testG_PreWriteFailureCounted() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.defaultRoot, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sh.defaultRoot.path, 0o500), 0)
        sh.shared.log(.warn, "w")
        sh.shared.log(.error, "e")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 2)
        XCTAssertEqual(chmod(sh.defaultRoot.path, 0o700), 0)
        sh.configure(key: "")
        await sh.settle()
        let rep = try XCTUnwrap(segmentLines(currentDir(sh)).first { $0["tag"] as? String == "rtv.pre_init_dropped" })
        XCTAssertEqual(int((rep["attrs"] as? [String: Any])?["count"]), 2)
        XCTAssertEqual(int((rep["attrs"] as? [String: Any])?["error_count"]), 1)
    }

    /// 孤儿 pre 文件 7 天删除（不属于活进程、收编不了：被别的进程目录里的会话认领）；计入本地总量（R-5）。
    func testG_StalePreFileDeletedAndCounted() async throws {
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.preDir, withIntermediateDirectories: true)
        func claimed(_ bytes: Int, ageDays: Int64) throws -> URL {
            let name = PreName.make()
            let url = sh.preDir.appendingPathComponent(name)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            FS.touch(url, wallMs: sh.clock.wallMs() - ageDays * 86_400_000)
            let d = sh.defaultRoot.appendingPathComponent("proc-ext/\(IDs.newV4())")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var m = SessionMeta(sessionId: d.lastPathComponent, sessionNo: 1, startedMs: 1, device: Device(os: "", osVersion: "", model: "",
                                appVersion: "", build: "", locale: "", sdk: ""), process: "ext", installId: nil)
            m.pre = name
            try Data(m.encode()).write(to: d.appendingPathComponent("meta.json"))
            return url
        }
        let stale = try claimed(10, ageDays: 8)
        let fresh = try claimed(1_500_000, ageDays: 0)
        // 出站箱 1 MB 的 p1：本地上限 2 MB，算上 1.5 MB 的 pre 文件才超
        let outbox = sh.defaultRoot.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var r = [UInt8](repeating: 0, count: 1024 * 1024)
        arc4random_buf(&r, r.count)
        let p1 = "p1-1790000000000-\(IDs.newV4()).gz"
        try Data(r).write(to: outbox.appendingPathComponent(p1))
        sh.configure(key: "") { $0.localCapBytes = 2 * 1024 * 1024 }
        await sh.settle()
        XCTAssertFalse(FS.exists(stale), "7 天以上、无活持有者：删")
        XCTAssertTrue(FS.exists(fresh), "新的、被认领：留着等认领它的进程重做")
        XCTAssertFalse(sh.outboxFiles().contains(p1), "pre 文件计入总量：超上限驱逐出站箱")
    }

    // MARK: H. 同意

    func testH_DisabledMarkerMeansZeroWritesBeforeConfigure() async throws {
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.base, withIntermediateDirectories: true)
        try Data().write(to: disabledMarker(sh.defaultRoot))
        XCTAssertFalse(sh.shared.isEnabled)
        sh.shared.log(.error, "x")
        sh.shared.setUser("u")
        XCTAssertFalse(FS.exists(sh.defaultRoot), "零写入")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 0, "禁用期间不计")
        sh.configure(key: "")
        await sh.settle()
        XCTAssertFalse(sh.client.isEnabled)
    }

    /// 标记判定未知（stat 出错）→ 按禁用：configure 之前不写不计；configure 时也禁用；之后 bootstrap 成功时重判。
    func testH_UnknownMarkerFailsClosedThenRejudged() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.base, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sh.base.path, 0o600), 0)          // 不可搜索：stat(<root>.disabled) 得 EACCES
        defer { chmod(sh.base.path, 0o700) }
        XCTAssertFalse(sh.shared.isEnabled)
        sh.shared.log(.error, "unknown state")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 0)
        sh.configure(key: "")
        let c = sh.client
        XCTAssertFalse(c.isEnabled, "未知按禁用")
        XCTAssertNil(c.installId, "root 也进不去：bootstrap 失败")
        XCTAssertEqual(chmod(sh.base.path, 0o700), 0)
        await c.tickNow()                                      // 调度唤醒：重试 bootstrap，成功后重判
        await c.settle()
        XCTAssertNotNil(c.installId)
        XCTAssertTrue(c.isEnabled, "bootstrap 成功后按标记（不存在）重判")
        c.log(.warn, "now written")
        XCTAssertTrue(segmentLines(currentDir(sh)).contains { $0["msg"] as? String == "now written" })
    }

    /// configure 之前 purgeLocal：pre 文件与 root 都清、计数清零、回调触发；之后的行进新的 pre 文件。
    func testH_PurgeBeforeConfigure() async throws {
        let sh = SharedHarness()
        sh.shared.log(.warn, "to purge")
        let first = sh.preFiles()
        XCTAssertEqual(first.count, 1)
        try FileManager.default.createDirectory(at: sh.defaultRoot.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        let done = Box<Bool>()
        sh.shared.purgeLocal { done.set(true) }
        await waitFor { done.value == true }
        XCTAssertEqual(done.value, true)
        XCTAssertFalse(FS.exists(sh.defaultRoot))
        XCTAssertEqual(purgeSiblings(sh.defaultRoot), [])
        sh.shared.log(.warn, "after purge")
        XCTAssertEqual(sh.preFiles().count, 1)
        XCTAssertNotEqual(sh.preFiles(), first)
        sh.configure(key: "")
        await sh.settle()
        XCTAssertEqual(hostLines(currentDir(sh)).map { $0["msg"] as? String }, ["after purge"])
    }

    // MARK: I. 实例身份只认首次 configure

    func testI_SecondConfigureIdentityIgnoredSameParamsNoRequest() async throws {
        let sh = SharedHarness()
        sh.transport.configBody = ["etag": "e"]
        sh.configure()
        await sh.settle()
        let c = sh.client
        let sid = c.writer.currentSessionId
        let n0 = sh.transport.configRequests.count
        XCTAssertGreaterThan(n0, 0)
        sh.configure()                                          // 同参数：只更新 redact
        await sh.settle()
        XCTAssertEqual(sh.transport.configRequests.count, n0, "同参数重复 configure：零请求")
        sh.configure { $0.processName = "renamed" }
        await sh.settle()
        XCTAssertTrue(sh.client === c)
        XCTAssertEqual(c.processName, "main")
        c.log(.warn, "still here")
        XCTAssertEqual(c.writer.currentSessionId, sid, "行继续进原会话")
        let ls = segmentLines(currentDir(sh))
        let ign = try XCTUnwrap(ls.first { $0["tag"] as? String == "rtv.reconfigure_ignored" })
        XCTAssertEqual((ign["attrs"] as? [String: Any])?["field"] as? String, "process_name")
        XCTAssertEqual(ign["msg"] as? String, "identity field change ignored after first configure")
        XCTAssertTrue(ls.contains { $0["msg"] as? String == "still here" })
        XCTAssertEqual(sh.transport.configRequests.count, n0, "只改了被忽略的字段：其余参数没变，不拉配置")
        XCTAssertFalse(FS.exists(sh.defaultRoot.appendingPathComponent("proc-renamed")))
    }

    // MARK: J. 多进程

    func testJ_LivePreFileOfAnotherProcessUntouched() async throws {
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.preDir, withIntermediateDirectories: true)
        let url = sh.preDir.appendingPathComponent(PreName.make())
        let content = Data("{\"pre\":1,\"started_ms\":1,\"process\":\"ext\",\"device\":{\"os\":\"\",\"os_version\":\"\",\"model\":\"\",\"app_version\":\"\",\"build\":\"\",\"locale\":\"\",\"sdk\":\"\"}}\n{\"r\":0,\"ts\":1,\"level\":\"warn\",\"msg\":\"alive\"}\n".utf8)
        try content.write(to: url)
        FS.touch(url, wallMs: sh.clock.wallMs() - 8 * 86_400_000)
        let fd = open(url.path, O_RDONLY)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "模拟另一个活进程持锁")
        sh.configure(key: "")
        await sh.settle()
        await sh.client.tickNow()
        XCTAssertTrue(FS.exists(url), "活进程的 pre 文件：不收编、不驱逐")
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(sh.sessions().count, 1, "没为它建会话")
        close(fd)
        // 那个进程死了：下一个用默认 root 的实例收编它
        sh.client.simulateCrash()
        let h = Harness(root: sh.defaultRoot, key: "")
        await h.settle()
        XCTAssertFalse(FS.exists(url))
        let adopted = try XCTUnwrap(SharedHarness(base: sh.base).sessions().first { $0.meta["process"] as? String == "ext" })
        XCTAssertEqual(segmentLines(sh.defaultRoot.appendingPathComponent("proc-main/\(adopted.sid)")).map { $0["msg"] as? String }, ["alive"])
    }

    // MARK: L. 并发

    func testL_ConcurrentLogAndConfigure() async throws {
        let sh = SharedHarness()
        let shared = sh.shared
        let threads = 8
        let per = 250
        DispatchQueue.concurrentPerform(iterations: threads + 1) { i in
            if i == threads {
                usleep(3000)
                var o = Options()
                o.uploadLevel = .info
                shared.configure(key: "", baseURL: SharedHarness.url, options: o)
            } else {
                for j in 0..<per { shared.log(j % 3 == 0 ? .warn : .info, "t\(i)-\(j)", tag: "L") }
            }
        }
        await sh.settle()
        let ls = segmentLines(currentDir(sh)).filter { $0["tag"] as? String == "L" }
        XCTAssertEqual(ls.count, threads * per, "行不丢")
        XCTAssertEqual(Set(ls.compactMap { $0["msg"] as? String }).count, threads * per, "不重")
        let all = segmentLines(currentDir(sh))
        XCTAssertEqual(all.map { int($0["seq"]) }, (1...Int64(all.count)).map { $0 }, "seq 无重无缺")
        let oseqs = all.compactMap { ($0["oseq"] as? NSNumber)?.int64Value }
        XCTAssertEqual(oseqs, (1...Int64(oseqs.count)).map { $0 }, "oseq 无重无缺")
        XCTAssertGreaterThanOrEqual(oseqs.count, threads * per)
        // 每个线程自己的行保持先后
        for i in 0..<threads {
            let mine = ls.compactMap { $0["msg"] as? String }.filter { $0.hasPrefix("t\(i)-") }
            XCTAssertEqual(mine, (0..<per).map { "t\(i)-\($0)" })
        }
    }

    // MARK: M. 没有会话

    /// bootstrap 失败（install.json 读不了）期间的 log()：计数；恢复后上报（修复前：静默丢）。
    func testM_NoSessionLinesCountedAndReported() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let sh = SharedHarness()
        try FileManager.default.createDirectory(at: sh.defaultRoot, withIntermediateDirectories: true)
        let inst = sh.defaultRoot.appendingPathComponent("install.json")
        try Data(InstallInfo(installId: IDs.newV4(), sessionCounter: 3, createdMs: 1).encode()).write(to: inst)
        XCTAssertEqual(chmod(inst.path, 0), 0)
        sh.configure(key: "")
        let c = sh.client
        XCTAssertNil(c.installId)
        let t0 = sh.clock.wallMs()
        c.log(.warn, "lost 1")
        sh.clock.advance(5)
        Retriever_logViaShared(sh, .error, "lost 2")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 2)
        XCTAssertEqual(chmod(inst.path, 0o600), 0)
        c.platformEvent(.protectedDataDidBecomeAvailable)
        await sh.settle()
        XCTAssertNotNil(c.installId)
        let rep = try XCTUnwrap(segmentLines(currentDir(sh)).first { $0["tag"] as? String == "rtv.pre_init_dropped" })
        let a = try XCTUnwrap(rep["attrs"] as? [String: Any])
        XCTAssertEqual(int(a["count"]), 2)
        XCTAssertEqual(int(a["error_count"]), 1)
        XCTAssertEqual(int(a["first_ts"]), t0)
        XCTAssertEqual(int(a["last_ts"]), t0 + 5)
    }

    /// meta.json 写不成 = bootstrap 失败（不允许「有会话、没 meta」）：不留会话目录，行计数；可写后重试成功并上报。
    func testM_MetaWriteFailureIsBootstrapFailure() async throws {
        let sh = SharedHarness()
        Faults.failMetaWrites(under: sh.defaultRoot)
        defer { Faults.clearMetaFaults(under: sh.defaultRoot) }
        sh.configure(key: "")
        let c = sh.client
        XCTAssertNil(c.installId)
        XCTAssertEqual(FS.list(sh.defaultRoot.appendingPathComponent("proc-main")), [], "没有「有会话、没 meta」")
        c.log(.warn, "no session")
        XCTAssertEqual(sh.shared.droppedCountForTesting, 1)
        Faults.clearMetaFaults(under: sh.defaultRoot)
        await c.tickNow()
        await c.settle()
        XCTAssertNotNil(c.installId)
        XCTAssertEqual(sh.sessions().count, 1)
        XCTAssertTrue(segmentLines(currentDir(sh)).contains { $0["tag"] as? String == "rtv.pre_init_dropped" })
    }

    // MARK: O. 不抛、不崩，flush 必回

    func testO_HostileInputsAndFlushAlwaysReturns() async throws {
        struct Weird: Error, CustomStringConvertible {
            var description: String { String(repeating: "\u{0}\u{FFFF}\"\\", count: 3000) }
        }
        let sh = SharedHarness()
        let attrs: [String: AttrValue] = ["nan": .number(.nan), "inf": .number(-.infinity), "big": .int(.max), "": .string(""),
                                          "ctx": .bool(true), "level": .string("fatal")]
        sh.shared.log(.error, "", tag: String(repeating: "t", count: 500), attrs: attrs, error: Weird())
        sh.shared.setUser(String(repeating: "\u{7}", count: 10))
        sh.shared.setUser("   ")
        sh.configure(key: "")
        await sh.settle()
        sh.shared.log(.fatal, "after", attrs: attrs, error: NSError(domain: "d", code: -1, userInfo: nil))
        await sh.settle()                                       // fatal 的封段（open → sealed 改名）在后台：等它落定再读
        XCTAssertNil(sh.client.writer.currentUser, "纯空白 / 纯控制字符 = nil")
        let ls = hostLines(currentDir(sh))
        XCTAssertEqual(ls.map { $0["msg"] as? String }, ["", "after"], "行照常落盘")
        XCTAssertEqual(ls.first?["truncated"] as? Bool, true)
        // flush 必回：传输挂起时窗口到点回 timeout；实例关闭后也回
        sh.transport.defaultReply = .hang
        sh.configure(key: SharedHarness.key)
        sh.client.setFlushWindowForTesting(300)
        let r = await sh.shared.flush()
        XCTAssertEqual(r, .pending("timeout"))
        sh.transport.cancelAll()
        sh.client.simulateCrash()
        let r2 = await sh.shared.flush()
        if case .pending = r2 {} else { XCTFail("\(r2)") }
    }

    // MARK: 提交点：unlink 失败时截成空文件（主代理审查第 1 条）

    /// pre 目录不可写（unlink 得 EACCES）：截成空文件即提交——不停在收编中、startup 照常跑（恢复旧会话），收编后的行直接进会话；
    /// 下次启动：空 pre 文件不被再次收编，meta.pre 指着空文件 = 已提交、按普通会话恢复。
    func testCommitByTruncateWhenUnlinkFails() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let sh = SharedHarness()
        // 一个死掉的旧会话：startup 跑了才会被恢复（封段、写终态）
        let old = sh.defaultRoot.appendingPathComponent("proc-main/\(IDs.newV4())")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let meta = SessionMeta(sessionId: old.lastPathComponent, sessionNo: 1, startedMs: 1, device: Device(os: "macos", osVersion: "1",
                               model: "m", appVersion: "1.2.3", build: "1", locale: "x", sdk: "s"), process: "main", installId: nil)
        try Data(meta.encode()).write(to: old.appendingPathComponent("meta.json"))
        try Data((String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 1).encode(), as: UTF8.self)
                  + "{\"seq\":1,\"oseq\":1,\"ts\":1,\"level\":\"warn\",\"msg\":\"old\"}\n").utf8)
            .write(to: old.appendingPathComponent("seg-000001.open"))
        for i in 0..<5 { sh.shared.log(.warn, "pre \(i)") }
        let pre = sh.preDir.appendingPathComponent(sh.preFiles()[0])
        XCTAssertEqual(chmod(sh.preDir.path, 0o500), 0)
        defer { chmod(sh.preDir.path, 0o700) }
        sh.configure(key: "")
        await sh.settle()
        let c = sh.client
        XCTAssertFalse(c.writer.isAdopting, "已提交：不停在收编中")
        XCTAssertEqual(FS.size(pre), 0, "unlink 失败 → 截成空文件")
        XCTAssertTrue(FS.exists(old.appendingPathComponent("seg-000001.sealed")), "startup 照常跑：旧会话已恢复")
        XCTAssertNil(sh.sessions().first { $0.sid == c.writer.currentSessionId }?.meta["pre"])
        c.log(.warn, "after commit")
        let dir = sh.defaultRoot.appendingPathComponent("proc-main/\(c.writer.currentSessionId)")
        XCTAssertEqual(hostLines(dir).map { $0["msg"] as? String }, ["pre 0", "pre 1", "pre 2", "pre 3", "pre 4", "after commit"])
        // 提交后、清 meta.pre 之前被杀的状态：meta.pre 指着空文件
        var m = try XCTUnwrap(SessionMeta.decode([UInt8](Data(contentsOf: dir.appendingPathComponent("meta.json")))))
        m.pre = pre.lastPathComponent
        try Data(m.encode()).write(to: dir.appendingPathComponent("meta.json"))
        let sid = c.writer.currentSessionId
        c.simulateCrash()
        let h = Harness(root: sh.defaultRoot, key: "")
        await h.settle()
        let after = segmentLines(dir)
        XCTAssertEqual(after.filter { $0["synthetic"] as? Bool != true }.map { $0["msg"] as? String },
                       ["pre 0", "pre 1", "pre 2", "pre 3", "pre 4", "after commit"], "空文件 = 已提交：不重做（行没被清掉重写）")
        XCTAssertEqual(after.filter { $0["tag"] as? String == "rtv.unclean_exit" }.count, 1, "按普通会话恢复")
        XCTAssertEqual(SharedHarness(base: sh.base).sessions().count, 3, "空 pre 文件没被当孤儿另建会话")
        XCTAssertTrue(h.readJSONL("sessions.jsonl").contains { $0["session_id"] as? String == sid })
    }

    /// 重做路径同口径：收编未提交的会话（meta.pre 指着非空、无活持有者的 pre 文件，段里已有一部分收编出的行）重做时 unlink 失败 →
    /// 截成空文件提交；重做保留前后台记录（fg → 合成 rtv.unclean_exit）；再启动不重复收编。
    func testRedoCommitsByTruncateAndIsNotRepeated() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let root = makeTempDir("rtv-redo")
        let a = Harness(root: root, key: "")
        await a.settle()
        a.client.simulateCrash()
        // 手工摆出「收编未提交」：pre 文件 3 行 + 会话 S（meta.pre、cursor fg、段里已写了第一行）
        let preDir = root.appendingPathComponent("pre")
        try FileManager.default.createDirectory(at: preDir, withIntermediateDirectories: true)
        let name = PreName.make()
        let pre = preDir.appendingPathComponent(name)
        let dev = Device(os: "macos", osVersion: "26.0", model: "Mac-test", appVersion: "1.2.3", build: "45", locale: "zh_CN", sdk: "s")
        var bytes = PreFile.header(startedMs: 100, process: "main", device: dev)
        for i in 0..<3 { bytes += PreFile.r0 + LineEncoder.encode(LogLine(ts: 100 + Int64(i), level: .warn, msg: "p\(i)")).body }
        try Data(bytes).write(to: pre)
        let sid = IDs.newV4()
        let dir = root.appendingPathComponent("proc-main/\(sid)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = SessionMeta(sessionId: sid, sessionNo: 9, startedMs: 100, device: dev, process: "main", installId: a.client.installId)
        meta.pre = name
        try Data(meta.encode()).write(to: dir.appendingPathComponent("meta.json"))
        try Data(Cursor(extractedThroughOseq: 0, ctxThroughSeq: 0, lastState: "fg", lastStateMs: 200).encode()).write(to: dir.appendingPathComponent("cursor.json"))
        try Data((String(decoding: SegmentHeader(segNo: 1, userId: nil, startedMs: 100).encode(), as: UTF8.self)
                  + "{\"seq\":1,\"oseq\":1,\"ts\":100,\"level\":\"warn\",\"msg\":\"p0\"}\n").utf8)
            .write(to: dir.appendingPathComponent("seg-000001.open"))
        XCTAssertEqual(chmod(preDir.path, 0o500), 0)
        defer { chmod(preDir.path, 0o700) }
        let h = Harness(root: root, key: "")
        await h.settle()
        XCTAssertEqual(FS.size(pre), 0, "重做后截空提交")
        let ls = segmentLines(dir)
        XCTAssertEqual(ls.filter { $0["synthetic"] as? Bool != true }.map { $0["msg"] as? String }, ["p0", "p1", "p2"], "不重不丢")
        XCTAssertEqual(ls.last?["tag"] as? String, "rtv.unclean_exit", "重做保留 last_state = fg")
        XCTAssertEqual(ls.compactMap { ($0["oseq"] as? NSNumber)?.int64Value }, [1, 2, 3, 4])
        XCTAssertNil(try XCTUnwrap(SessionMeta.decode([UInt8](Data(contentsOf: dir.appendingPathComponent("meta.json"))))).pre)
        h.client.simulateCrash()
        let h2 = Harness(root: root, key: "")
        await h2.settle()
        XCTAssertEqual(segmentLines(dir).count, 4, "不重复收编")
        XCTAssertEqual(Set(FS.list(root.appendingPathComponent("proc-main")).filter(IDs.isUuid)), [sid, h2.client.writer.currentSessionId],
                       "空 pre 文件没被当孤儿另建会话（零行的旧会话目录按既有规则删掉）")
    }
}

/// 走共享入口写一行（等价 `Retriever.log`）。
func Retriever_logViaShared(_ sh: SharedHarness, _ level: LogLevel, _ msg: String) {
    sh.shared.log(level, msg)
}

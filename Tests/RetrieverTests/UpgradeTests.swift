import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 从 0.2.0 / 0.1.4 原地升级到 0.3.0（主代理补充 U）：旧版本写下的全部本地状态照读；backoff / mapping / 配置缓存没有指纹字段
/// = 视为与当前 key 相同并补写，不复位；install_id 不变；旧会话照常恢复（fg 合成 rtv.unclean_exit）；出站箱旧批照常上传；oseq 连续。
/// 夹具按 git HEAD（0.2.0）/ e95a7a7（0.1.4）的编码器逐字节手写（字段顺序、键名照抄），不借用 0.3.0 的编码器。
final class UpgradeTests: XCTestCase {
    static let key = "lk_test_demo_abc_12345678"
    let iid = "3f2c9a4e-8b1d-4c7a-9e5f-0a1b2c3d4e5f"
    let sid = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    let otherSid = "1b4e28ba-2fa1-41d2-883f-0016d3cca427"
    let clock = FakeClock()
    /// 与 FakePlatform 的设备、0.3.0 sdk 相同：映射摘要不因设备变化而失效（只测指纹规则）。
    var deviceJSON: String {
        "{\"os\":\"macos\",\"os_version\":\"26.0\",\"model\":\"Mac-test\",\"app_version\":\"1.2.3\",\"build\":\"45\",\"locale\":\"zh_CN\",\"sdk\":\"retriever-ios/\(RetrieverVersion.current)\"}"
    }

    enum Pause { case auth, backoff, none }

    /// 旧版本的 root。`v014`：meta 没有 install_id、没有禁用标记 / 清空残留（0.1.4 没有这两样）。
    func legacyRoot(v014: Bool, pause: Pause, disabled: Bool) throws -> URL {
        let root = makeTempDir("rtv-up").appendingPathComponent("r")
        let fm = FileManager.default
        let dir = root.appendingPathComponent("proc-main/\(sid)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        let now = clock.wallMs()
        func w(_ rel: String, _ s: String) throws { try Data(s.utf8).write(to: root.appendingPathComponent(rel)) }
        try w("install.json", "{\"install_id\":\"\(iid)\",\"session_counter\":2,\"created_ms\":\(now - 86_400_000)}")
        try w("proc-main/\(sid)/meta.json",
              "{\"session_id\":\"\(sid)\",\"session_no\":2,\"started_ms\":\(now - 600_000),\"device\":\(deviceJSON),\"process\":\"main\""
              + (v014 ? "" : ",\"install_id\":\"\(iid)\"") + "}")
        try w("proc-main/\(sid)/cursor.json",
              "{\"extracted_through_oseq\":2,\"ctx_through_seq\":0,\"last_state\":\"fg\",\"last_state_ms\":\(now - 1000)}")
        // 已封段：oseq 1–2 已物化进出站箱；未封段：oseq 3（warn）+ 两行 info
        try w("proc-main/\(sid)/seg-000001.sealed",
              "{\"v\":1,\"seg_no\":1,\"user_id\":null,\"started_ms\":\(now - 600_000)}\n"
              + "{\"seq\":1,\"oseq\":1,\"ts\":\(now - 500_000),\"level\":\"warn\",\"msg\":\"w1\"}\n"
              + "{\"seq\":2,\"oseq\":2,\"ts\":\(now - 400_000),\"level\":\"error\",\"msg\":\"e2\"}\n")
        try w("proc-main/\(sid)/seg-000002.open",
              "{\"v\":1,\"seg_no\":2,\"user_id\":null,\"started_ms\":\(now - 300_000)}\n"
              + "{\"seq\":3,\"oseq\":3,\"ts\":\(now - 3000),\"level\":\"warn\",\"msg\":\"w3\"}\n"
              + "{\"seq\":4,\"ts\":\(now - 2000),\"level\":\"info\",\"msg\":\"i4\"}\n"
              + "{\"seq\":5,\"ts\":\(now - 1500),\"level\":\"info\",\"msg\":\"i5\",\"attrs\":{\"ctx\":true,\"level\":\"error\"}}\n")
        // 出站箱：oseq 1–2 的 p0 批 + 一个隔离批（信封格式未变）
        let bid = IDs.batchId(installId: iid, sessionId: sid, kind: .primary, n: 1)!
        let env = "{\"v\":1,\"kind\":\"primary\",\"batch_id\":\"\(bid)\",\"created_ms\":\(now - 390_000),\"day\":\"\(Day.fromMs(now - 500_000))\","
            + "\"install_id\":\"\(iid)\",\"session_id\":\"\(sid)\",\"session_no\":2,\"process\":\"main\",\"user_id\":null,\"device\":\(deviceJSON),"
            + "\"seq_from\":1,\"seq_to\":2,\"oseq_from\":1,\"oseq_to\":2,\"ctx_truncated\":0,\"lines\":["
            + "{\"seq\":1,\"oseq\":1,\"ts\":\(now - 500_000),\"level\":\"warn\",\"msg\":\"w1\"},"
            + "{\"seq\":2,\"oseq\":2,\"ts\":\(now - 400_000),\"level\":\"error\",\"msg\":\"e2\"}]}"
        try Data(Gzip.compress(Array(env.utf8))!).write(to: root.appendingPathComponent("outbox/p0-\(now - 390_000)-\(bid).gz"))
        let qbid = IDs.batchId(installId: iid, sessionId: otherSid, kind: .primary, n: 1)!
        let qenv = env.replacingOccurrences(of: bid, with: qbid).replacingOccurrences(of: sid, with: otherSid)
        try Data(Gzip.compress(Array(qenv.utf8))!).write(to: root.appendingPathComponent("outbox/q-\(now - 390_000)-\(qbid).gz"))
        try w("drops.jsonl", "{\"session_id\":\"\(otherSid)\",\"oseq_from\":5,\"oseq_to\":6,\"n\":2,\"reason\":\"buffer_overflow\",\"at_ms\":1,\"last_ack_age_ms\":-1}\n")
        try w("sessions.jsonl", "{\"session_id\":\"\(otherSid)\",\"session_no\":1,\"started_ms\":1,\"ended_ms\":2,\"last_seq\":9,\"last_oseq\":6,\"exit\":\"clean_bg\"}\n")
        try w("config.json", "{\"fetched_ms\":\(now - 60_000),\"config\":{\"etag\":\"e-old\",\"ttl_s\":1800,\"upload_enabled\":true,\"upload_level\":\"info\",\"local_level\":\"debug\",\"context_lines\":200,\"context_bytes\":131072,\"flush_interval_s\":300,\"local_cap_bytes\":20971520,\"full_dump\":false,\"full_dump_ttl_s\":0,\"daily_batch_cap\":0}}")
        let digest = Engine.digest(Device.decode(try JSONSerialization.jsonObject(with: Data(deviceJSON.utf8)))!)
        try w("mapping.json", "{\"user_id\":null,\"device_digest\":\"\(digest)\",\"acked_ms\":\(now - 3_600_000)}")
        switch pause {
        case .auth:
            try w("backoff.json", "{\"attempt\":0,\"next_at_wall_ms\":0,\"next_at_mono_ms\":0,\"paused_until_ms\":\(now + 3_000_000),\"paused_categories\":[\"all\"],\"reason\":\"auth:3600000\",\"last_ack_ms\":\(now - 3_600_000)}")
        case .backoff:
            try w("backoff.json", "{\"attempt\":3,\"next_at_wall_ms\":\(now + 8000),\"next_at_mono_ms\":123,\"paused_until_ms\":0,\"paused_categories\":[],\"reason\":\"http_503\",\"last_ack_ms\":\(now - 3_600_000)}")
        case .none:
            break
        }
        if !v014 {
            if disabled { try Data().write(to: Engine.sibling(of: root, suffix: ".disabled")) }
            let left = Engine.sibling(of: root, suffix: ".purge-" + IDs.newV4())
            try fm.createDirectory(at: left.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        }
        return root
    }

    func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// 0.2.0：鉴权暂停中 + 映射已确认 + 配置缓存（无 from_host）+ 标记不在。
    func testU_From020_AuthPausedStateKeptAndBackfilled() async throws {
        let root = try legacyRoot(v014: false, pause: .auth, disabled: false)
        let h = Harness(root: root, key: UpgradeTests.key, clock: clock)
        await h.settle()
        let fp = ConfigRules.keyFingerprint(UpgradeTests.key)
        XCTAssertEqual(fp.count, 16)
        XCTAssertEqual(h.client.installId, iid, "install_id 不变")
        XCTAssertEqual(h.client.supportCode, String(iid.prefix(8)) + "-3", "会话计数续上")
        // backoff：鉴权暂停沿用（没被指纹规则复位），指纹补写
        let bo = try json(root.appendingPathComponent("backoff.json"))
        XCTAssertEqual(bo["reason"] as? String, "auth:3600000")
        XCTAssertEqual(bo["key_fp"] as? String, fp)
        XCTAssertEqual(bo["base_url"] as? String, "https://logs-test.invalid")
        XCTAssertEqual(h.transport.batchRequests.count, 0, "暂停中：不上传")
        XCTAssertEqual(h.client.debugLastStopReason, "paused")
        // mapping：已确认沿用并补写指纹；新批不重发映射
        let mp = try json(root.appendingPathComponent("mapping.json"))
        XCTAssertEqual(mp["key_fp"] as? String, fp)
        let mapped = await h.work { $0.mapping != nil }
        XCTAssertTrue(mapped)
        // 配置缓存：照用（无 from_host = 空集 = 旧语义），不按身份过期；指纹补写
        let cache = await h.work { $0.configCache }
        XCTAssertEqual(cache?.identityStale, false)
        XCTAssertEqual(cache?.config.etag, "e-old")
        XCTAssertEqual(h.client.effectiveLevels.upload, .info, "缓存值照旧生效")
        let cf = try json(root.appendingPathComponent("config.json"))
        XCTAssertEqual(cf["key_fp"] as? String, fp)
        XCTAssertEqual(cf["from_host"] as? [String], [])
        // 旧会话：未封段恢复、fg → 合成 rtv.unclean_exit（按位置判定，attrs 里的 ctx / level 不干扰）、oseq 连续
        let dir = root.appendingPathComponent("proc-main/\(sid)")
        XCTAssertTrue(FS.list(dir).filter { $0.hasPrefix("seg-") }.allSatisfy { $0.hasSuffix(".sealed") })
        let ls = segmentLines(dir)
        XCTAssertEqual(ls.map { int($0["seq"]) }, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ls.last?["tag"] as? String, "rtv.unclean_exit")
        XCTAssertEqual(int(ls.last?["oseq"]), 4)
        let envs = h.envelopes().map(\.1).filter { $0["session_id"] as? String == sid }
        let covered = envs.flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, [1, 2, 3, 4], "旧批 1–2 + 恢复出的 3–4，首尾相接")
        XCTAssertTrue(h.outboxFiles().contains { $0.hasPrefix("q-") }, "隔离批照读、留着")
        XCTAssertEqual(purgeSiblings(root), [], "0.2.0 的清空残留照清")
        let closed = h.readJSONL("sessions.jsonl").compactMap { $0["session_id"] as? String }
        XCTAssertEqual(Set(closed), [otherSid, sid], "旧终态照读、新终态追加")
        XCTAssertEqual(h.readJSONL("drops.jsonl").count, 1)
        // 暂停到期后：旧批照常上传，请求头 install = 旧 install
        h.transport.configBody = nil
        await h.tick(advance: 3_100_000)
        for _ in 0..<6 where !h.outboxFiles().filter({ !$0.hasPrefix("q-") }).isEmpty { await h.tick(advance: Limits.minRequestSpacingMs) }
        XCTAssertEqual(h.outboxFiles().filter { !$0.hasPrefix("q-") }, [])
        XCTAssertTrue(h.transport.batchRequests.allSatisfy { $0.headers["X-Rtv-Install"] == iid })
        let sent = h.transport.batchRequests.compactMap { decodeEnvelope($0.body ?? Data()) }
        XCTAssertFalse(sent.contains { $0["mapping"] != nil && $0["session_id"] as? String == sid }, "映射已确认：不重发")
    }

    /// 0.2.0：普通退避中 + 禁用标记在：照旧禁用（不写、不合成）；退避沿用并补指纹；重新启用后旧批照常上传、oseq 连续。
    func testU_From020_BackoffAndDisabledKept() async throws {
        let root = try legacyRoot(v014: false, pause: .backoff, disabled: true)
        let h = Harness(root: root, key: UpgradeTests.key, clock: clock)
        await h.settle()
        XCTAssertEqual(h.client.installId, iid)
        XCTAssertFalse(h.client.isEnabled, "禁用标记照读")
        let bo = try json(root.appendingPathComponent("backoff.json"))
        XCTAssertEqual(int(bo["attempt"]), 3, "退避沿用")
        XCTAssertEqual(bo["key_fp"] as? String, ConfigRules.keyFingerprint(UpgradeTests.key))
        let ls = segmentLines(root.appendingPathComponent("proc-main/\(sid)"))
        XCTAssertEqual(ls.count, 5, "禁用：恢复不合成行")
        XCTAssertEqual(h.transport.batchRequests.count, 0)
        h.client.setEnabled(true)
        await h.settle()
        for _ in 0..<8 where !h.outboxFiles().filter({ !$0.hasPrefix("q-") }).isEmpty { await h.tick(advance: 10_000) }
        XCTAssertEqual(h.outboxFiles().filter { !$0.hasPrefix("q-") }, [])
        let sent = h.transport.batchRequests.compactMap { decodeEnvelope($0.body ?? Data()) }.filter { $0["session_id"] as? String == sid }
        let covered = sent.flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, [1, 2, 3])
    }

    /// 0.1.4：meta 没有 install_id、没有禁用标记 / 清空残留；没有暂停。install 不变、旧会话恢复、旧批上传。
    func testU_From014Layout() async throws {
        let root = try legacyRoot(v014: true, pause: .none, disabled: false)
        let h = Harness(root: root, key: UpgradeTests.key, clock: clock)
        await h.settle()
        XCTAssertEqual(h.client.installId, iid)
        XCTAssertTrue(h.client.isEnabled)
        XCTAssertNotEqual(h.client.debugLastStopReason, "paused")
        let ls = segmentLines(root.appendingPathComponent("proc-main/\(sid)"))
        XCTAssertEqual(ls.last?["tag"] as? String, "rtv.unclean_exit")
        for _ in 0..<6 where !h.outboxFiles().filter({ !$0.hasPrefix("q-") }).isEmpty { await h.tick(advance: Limits.minRequestSpacingMs) }
        XCTAssertEqual(h.outboxFiles().filter { !$0.hasPrefix("q-") }, [])
        let sent = h.transport.batchRequests.compactMap { decodeEnvelope($0.body ?? Data()) }.filter { $0["session_id"] as? String == sid }
        let covered = sent.flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }.sorted()
        XCTAssertEqual(covered, [1, 2, 3, 4])
        XCTAssertTrue(h.transport.batchRequests.allSatisfy { $0.headers["X-Rtv-Install"] == iid })
        // 新会话的 meta 带 install_id（0.2.0 起）、不带 pre
        let cur = try json(root.appendingPathComponent("proc-main/\(h.client.writer.currentSessionId)/meta.json"))
        XCTAssertEqual(cur["install_id"] as? String, iid)
        XCTAssertNil(cur["pre"])
    }

    /// 文件里**有**指纹且与当前不符（真的换了 key）才复位：鉴权暂停清掉、映射未确认、配置缓存按身份过期（ADR 0024 决定 7）。
    func testU_FingerprintMismatchStillResets() async throws {
        let root = try legacyRoot(v014: false, pause: .auth, disabled: false)
        let a = Harness(root: root, key: UpgradeTests.key, clock: clock)
        await a.settle()
        a.client.simulateCrash()
        let b = Harness(root: root, key: "lk_test_demo_other_87654321", clock: clock)
        await b.settle()
        let bo = try json(root.appendingPathComponent("backoff.json"))
        XCTAssertEqual(bo["reason"] as? String, "", "换 key：鉴权暂停清掉")
        XCTAssertEqual(bo["key_fp"] as? String, ConfigRules.keyFingerprint("lk_test_demo_other_87654321"))
        XCTAssertGreaterThan(b.transport.batchRequests.count, 0, "立即可传")
        let mapped = await b.work { $0.mapping != nil }
        XCTAssertFalse(mapped, "映射标为未确认")
    }

    /// 真 0.2.0 写出的 root（用 git HEAD 的 RetrieverKillHelper 生成，见实现报告）：设了 `RTV_REAL_V020_ROOT` 才跑。
    /// 断言：install 不变、全部旧会话恢复（段全封、终态写出）、出站箱覆盖每个旧会话的全部义务行、服务端校验器通过。
    func testU_RealV020LayoutIfProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["RTV_REAL_V020_ROOT"] else { throw XCTSkip("RTV_REAL_V020_ROOT 未设") }
        let root = URL(fileURLWithPath: path)
        let before = try json(root.appendingPathComponent("install.json"))
        let olds = FS.list(root.appendingPathComponent("proc-main")).filter(IDs.isUuid)
        let h = Harness(root: root, key: "")
        await h.settle()
        XCTAssertEqual(h.client.installId, before["install_id"] as? String)
        let closed = Set(h.readJSONL("sessions.jsonl").compactMap { $0["session_id"] as? String })
        for sid in olds {
            let dir = root.appendingPathComponent("proc-main/\(sid)")
            guard FS.exists(dir) else { continue }
            XCTAssertTrue(FS.list(dir).filter { $0.hasPrefix("seg-") }.allSatisfy { $0.hasSuffix(".sealed") }, sid)
            XCTAssertTrue(closed.contains(sid), sid)
            let maxO = segmentLines(dir).compactMap { ($0["oseq"] as? NSNumber)?.int64Value }.max() ?? 0
            let tombs = h.readJSONL("drops.jsonl").filter { $0["session_id"] as? String == sid }
                .flatMap { int($0["oseq_from"])...int($0["oseq_to"]) }
            let covered = h.envelopes().map(\.1).filter { $0["session_id"] as? String == sid }
                .flatMap { lines(of: $0).filter { $0["ctx"] == nil }.compactMap { ($0["oseq"] as? NSNumber)?.int64Value } }
            XCTAssertEqual(Set(covered + tombs), Set(maxO > 0 ? Array(1...maxO) : []), "\(sid)：义务行全进批（或有墓碑）")
        }
        let results = try runValidator(h.envelopes().map(\.1))
        for r in results { XCTAssertEqual(r["ok"] as? Bool, true, "\(r)") }
    }
}

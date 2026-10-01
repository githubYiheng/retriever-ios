import Foundation
import OSLog
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 配置诊断（ADR 0025；简报 §13 V1–V9）。除 V1 外都走静态入口（共享入口 `SharedClient`）；出口换成测试 sink 断言。
final class ConfigDiagnosticsTests: XCTestCase {
    /// golden `valid[]` 里的两把合法 key。
    // golden/apikey.json 里的假 key；拆开写，免得发布脚本的「真 key 形状」扫描把测试向量当成泄露
    static let testKey = "lk_test_my_app-2_" + "ffffffffffffffffffffffffffffffff" + "_0456af9e"
    static let liveKey = "lk_live_bible-bff_" + "0123456789abcdef0123456789abcdef" + "_86381e7d"
    static let local = URL(string: "http://127.0.0.1:8787")!
    static let production = URL(string: "https://logs.revdog.org")!

    /// sink 收到的 (code, message)。
    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(code: String, message: String)] = []
        func add(_ code: String, _ message: String) { lock.withLock { items.append((code, message)) } }
        var all: [(code: String, message: String)] { lock.withLock { items } }
        var codes: [String] { all.map(\.code) }
        func messages(_ code: String) -> [String] { all.filter { $0.code == code }.map(\.message) }
    }

    /// 清空去重集合、把出口换成记录用的 sink（tearDown 复位）。
    func capture() -> Captured {
        let c = Captured()
        ConfigDiagnostics.resetForTesting()
        ConfigDiagnostics.setSinkForTesting { code, message in c.add(code, message) }
        return c
    }

    override func tearDown() {
        ConfigDiagnostics.resetForTesting()
        super.tearDown()
    }

    /// 封当前段并按正常路径排空（封段是排空触发点之一）。
    func sealAndDrain(_ sh: SharedHarness) async {
        let c = sh.client
        c.writer.rotate(.timer)
        await c.onWork { c.afterSeal() }
        await sh.settle()
    }

    /// 消息绝不含 key 的任何部分（整串、`lk_` 前缀、app、random、crc；env 词 test / live 本来就在消息里，不算）。
    func assertNoKeyLeak(_ cap: Captured, _ keys: [String], file: StaticString = #filePath, line: UInt = #line) {
        let parts = keys.flatMap { k -> [String] in
            guard k.count >= 52 else { return [k] }
            return [k, String(k.dropFirst(8).dropLast(42)), String(k.suffix(41).prefix(32)), String(k.suffix(8))]
        } + ["lk_"]
        for (code, m) in cap.all {
            for p in parts where m.contains(p) { XCTFail("\(code) 的消息含 key 片段 \(p)：\(m)", file: file, line: line) }
        }
    }

    // MARK: V1. golden 回放（纯函数）

    func testV1_GoldenApiKey() throws {
        let g = try Repo.golden("apikey.json")
        let crcs = try XCTUnwrap(g["crc32"] as? [[String: Any]])
        XCTAssertGreaterThan(crcs.count, 0)
        for v in crcs {
            let text = try XCTUnwrap(v["text"] as? String)
            XCTAssertEqual(ConfigCheck.crc32Hex(Array(text.utf8)), v["expect"] as? String, text)
        }
        let valid = try XCTUnwrap(g["valid"] as? [[String: Any]])
        XCTAssertGreaterThan(valid.count, 0)
        for v in valid {
            let name = "\(v["name"] ?? "")"
            let key = try XCTUnwrap(v["key"] as? String)
            XCTAssertEqual(ConfigCheck.crc32Hex(Array(try XCTUnwrap(v["crc_input"] as? String).utf8)), v["crc"] as? String, name)
            XCTAssertEqual(ConfigCheck.keyEnv(key), v["env"] as? String, name)
            XCTAssertEqual(ConfigCheck.check(rawKey: key, key: key, baseURL: Self.local), [], name)
        }
        let invalid = try XCTUnwrap(g["invalid"] as? [[String: Any]])
        XCTAssertGreaterThan(invalid.count, 0)
        for v in invalid {
            let name = "\(v["name"] ?? "")"
            let key = try XCTUnwrap(v["key"] as? String)
            XCTAssertNil(ConfigCheck.keyEnv(key), name)
            // 空串按第 1 条判 no_key（不再判 2–4）；其余（尾随换行 / 前导空格这里不经修剪）判 key_malformed
            XCTAssertEqual(ConfigCheck.check(rawKey: key, key: key, baseURL: Self.local), key.isEmpty ? [.noKey] : [.keyMalformed], name)
        }
    }

    // MARK: V2. 修剪

    func testV2_KeyTrimmedEverywhereAndReportedOnce() async throws {
        let cap = capture()
        let sh = SharedHarness()
        let raw = " " + Self.testKey + "\n"
        sh.configure(key: raw)
        await sh.settle()
        XCTAssertEqual(cap.codes, ["key_trimmed"])
        XCTAssertEqual(cap.all.first?.message, "key had leading or trailing whitespace; it was trimmed")
        let c = sh.client
        let (key, fp) = await c.onWork { (c.engine.key, c.engine.keyFp) }
        XCTAssertEqual(key, Self.testKey)
        XCTAssertEqual(fp, ConfigRules.keyFingerprint(Self.testKey), "指纹用修剪后的值")
        sh.shared.log(.warn, "w")
        let r = await sh.shared.flush()
        XCTAssertEqual(r, .stored, "上传成功")
        XCTAssertEqual(sh.transport.batchRequests.last?.headers["Authorization"], "Bearer \(Self.testKey)")
        XCTAssertEqual(sh.transport.configRequests.last?.headers["Authorization"], "Bearer \(Self.testKey)")
        // 同参数判定也用修剪后的值：原值、修剪后的值再 configure 都是同参数（零请求），且不重复出
        await sh.settle()
        let n = sh.transport.requests.count
        sh.configure(key: raw)
        sh.configure(key: Self.testKey)
        await sh.settle()
        XCTAssertEqual(sh.transport.requests.count, n, "同参数：零请求")
        XCTAssertEqual(cap.codes, ["key_trimmed"])
        assertNoKeyLeak(cap, [Self.testKey])
        // 修剪规则（纯函数）：码点 ≤ 0x20、0x7F–0x9F、Unicode White_Space；只动首尾
        XCTAssertEqual(ConfigCheck.trim(" \t\r\nk\u{0}"), "k")
        XCTAssertEqual(ConfigCheck.trim("\u{7F}\u{85}\u{9F}k\u{A0}\u{2028}\u{3000}"), "k")
        XCTAssertEqual(ConfigCheck.trim("a b\nc"), "a b\nc")
        XCTAssertEqual(ConfigCheck.trim("\u{200B}k"), "\u{200B}k", "零宽空格不是 White_Space：不动")
        XCTAssertEqual(ConfigCheck.trim(" \n\t"), "")
        XCTAssertEqual(ConfigCheck.check(rawKey: "\u{3000}" + Self.testKey, key: Self.testKey, baseURL: Self.local), [.keyTrimmed])
    }

    // MARK: V3. 畸形 key

    func testV3_MalformedKeyReportedOnceRequestStillSent() async throws {
        let cap = capture()
        let sh = SharedHarness()
        let bad = "lk_test_my_app-2_" + "ffffffffffffffffffffffffffffffff" + "_0456af9f"     // crc 末位错
        sh.transport.setScript([.status(401, ["reason": "key_invalid"], [:])])
        sh.configure(key: bad)
        await sh.settle()
        XCTAssertEqual(cap.codes, ["key_malformed"])
        XCTAssertEqual(cap.all.first?.message,
                       "key is not a valid Retriever key (format or checksum mismatch); the server will reject it")
        sh.configure(key: bad)
        XCTAssertEqual(cap.codes, ["key_malformed"], "同参数再 configure 不重复出")
        sh.shared.log(.warn, "w")
        await sealAndDrain(sh)
        XCTAssertEqual(sh.transport.batchRequests.count, 1, "请求照发")
        XCTAssertEqual(sh.transport.batchRequests.first?.headers["Authorization"], "Bearer \(bad)")
        XCTAssertEqual(cap.codes, ["key_malformed", "key_rejected"])
        XCTAssertEqual(cap.messages("key_rejected"),
                       ["server rejected the key (HTTP 401, reason=key_invalid); uploads paused for 60 min; logs are kept locally"])
        assertNoKeyLeak(cap, [bad])
    }

    // MARK: V4. 空 key

    func testV4_EmptyKeyNoKeyAndZeroNetwork() async throws {
        let cap = capture()
        let sh = SharedHarness()
        sh.configure(key: "")
        sh.shared.log(.error, "e")
        _ = await sh.shared.flush()
        await sh.settle()
        XCTAssertEqual(cap.codes, ["no_key"])
        XCTAssertEqual(cap.all.first?.message, "no key configured; logs are written locally and never uploaded")
        XCTAssertEqual(sh.transport.requests.count, 0, "零联网")
        // 纯空白 = 修剪后为空：只出 no_key（不再判 2–4，不出 key_trimmed）
        let sh2 = SharedHarness()
        sh2.shared.configure(key: " \n\t", baseURL: Self.local, options: Options())
        sh2.shared.log(.error, "e")
        _ = await sh2.shared.flush()
        await sh2.settle()
        XCTAssertEqual(cap.codes, ["no_key", "no_key"])
        XCTAssertEqual(sh2.transport.requests.count, 0, "零联网")
        let key = await sh2.client.onWork { [c = sh2.client] in c.engine.key }
        XCTAssertEqual(key, "")
    }

    // MARK: V5. key 环境与端点不符

    func testV5_KeyEnvMismatchBothDirections() async throws {
        let cap = capture()
        let sh = SharedHarness()
        let mismatch = "key environment does not match the endpoint (test key with production endpoint, or live key with staging endpoint); the server will reject it"
        sh.shared.configure(key: Self.testKey, baseURL: Self.production, options: Options())
        XCTAssertEqual(cap.codes, ["key_env_mismatch"])
        sh.shared.configure(key: Self.liveKey, baseURL: URL(string: "https://LOGS-STAGING.revdog.org/")!, options: Options())
        XCTAssertEqual(cap.codes, ["key_env_mismatch", "key_env_mismatch"], "主机按小写比")
        XCTAssertEqual(cap.messages("key_env_mismatch"), [mismatch, mismatch])
        // 对得上的组合、自定义主机都不出
        sh.shared.configure(key: Self.liveKey, baseURL: Self.production, options: Options())
        sh.shared.configure(key: Self.testKey, baseURL: URL(string: "https://logs-staging.revdog.org")!, options: Options())
        sh.shared.configure(key: Self.liveKey, baseURL: Self.local, options: Options())
        sh.shared.configure(key: Self.testKey, baseURL: Self.local, options: Options())
        await sh.settle()
        XCTAssertEqual(cap.codes, ["key_env_mismatch", "key_env_mismatch"])
        assertNoKeyLeak(cap, [Self.testKey, Self.liveKey])
    }

    // MARK: V6. baseURL 不是 http(s)

    func testV6_BaseURLInvalid() async throws {
        let cap = capture()
        let sh = SharedHarness()
        let invalid = "baseUrl is not a valid http(s) URL; uploads will fail"
        let noScheme = try XCTUnwrap(URL(string: "logs.revdog.org"))
        sh.shared.configure(key: Self.testKey, baseURL: noScheme, options: Options())
        XCTAssertEqual(cap.codes, ["base_url_invalid"], "缺 scheme：没有主机，也不判环境")
        sh.shared.configure(key: Self.testKey, baseURL: noScheme, options: Options())
        XCTAssertEqual(cap.codes, ["base_url_invalid"], "同参数不重复")
        sh.shared.configure(key: Self.testKey, baseURL: try XCTUnwrap(URL(string: "ftp://x")), options: Options())
        XCTAssertEqual(cap.messages("base_url_invalid"), [invalid, invalid])
        sh.shared.configure(key: Self.testKey, baseURL: Self.local, options: Options())
        await sh.settle()
        XCTAssertEqual(cap.codes, ["base_url_invalid", "base_url_invalid"])
        // 纯函数：scheme 不分大小写、主机非空
        XCTAssertTrue(ConfigCheck.isHTTPURL(try XCTUnwrap(URL(string: "HTTPS://logs.revdog.org"))))
        XCTAssertTrue(ConfigCheck.isHTTPURL(Self.local))
        XCTAssertFalse(ConfigCheck.isHTTPURL(try XCTUnwrap(URL(string: "file:///tmp/x"))))
        XCTAssertFalse(ConfigCheck.isHTTPURL(try XCTUnwrap(URL(string: "https:///v1"))))
    }

    // MARK: V7. 服务端拒绝

    /// 401 带 reason → key_rejected（状态码 / reason / 分钟数）；一次暂停一条、同 key 第二次暂停不重复。
    func testV7_KeyRejectedOncePerKey() async throws {
        let cap = capture()
        let sh = SharedHarness()
        sh.transport.setScript([.status(401, ["reason": "key_revoked"], [:]), .status(401, ["reason": "key_revoked"], [:])])
        sh.configure(key: Self.testKey)
        sh.shared.log(.warn, "w")
        await sealAndDrain(sh)
        XCTAssertEqual(cap.messages("key_rejected"),
                       ["server rejected the key (HTTP 401, reason=key_revoked); uploads paused for 60 min; logs are kept locally"])
        // 暂停到期、第二次 401 → 暂停 2 h；同 key 不重复出
        let c = sh.client
        sh.clock.advance(Limits.pause401BaseMs)
        await c.tickNow()
        XCTAssertEqual(sh.transport.batchRequests.count, 2)
        let reason = await c.onWork { c.engine.backoff.reason }
        XCTAssertEqual(reason, "auth:7200000")
        XCTAssertEqual(cap.codes, ["key_rejected"])
        // 换 key：403 带 reason，状态码进消息；分钟数 = 本次暂停时长（上次进程留下的同目标倍增状态 2 h → 本次 4 h）
        sh.transport.setScript([.status(403, ["reason": "app_disabled"], [:])])
        sh.configure(key: Self.liveKey)
        await sh.settle()
        await c.onWork { c.engine.backoff.reason = "auth:7200000" }
        sh.clock.advance(Limits.minRequestSpacingMs)
        await c.tickNow()
        XCTAssertEqual(sh.transport.batchRequests.last?.headers["Authorization"], "Bearer \(Self.liveKey)")
        XCTAssertEqual(cap.messages("key_rejected").last,
                       "server rejected the key (HTTP 403, reason=app_disabled); uploads paused for 240 min; logs are kept locally")
        XCTAssertEqual(cap.codes, ["key_rejected", "key_rejected"])
        assertNoKeyLeak(cap, [Self.testKey, Self.liveKey])
    }

    /// 401 无 reason（HTML 体）不出；旧 key 的在途请求回 401 不出；旧 baseURL 的在途请求回 401 也不出。
    func testV7_NonServer401AndStaleTargetDoNotReport() async throws {
        let cap = capture()
        let sh = SharedHarness()
        sh.configure(key: Self.testKey)
        await sh.settle()
        let c = sh.client
        sh.transport.setScript([.raw(401, Data("<html><body>Access denied</body></html>".utf8), ["content-type": "text/html"])])
        sh.shared.log(.warn, "w1")
        await sealAndDrain(sh)
        let r1 = await c.onWork { c.engine.backoff.reason }
        XCTAssertEqual(r1, "http_401", "普通退避")
        XCTAssertEqual(cap.codes, [])
        sh.clock.advance(Limits.minRequestSpacingMs)
        await c.tickNow()
        XCTAssertEqual(sh.outboxFiles(), [], "退避后重发确认")
        // 旧 key 在途：请求挂住 → 换 key → 回 401 + reason：不暂停、不出
        sh.transport.setScript([.heldStatus(401, ["reason": "key_revoked"])])
        sh.clock.advance(Limits.minRequestSpacingMs)
        sh.shared.log(.warn, "w2")
        c.writer.rotate(.timer)
        await c.onWork { c.afterSeal() }
        await waitFor { sh.transport.heldBatchCount == 1 }
        XCTAssertEqual(sh.transport.heldBatchCount, 1)
        sh.configure(key: Self.liveKey)
        await c.onWork {}                                   // 换目标已在引擎线程上生效
        sh.transport.releaseHeldBatches()
        await sh.settle()
        let r2 = await c.onWork { c.engine.backoff.reason }
        XCTAssertFalse(r2.hasPrefix("auth:"))
        XCTAssertEqual(cap.codes, [])
        sh.clock.advance(Limits.minRequestSpacingMs)       // 相邻请求间隔
        await c.tickNow()
        XCTAssertEqual(sh.transport.batchRequests.last?.headers["Authorization"], "Bearer \(Self.liveKey)", "批用新 key 重发")
        XCTAssertEqual(sh.outboxFiles(), [])
        // 旧 baseURL 在途（key 不变）：不出（暂停是否发生按 ADR 0024 决定 7 的现状，只看 key 指纹，这里不断言）
        sh.transport.setScript([.heldStatus(401, ["reason": "key_revoked"])])
        sh.clock.advance(Limits.minRequestSpacingMs)
        sh.shared.log(.warn, "w3")
        c.writer.rotate(.timer)
        await c.onWork { c.afterSeal() }
        await waitFor { sh.transport.heldBatchCount == 1 }
        XCTAssertEqual(sh.transport.heldBatchCount, 1)
        sh.shared.configure(key: Self.liveKey, baseURL: Self.local, options: Options())
        await c.onWork {}
        sh.transport.releaseHeldBatches()
        await sh.settle()
        XCTAssertEqual(cap.codes, [])
    }

    // MARK: V8. reason 清洗

    func testV8_ReasonSanitized() async throws {
        XCTAssertEqual(ConfigCheck.sanitizeReason("key_revoked"), "key_revoked")
        XCTAssertEqual(ConfigCheck.sanitizeReason("Key_Revoked"), "ey_evoked", "大写不在 [a-z0-9_] 里：去掉（不转小写）")
        XCTAssertEqual(ConfigCheck.sanitizeReason("key revoked\n"), "keyrevoked")
        XCTAssertEqual(ConfigCheck.sanitizeReason(String(repeating: "a", count: 100)), String(repeating: "a", count: 40))
        XCTAssertEqual(ConfigCheck.sanitizeReason(String(repeating: "A", count: 50) + String(repeating: "b", count: 50)),
                       String(repeating: "b", count: 40), "先过滤后截断")
        XCTAssertEqual(ConfigCheck.sanitizeReason("!!! -- ÄÖ 中文"), "unknown")
        XCTAssertEqual(ConfigCheck.sanitizeReason(""), "unknown")
        // 分钟数向上取整
        XCTAssertEqual(ConfigCheck.pauseMinutes(1), 1)
        XCTAssertEqual(ConfigCheck.pauseMinutes(60_000), 1)
        XCTAssertEqual(ConfigCheck.pauseMinutes(60_001), 2)
        XCTAssertEqual(ConfigCheck.pauseMinutes(Limits.pause401MaxMs), 1440)
        // 静态入口：服务端回的 reason 经清洗进消息
        let cap = capture()
        let sh = SharedHarness()
        sh.transport.setScript([.status(403, ["reason": "Bad Key! " + String(repeating: "x", count: 60)], [:])])
        sh.configure(key: Self.testKey)
        sh.shared.log(.warn, "w")
        await sealAndDrain(sh)
        XCTAssertEqual(cap.messages("key_rejected"),
                       ["server rejected the key (HTTP 403, reason=adey\(String(repeating: "x", count: 36))); uploads paused for 60 min; logs are kept locally"])
    }

    // MARK: V9. 出口抛异常 / 重入 / 耗时

    /// sink 里判断是否在实例的 work 队列上（给队列挂一个测试用的 specific key）。
    final class QueueProbe: @unchecked Sendable {
        let key = DispatchSpecificKey<Bool>()
        private let lock = NSLock()
        private var hits = 0
        func check() { if DispatchQueue.getSpecific(key: key) == true { lock.withLock { hits += 1 } } }
        var onQueueHits: Int { lock.withLock { hits } }
    }

    func testV9_SinkThrowsOrReentersConfigureUnaffected() async throws {
        struct Boom: Error {}
        let cap = Captured()
        let probe = QueueProbe()
        let sh = SharedHarness()
        let shared = sh.shared
        ConfigDiagnostics.resetForTesting()
        ConfigDiagnostics.setSinkForTesting { code, message in
            cap.add(code, message)
            probe.check()
            // 重入 SDK（出口若在持 SDK 锁时调，这里会死锁）、耗时，然后抛
            shared.log(.warn, "from sink \(code)")
            _ = shared.isEnabled
            Thread.sleep(forTimeInterval: 0.02)
            throw Boom()
        }
        sh.transport.setScript([.status(401, ["reason": "key_invalid"], [:])])
        let bad = "lk_test_demo"
        shared.configure(key: " " + bad, baseURL: try XCTUnwrap(URL(string: "logs.revdog.org")), options: Options())
        XCTAssertEqual(cap.codes, ["key_trimmed", "key_malformed", "base_url_invalid"], "每条都出（前一条抛了不影响后一条）")
        let c = try XCTUnwrap(shared.instanceForTesting, "configure 照常建实例")
        c.work.setSpecific(key: probe.key, value: true)
        await sh.settle()
        let key = await c.onWork { c.engine.key }
        XCTAssertEqual(key, bad, "照常修剪")
        shared.log(.warn, "w")
        await sealAndDrain(sh)
        XCTAssertEqual(sh.transport.batchRequests.count, 1, "请求照发")
        XCTAssertEqual(cap.codes, ["key_trimmed", "key_malformed", "base_url_invalid", "key_rejected"])
        XCTAssertEqual(probe.onQueueHits, 0, "key_rejected 不在 work 队列上出")
        await c.onWork { probe.check() }
        XCTAssertEqual(probe.onQueueHits, 1, "探针本身有效")
        let (reason, stop) = await c.onWork { (c.engine.backoff.reason, c.debugLastStopReason) }
        XCTAssertEqual(reason, "auth:3600000", "暂停照常")
        XCTAssertEqual(stop, "paused", "排空照常收尾")
        XCTAssertEqual(sh.outboxFiles().count, 1, "批留着")
        // sink 里写的行照常落盘（configure 路径与排空路径各自的重入都没被挡）
        c.writer.rotate(.timer)
        await sh.settle()
        let dir = c.root.appendingPathComponent("proc-main").appendingPathComponent(c.writer.currentSessionId)
        let msgs = segmentLines(dir).compactMap { $0["msg"] as? String }
        for code in ["key_trimmed", "key_malformed", "base_url_invalid", "key_rejected"] {
            XCTAssertTrue(msgs.contains("from sink \(code)"), code)
        }
    }

    // MARK: 出口（不换 sink：真写系统日志，从本进程日志里读回）

    func testExit_SystemLogSubsystemCategoryLevels() async throws {
        ConfigDiagnostics.resetForTesting()
        let since = Date().addingTimeInterval(-1)
        let sh = SharedHarness()
        sh.shared.configure(key: "", baseURL: try XCTUnwrap(URL(string: "ftp://exit-probe-\(UUID().uuidString.prefix(8))")),
                            options: Options())
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "org.revdog.retriever", "diagnostics")
        let got = try store.getEntries(at: store.position(date: since), matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }.map { ($0.level, $0.composedMessage) }
        XCTAssertTrue(got.contains { $0.0 == .info && $0.1 == ConfigCheck.Diagnostic.noKey.message }, "no_key 用 info：\(got)")
        XCTAssertTrue(got.contains { $0.0 == .notice && $0.1 == ConfigCheck.Diagnostic.baseURLInvalid.message }, "其余用 notice：\(got)")
    }
}

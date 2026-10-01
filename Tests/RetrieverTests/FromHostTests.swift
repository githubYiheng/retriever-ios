import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 缓存只记远程明确给的值（ADR 0022；简报 §2 / §11 K）。假服务端开回显模式（与 ingest 一致）。
final class FromHostTests: XCTestCase {
    func dir(_ sh: SharedHarness) -> URL {
        sh.client.root.appendingPathComponent("proc-main").appendingPathComponent(sh.client.writer.currentSessionId)
    }

    /// 上一次进程以 uploadLevel 拉到配置并缓存（未过期），然后「死掉」；返回同一 base。
    func primeCache(_ level: LogLevel, remote: [String: Any] = ["etag": "e1"]) async -> (URL, FakeClock) {
        let sh = SharedHarness()
        sh.transport.configEcho = true
        sh.transport.configBody = remote
        sh.configure { $0.uploadLevel = level }
        await sh.settle()
        XCTAssertNotNil(sh.client.engine.configCache)
        sh.client.simulateCrash()
        return (sh.base, sh.clock)
    }

    func nextLaunch(_ base: URL, _ clock: FakeClock) -> SharedHarness {
        let t = FakeTransport()
        t.configEcho = true
        t.configHold = true                         // 本次的配置迟迟不回：生效配置 = 缓存 + 当前宿主默认
        return SharedHarness(base: base, clock: clock, transport: t)
    }

    func testK_CachedEchoDoesNotOverrideCurrentHost() async throws {
        // 上次 INFO → 本次 WARN：info 行（configure 前后）都无 oseq
        let (b1, c1) = await primeCache(.info)
        let cache = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: b1.appendingPathComponent("default/config.json"))) as? [String: Any])
        XCTAssertEqual(cache["from_host"] as? [String], ["upload_level", "local_level", "local_cap_bytes", "daily_batch_cap"])
        XCTAssertEqual((cache["config"] as? [String: Any])?["upload_level"] as? String, "info", "缓存里是回显的旧宿主值")
        let s1 = nextLaunch(b1, c1)
        s1.shared.log(.info, "pre info")
        s1.configure { $0.uploadLevel = .warn }
        await s1.settle()
        s1.client.log(.info, "post info")
        var ls = segmentLines(dir(s1)).filter { ($0["msg"] as? String)?.contains("info") == true }
        XCTAssertEqual(ls.count, 2)
        XCTAssertTrue(ls.allSatisfy { $0["oseq"] == nil }, "按本次 WARN 判定")
        s1.transport.cancelAll()

        // 反向：上次 WARN → 本次 INFO：都有 oseq
        let (b2, c2) = await primeCache(.warn)
        let s2 = nextLaunch(b2, c2)
        s2.shared.log(.info, "pre info")
        s2.configure { $0.uploadLevel = .info }
        await s2.settle()
        s2.client.log(.info, "post info")
        ls = segmentLines(dir(s2)).filter { ($0["msg"] as? String)?.contains("info") == true }
        XCTAssertEqual(ls.map { int($0["oseq"]) }, [1, 2])
        s2.transport.cancelAll()

        // 远程明确给 upload_level（不在 from_host）：不随宿主变
        let (b3, c3) = await primeCache(.warn, remote: ["etag": "r", "upload_level": "error"])
        let s3 = nextLaunch(b3, c3)
        s3.configure { $0.uploadLevel = .info }
        await s3.settle()
        XCTAssertEqual(s3.client.effectiveLevels.upload, .error)
        s3.client.log(.warn, "w")
        s3.client.log(.error, "e")
        ls = segmentLines(dir(s3)).filter { ["w", "e"].contains($0["msg"] as? String ?? "") }
        XCTAssertEqual(ls.map { $0["oseq"] == nil }, [true, false])
        s3.transport.cancelAll()
    }

    /// reconfigure 返回后立即写的行按新级别——引擎线程被堵住也成立（宿主默认在宿主线程上同步生效）。
    func testK_ReconfigureLevelAppliesSynchronously() async throws {
        let sh = SharedHarness()
        sh.configure(key: "")
        await sh.settle()
        let release = await blockWork(sh.client)
        sh.configure(key: "") { $0.uploadLevel = .info }
        sh.client.log(.info, "now obligatory")
        XCTAssertEqual(sh.client.debugCounters.oseq, 1)
        release()
        await sh.settle()
    }

    /// 请求在途时宿主默认变了：响应丢弃（不缓存、不生效）并按新宿主默认重拉。
    func testK_InFlightResponseForOldHostDiscarded() async throws {
        let sh = SharedHarness()
        sh.transport.configEcho = true
        sh.transport.configBody = ["etag": "x"]
        sh.transport.configHold = true
        sh.configure { $0.uploadLevel = .warn }
        await waitFor { sh.transport.heldConfigCount == 1 }
        XCTAssertEqual(sh.transport.configRequests.last?.headers["X-Rtv-Upload-Level"], "warn")
        sh.transport.configHold = false
        sh.configure { $0.uploadLevel = .info }
        sh.transport.releaseHeldConfigs()                  // 旧宿主（warn）的响应此刻才到
        await sh.settle()
        XCTAssertEqual(sh.transport.configRequests.last?.headers["X-Rtv-Upload-Level"], "info", "按新宿主默认重拉")
        let cache = try XCTUnwrap(sh.client.engine.configCache)
        XCTAssertEqual(cache.config.uploadLevel, .info, "缓存的是新请求的响应")
        XCTAssertEqual(sh.client.effectiveLevels.upload, .info)
    }

    /// golden `from_host[]` 回放：(1) 移植的 hostDerivedFields 与 core 逐项一致（假服务端的回显靠它）；
    /// (2) 按服务端的形状给出响应（clamp(raw, hostA) + from_host），换一个宿主 hostB 求生效配置：
    /// from_host 里的字段取 hostB，其余取 clamp(raw, hostA)。
    func testK_GoldenFromHostReplay() throws {
        let g = try Repo.golden("config.json")
        let vs = try XCTUnwrap(g["from_host"] as? [[String: Any]])
        XCTAssertGreaterThan(vs.count, 0)
        let hostA = HostDefaults(uploadLevel: .info, localLevel: .info, dailyBatchCap: 7, localCapBytes: 3 * 1024 * 1024)
        let hostB = HostDefaults(uploadLevel: .error, localLevel: .warn, dailyBatchCap: 99, localCapBytes: 60 * 1024 * 1024)
        for v in vs {
            let name = v["name"] as? String ?? ""
            let raw: Any? = (v["raw"] is NSNull) ? nil : v["raw"]
            let expect = try XCTUnwrap(v["expect"] as? [String])
            XCTAssertEqual(ConfigRules.hostDerivedFields(raw), expect, name)
            var resp: [String: Any] = [:]
            let ca = ConfigRules.clamp(raw, host: hostA)
            resp = (try JSONSerialization.jsonObject(with: Data(ConfigRules.encode(ca))) as? [String: Any]) ?? [:]
            resp["from_host"] = expect
            let cache = ConfigCache(config: ConfigRules.clamp(resp, host: hostA), fetchedWallMs: 0, fetchedMonoMs: 0,
                                    fromHost: ConfigRules.parseFromHost(resp["from_host"]))
            let e = ConfigCache.effective(cache, host: hostB, nowWall: 0, nowMono: 1).config
            XCTAssertEqual(e.uploadLevel, expect.contains("upload_level") ? .error : ca.uploadLevel, name)
            XCTAssertEqual(e.localLevel, expect.contains("local_level") ? .warn : ca.localLevel, name)
            XCTAssertEqual(e.localCapBytes, expect.contains("local_cap_bytes") ? 60 * 1024 * 1024 : ca.localCapBytes, name)
            XCTAssertEqual(e.dailyBatchCap, expect.contains("daily_batch_cap") ? 99 : ca.dailyBatchCap, name)
        }
        // 旧响应 / 旧缓存没有 from_host → 空集（现状行为）
        XCTAssertEqual(ConfigRules.parseFromHost(nil), [])
        XCTAssertEqual(ConfigRules.parseFromHost(["upload_level", "bogus", 3]), ["upload_level"])
    }

    /// SDK clamp 的 local_cap_bytes 缺省取宿主值（对齐 config.ts）。golden `clamp[]` 已有带 `host.localCapBytes` 的向量
    /// （GoldenTests.testConfigClamp 回放）；这里再直接断言几个边界。
    func testK_ClampLocalCapDefaultsToHost() {
        let h = HostDefaults(uploadLevel: .warn, localCapBytes: 50 * 1024 * 1024)
        XCTAssertEqual(ConfigRules.clamp([String: Any](), host: h).localCapBytes, 50 * 1024 * 1024)
        XCTAssertEqual(ConfigRules.clamp(["local_cap_bytes": "x"], host: h).localCapBytes, 50 * 1024 * 1024)
        XCTAssertEqual(ConfigRules.clamp(["local_cap_bytes": 1], host: h).localCapBytes, Limits.localCapBytesMin)
        XCTAssertEqual(ConfigRules.clamp([String: Any](), host: HostDefaults(uploadLevel: .warn, localCapBytes: 1)).localCapBytes,
                       Limits.localCapBytesMin, "宿主值先钳到 2–100 MB")
    }
}

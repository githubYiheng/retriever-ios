import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

final class BackupAndPerfTests: XCTestCase {
    func excluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    /// 目录与每个新建文件都设 isExcludedFromBackup（macOS 也支持该 resource value）；iOS 另设保护类别。
    func testBackupExclusionOnDirsAndFiles() async throws {
        let h = Harness(key: "")
        h.client.log(.warn, "w")
        await h.seal()
        let dir = h.sessionDir()
        var urls = [h.root, h.root.appendingPathComponent("install.json"), h.root.appendingPathComponent("outbox"),
                    h.root.appendingPathComponent("proc-main"), dir, dir.appendingPathComponent("meta.json"),
                    dir.appendingPathComponent("cursor.json"), dir.appendingPathComponent("seg-000001.sealed"),
                    dir.appendingPathComponent("seg-000002.open")]
        urls.append(contentsOf: h.outboxFiles().map { h.outbox.appendingPathComponent($0) })
        XCTAssertEqual(h.outboxFiles().count, 1)
        for u in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), u.path)
            XCTAssertTrue(excluded(u), u.lastPathComponent)
        }
        #if os(iOS)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("seg-000002.open").path)
        XCTAssertEqual(attrs[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
    }

    func testLayoutAndInstallJson() async throws {
        let h = Harness(key: "")
        await h.settle()
        let inst = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.root.appendingPathComponent("install.json"))) as? [String: Any])
        XCTAssertTrue(IDs.isUuid(inst["install_id"] as? String ?? ""))
        XCTAssertEqual(int(inst["session_counter"]), 1)
        XCTAssertEqual(h.client.installId, inst["install_id"] as? String)
        XCTAssertEqual(h.client.supportCode, String((inst["install_id"] as! String).prefix(8)) + "-1")
        let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: h.sessionDir().appendingPathComponent("meta.json"))) as? [String: Any])
        XCTAssertEqual(int(meta["session_no"]), 1)
        XCTAssertEqual(meta["process"] as? String, "main")
        XCTAssertEqual((meta["device"] as? [String: Any])?["sdk"] as? String, "retriever-ios/0.1.0")
        // 第二次启动：计数器 +1，install_id 不变
        let h2 = Harness(root: h.root, key: "")
        await h2.settle()
        XCTAssertEqual(h2.client.installId, h.client.installId)
        XCTAssertTrue(h2.client.supportCode!.hasSuffix("-2"))
        // purgeLocal：新 install_id
        h2.client.purgeLocal()
        XCTAssertNotEqual(h2.client.installId, h.client.installId)
        XCTAssertTrue(h2.client.supportCode!.hasSuffix("-1"))
        h2.client.log(.warn, "after purge")
        XCTAssertEqual(h2.client.debugCounters.seq, 1)
    }

    /// 性能（信息性）：主线程 log() 1 万次的 p99，打印到测试输出。
    func testLogLatencyP99() {
        let h = Harness(key: "")
        let c = h.client
        var samples: [UInt64] = []
        samples.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            c.log(i % 10 == 0 ? .warn : .info, "request finished", tag: "net",
                  attrs: ["status": .number(200), "path": .string("/v1/plan"), "ms": .number(Double(i % 300))])
            samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0)
        }
        samples.sort()
        let p50 = Double(samples[5_000]) / 1000
        let p99 = Double(samples[9_900]) / 1000
        let max = Double(samples.last!) / 1000
        print("[perf] log() x10000 on main thread: p50=\(String(format: "%.1f", p50))µs p99=\(String(format: "%.1f", p99))µs max=\(String(format: "%.1f", max))µs")
        XCTAssertLessThan(p99, 1000)
    }
}

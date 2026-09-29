import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// os.Logger 替身（RetrieverLogger）：级别映射、attrs 合并 subsystem、localLevel 早过滤。
final class RetrieverLoggerTests: XCTestCase {
    final class Rec: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(LogLevel, String, String?, [String: AttrValue]?, (any Error)?)] = []
        var local: LogLevel = .debug
        func add(_ c: (LogLevel, String, String?, [String: AttrValue]?, (any Error)?)) { lock.lock(); calls.append(c); lock.unlock() }
    }

    func make(_ rec: Rec) -> RetrieverLogger {
        RetrieverLogger(subsystem: "com.example.bff", category: "billing",
                        emit: { rec.add(($0, $1, $2, $3, $4)) }, localLevel: { rec.lock.withLock { rec.local } })
    }

    func testLevelMappingAndTag() {
        let rec = Rec()
        let log = make(rec)
        log.debug("d")
        log.info("i")
        log.notice("n")
        log.warning("w")
        log.error("e")
        log.fault("f")
        XCTAssertEqual(rec.calls.map(\.0), [.debug, .info, .info, .warn, .error, .fatal])
        XCTAssertEqual(rec.calls.map(\.1), ["d", "i", "n", "w", "e", "f"])
        XCTAssertTrue(rec.calls.allSatisfy { $0.2 == "billing" }, "tag = category")
    }

    func testAttrsMergeSubsystemAndError() {
        struct Declined: Error {}
        let rec = Rec()
        let log = make(rec)
        log.error("purchase failed", attrs: ["sku": .string("pro"), "ms": .number(12)], error: Declined())
        log.info("plain")
        log.info("override", attrs: ["subsystem": .string("custom")])
        XCTAssertEqual(rec.calls[0].3, ["sku": .string("pro"), "ms": .number(12), "subsystem": .string("com.example.bff")])
        XCTAssertTrue(rec.calls[0].4 is Declined)
        XCTAssertEqual(rec.calls[1].3, ["subsystem": .string("com.example.bff")])
        XCTAssertEqual(rec.calls[2].3?["subsystem"], .string("custom"), "调用方显式给的 subsystem 不覆盖")
    }

    func testLocalLevelEarlyFilter() {
        let rec = Rec()
        rec.local = .warn
        let log = make(rec)
        log.debug("x")
        log.info("x")
        log.notice("x")
        log.warning("kept")
        log.fault("kept")
        XCTAssertEqual(rec.calls.map(\.0), [.warn, .fatal])
    }

    /// 端到端：经真实实例落盘，exc / tag / attrs 形状正确。
    func testEndToEndIntoSegment() throws {
        let h = Harness(key: "")
        let c = h.client
        let log = RetrieverLogger(subsystem: "com.example.bff", category: "net",
                                  emit: { c.log($0, $1, tag: $2, attrs: $3, error: $4) }, localLevel: { c.effectiveLevels.local })
        log.warning("slow", attrs: ["ms": .number(3200)], error: NSError(domain: "D", code: 3))
        let text = try String(contentsOfFile: try XCTUnwrap(c.debugOpenSegmentPath), encoding: .utf8)
        let line = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.split(separator: "\n")[1].utf8)) as? [String: Any])
        XCTAssertEqual(line["level"] as? String, "warn")
        XCTAssertEqual(line["tag"] as? String, "net")
        XCTAssertEqual((line["attrs"] as? [String: Any])?["subsystem"] as? String, "com.example.bff")
        XCTAssertTrue(((line["exc"] as? [String: Any])?["message"] as? String ?? "").hasPrefix("D (3): "))
    }
}

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

    final class SysRec: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(RetrieverLogger.SystemLevel, String, Bool)] = []
        func add(_ c: (RetrieverLogger.SystemLevel, String, Bool)) { lock.lock(); calls.append(c); lock.unlock() }
    }

    /// 系统日志那一路默认 `.private`（ADR 0020 决定 5）；`publicSystemLog: true` 才 `.public`；低于 localLevel 的行系统日志照写。
    func testSystemLogPrivateByDefault() {
        XCTAssertFalse(RetrieverLogger(subsystem: "com.example.bff", category: "billing").publicSystemLog)
        XCTAssertTrue(RetrieverLogger(subsystem: "com.example.bff", category: "billing", publicSystemLog: true).publicSystemLog)
        let rec = Rec()
        rec.local = .fatal
        let sys = SysRec()
        let priv = RetrieverLogger(subsystem: "com.example.bff", category: "billing", emit: { rec.add(($0, $1, $2, $3, $4)) },
                                   localLevel: { rec.lock.withLock { rec.local } }, systemLog: { sys.add(($0, $1, $2)) })
        priv.debug("d")
        priv.info("i")
        priv.notice("n")
        priv.warning("w")
        priv.error("e")
        priv.fault("f")
        XCTAssertEqual(sys.calls.map(\.0), [.debug, .info, .notice, .warning, .error, .fault])
        XCTAssertEqual(sys.calls.map(\.1), ["d", "i", "n", "w", "e", "f"])
        XCTAssertTrue(sys.calls.allSatisfy { !$0.2 }, "默认私有")
        XCTAssertEqual(rec.calls.map(\.0), [.fatal], "Retriever 那一路照旧按 localLevel 早过滤")
        let pubSys = SysRec()
        let pub = RetrieverLogger(subsystem: "com.example.bff", category: "billing", publicSystemLog: true,
                                  emit: { rec.add(($0, $1, $2, $3, $4)) }, localLevel: { .debug }, systemLog: { pubSys.add(($0, $1, $2)) })
        pub.error("static text")
        XCTAssertEqual(pubSys.calls.map(\.2), [true])
        // 真实 os.Logger 路径（两支）能走通
        RetrieverLogger(subsystem: "com.example.bff", category: "billing", emit: { _, _, _, _, _ in }, localLevel: { .fatal }).info("private")
        RetrieverLogger(subsystem: "com.example.bff", category: "billing", publicSystemLog: true, emit: { _, _, _, _, _ in },
                        localLevel: { .fatal }).info("public")
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

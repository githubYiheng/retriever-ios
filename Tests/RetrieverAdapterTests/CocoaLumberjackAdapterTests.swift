import Foundation
import XCTest
import CocoaLumberjackSwift
@testable import RetrieverCocoaLumberjack
@_spi(RetrieverTesting) import Retriever

final class CocoaLumberjackAdapterTests: XCTestCase {
    func make(_ rec: Recorder, _ lvl: LevelBox = LevelBox()) -> RetrieverDDLogger {
        RetrieverDDLogger(emit: { rec.add(.init(level: $0, msg: $1, tag: $2, attrs: $3, error: nil)) }, localLevel: { lvl.level })
    }

    func message(_ text: String, flag: DDLogFlag, tag: Any? = nil, function: String? = "f()") -> DDLogMessage {
        DDLogMessage(format: text, formatted: text, level: .all, flag: flag, context: 0, file: "/tmp/src/Billing.swift",
                     function: function, line: 42, tag: tag, options: [], timestamp: nil)
    }

    func testFlagMapping() {
        XCTAssertEqual(RetrieverDDLogger.level(for: .error), .error)
        XCTAssertEqual(RetrieverDDLogger.level(for: .warning), .warn)
        XCTAssertEqual(RetrieverDDLogger.level(for: .info), .info)
        XCTAssertEqual(RetrieverDDLogger.level(for: .debug), .debug)
        XCTAssertEqual(RetrieverDDLogger.level(for: .verbose), .debug)
        XCTAssertEqual(RetrieverDDLogger.level(for: [.warning, .error]), .error)
        XCTAssertNil(RetrieverDDLogger.level(for: []))
    }

    func testTagAndAttrs() {
        let rec = Recorder()
        let logger = make(rec)
        logger.log(message: message("with tag", flag: .warning, tag: "billing"))
        logger.log(message: message("no tag", flag: .info, function: nil))
        let c = rec.calls
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].level, .warn)
        XCTAssertEqual(c[0].msg, "with tag")
        XCTAssertEqual(c[0].tag, "billing")
        XCTAssertEqual(c[0].attrs?["file"], .string("Billing"))
        XCTAssertEqual(c[0].attrs?["function"], .string("f()"))
        XCTAssertEqual(c[0].attrs?["line"], .number(42))
        XCTAssertEqual(c[1].tag, "Billing", "没有 representedObject 用文件名")
        XCTAssertNil(c[1].attrs?["function"])
    }

    func testLocalLevelEarlyFilter() {
        let rec = Recorder()
        let lvl = LevelBox()
        lvl.level = .warn
        let logger = make(rec, lvl)
        for f: DDLogFlag in [.verbose, .debug, .info, .warning, .error] { logger.log(message: message("m", flag: f)) }
        XCTAssertEqual(rec.calls.map(\.level), [.warn, .error])
    }

    /// 宿主按文档关掉异步分发后，DDLog 调用返回时行已经到了 Retriever（R-1 从 DDLog 调用起算）。
    func testSynchronousThroughDDLog() {
        let rec = Recorder()
        let ddlog = DDLog()
        ddlog.add(make(rec), with: .all)
        let saved = asyncLoggingEnabled
        asyncLoggingEnabled = false
        defer { asyncLoggingEnabled = saved }
        DDLogInfo("sync info", ddlog: ddlog)
        XCTAssertEqual(rec.calls.map(\.msg), ["sync info"])
        DDLogError("sync error", tag: 7, ddlog: ddlog)
        XCTAssertEqual(rec.calls.last?.level, .error)
        XCTAssertEqual(rec.calls.last?.tag, "7")
    }

    /// 端到端：经真实 RetrieverClient 落盘；tag 由 SDK 截到 64 B。
    func testEndToEndIntoSegment() throws {
        let client = makeClient()
        let logger = RetrieverDDLogger(emit: { client.log($0, $1, tag: $2, attrs: $3) }, localLevel: { client.effectiveLevels.local })
        logger.log(message: message("purchase failed", flag: .error, tag: String(repeating: "t", count: 100)))
        logger.log(message: message("verbose", flag: .verbose))
        let ls = try segmentLines(client)
        XCTAssertEqual(ls.count, 2)
        XCTAssertEqual(ls[0]["level"] as? String, "error")
        XCTAssertNotNil(ls[0]["oseq"])
        XCTAssertEqual((ls[0]["tag"] as? String)?.utf8.count, 64)
        XCTAssertEqual(ls[0]["truncated"] as? Bool, true)
        XCTAssertEqual((ls[0]["attrs"] as? [String: Any])?["line"] as? Int, 42)
        XCTAssertEqual(ls[1]["level"] as? String, "debug")
    }
}

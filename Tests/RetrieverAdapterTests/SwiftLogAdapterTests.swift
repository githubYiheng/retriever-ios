import Foundation
import XCTest
import Logging
@testable import RetrieverSwiftLog
@_spi(RetrieverTesting) import Retriever

final class SwiftLogAdapterTests: XCTestCase {
    func make(_ rec: Recorder, _ lvl: LevelBox = LevelBox(), label: String = "app.net",
              provider: Logger.MetadataProvider? = nil) -> RetrieverLogHandler {
        RetrieverLogHandler(label: label, metadataProvider: provider,
                            emit: { rec.add(.init(level: $0, msg: $1, tag: $2, attrs: $3, error: $4)) },
                            localLevel: { lvl.level })
    }

    func testLevelMapping() {
        let expect: [(Logger.Level, LogLevel)] = [
            (.trace, .debug), (.debug, .debug), (.info, .info), (.notice, .info),
            (.warning, .warn), (.error, .error), (.critical, .fatal),
        ]
        for (a, b) in expect { XCTAssertEqual(RetrieverLogHandler.level(a), b, "\(a)") }
        let rec = Recorder()
        var logger = Logger(label: "x") { self.make(rec, label: $0) }
        logger.logLevel = .trace
        logger.critical("boom")
        XCTAssertEqual(rec.calls.first?.level, .fatal)
        XCTAssertEqual(rec.calls.first?.tag, "x")
    }

    func testDefaultLogLevelInfoAndLocalLevelFilter() {
        let rec = Recorder()
        let lvl = LevelBox()
        let logger = Logger(label: "app") { _ in self.make(rec, lvl) }
        XCTAssertEqual(logger.logLevel, .info)
        logger.debug("dropped by swift-log")
        logger.info("kept")
        lvl.level = .warn
        logger.notice("dropped by Retriever.localLevel")
        logger.warning("kept too")
        XCTAssertEqual(rec.calls.map(\.msg), ["kept", "kept too"])
    }

    func testMetadataFlattenAndPrecedence() {
        let rec = Recorder()
        let provider = Logger.MetadataProvider { ["trace_id": "p-1", "who": "provider"] }
        var logger = Logger(label: "app") { _ in self.make(rec, provider: provider) }
        logger[metadataKey: "who"] = "handler"
        logger[metadataKey: "env"] = "staging"
        logger.info("req", metadata: [
            "who": "call",
            "http": ["status": .stringConvertible(200), "path": "/v1/plan", "hdr": ["x": "1"]],
            "ids": [.string("a"), .stringConvertible(2), ["k": "v"]],
            "ratio": .stringConvertible(0.5),
        ])
        let a = try! XCTUnwrap(rec.calls.first?.attrs)
        XCTAssertEqual(a["who"], .string("call"), "调用处 > provider > handler")
        XCTAssertEqual(a["trace_id"], .string("p-1"))
        XCTAssertEqual(a["env"], .string("staging"))
        XCTAssertEqual(a["http.status"], .string("200"))
        XCTAssertEqual(a["http.path"], .string("/v1/plan"))
        XCTAssertEqual(a["http.hdr.x"], .string("1"))
        XCTAssertEqual(a["ids"], .string(#"["a","2",{"k":"v"}]"#))
        XCTAssertEqual(a["ratio"], .string("0.5"))
        XCTAssertNil(a["http"])
    }

    func testErrorAndEventPath() {
        struct Boom: Error {}
        let rec = Recorder()
        let h = make(rec)
        h.log(event: LogEvent(level: .error, message: "failed", error: Boom(), metadata: nil, source: "M",
                              file: #file, function: #function, line: #line))
        XCTAssertEqual(rec.calls.first?.level, .error)
        XCTAssertTrue(rec.calls.first?.error is Boom)
        XCTAssertNil(rec.calls.first?.attrs)
    }

    /// 旧签名与 log(event:) 一致。
    @available(*, deprecated)
    func testLegacySignaturesMatchEvent() {
        let rec = Recorder()
        let h = make(rec)
        h.log(level: .warning, message: "old", metadata: ["k": "v"], source: "S", file: "f", function: "g", line: 1)
        h.log(level: .warning, message: "old", metadata: ["k": "v"], file: "f", function: "g", line: 1)
        h.log(event: LogEvent(level: .warning, message: "old", metadata: ["k": "v"], source: "S", file: "f", function: "g", line: 1))
        let c = rec.calls
        XCTAssertEqual(c.count, 3)
        for x in c {
            XCTAssertEqual(x.level, .warn)
            XCTAssertEqual(x.msg, "old")
            XCTAssertEqual(x.tag, "app.net")
            XCTAssertEqual(x.attrs, ["k": .string("v")])
        }
    }

    /// attrs 上限由 SDK 截：≤ 32 键、序列化 ≤ 4 KB，并标 truncated。
    func testAttrsLimitsEnforcedBySDK() throws {
        let client = makeClient()
        let h = RetrieverLogHandler(label: "bulk", emit: { client.log($0, $1, tag: $2, attrs: $3, error: $4) },
                                    localLevel: { client.effectiveLevels.local })
        let logger = Logger(label: "bulk") { _ in h }
        var md: Logger.Metadata = [:]
        for i in 0..<40 { md[String(format: "k%02d", i)] = .string(String(repeating: "v", count: 150)) }
        logger.warning("many attrs", metadata: md)
        let line = try XCTUnwrap(try segmentLines(client).first)
        let attrs = try XCTUnwrap(line["attrs"] as? [String: Any])
        XCTAssertLessThanOrEqual(attrs.count, 32)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: attrs).count, 4096)
        XCTAssertEqual(line["truncated"] as? Bool, true)
        XCTAssertEqual(line["tag"] as? String, "bulk")
        XCTAssertEqual(line["level"] as? String, "warn")
    }
}

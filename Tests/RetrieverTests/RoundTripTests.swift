import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 收编时「解码 → redact 钩子 → 重编码」往返无损（简报 §1.2 第 4 条）：恒等钩子下输出行体与输入逐字节相同。
/// 向量同时落成两端共用的夹具 `Fixtures/pre-roundtrip.json`（`[{"name","body"}]`；body = 行体原文、不含行尾 `\n`，
/// 即 pre 文件行记录去掉 `{"r":0,` 之后、段文件行去掉 `{"seq":N[,"oseq":M],` 之后的部分）。
/// 设 `RTV_WRITE_FIXTURES=1` 跑本测试会重写夹具。
final class RoundTripTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pre-roundtrip.json")

    struct V { var name: String; var line: LogLine; var synthetic = false }

    static var vectors: [V] {
        let ts: Int64 = 1_790_668_800_123
        var keys32: [String: AttrValue] = [:]
        for i in 0..<32 { keys32[String(format: "k%02d", i)] = .int(Int64(i)) }
        var keys40: [String: AttrValue] = [:]
        for i in 0..<40 { keys40[String(format: "k%02d", i)] = .string("v\(i)") }
        return [
            V(name: "plain_no_tag", line: LogLine(ts: ts, level: .info, msg: "hello")),
            V(name: "with_tag", line: LogLine(ts: ts, level: .debug, msg: "m", tag: "billing")),
            V(name: "int_attrs", line: LogLine(ts: ts, level: .warn, msg: "ints",
                                               attrs: ["n": .int(5), "neg": .int(-42), "zero": .int(0), "max_safe": .int(9_007_199_254_740_991)])),
            V(name: "decimal_attrs", line: LogLine(ts: ts, level: .info, msg: "decimals",
                                                   attrs: ["f": .number(0.1), "g": .number(-1.25), "tiny": .number(1.5e-7),
                                                           "huge": .number(1e21), "e300": .number(2.5e300), "whole": .number(5)])),
            V(name: "big_int_as_string", line: LogLine(ts: ts, level: .error, msg: "ids",
                                                       attrs: ["id": .int(9_007_199_254_740_993), "max": .int(.max), "min": .int(.min)])),
            V(name: "bool_attrs", line: LogLine(ts: ts, level: .info, msg: "b", attrs: ["ok": .bool(true), "no": .bool(false)])),
            V(name: "nonfinite_as_string", line: LogLine(ts: ts, level: .info, msg: "nf",
                                                         attrs: ["nan": .number(.nan), "inf": .number(.infinity), "ninf": .number(-.infinity)])),
            V(name: "escaped_strings", line: LogLine(ts: ts, level: .warn, msg: "q\"uote \\ back\nnl\ttab\r\u{1}\u{1F}/slash 中文 😀 \u{2028}",
                                                     tag: "t\"g", attrs: ["s": .string("a\"b\\c\u{0}d"), "e": .string("")])),
            V(name: "exc_with_stack", line: LogLine(ts: ts, level: .error, msg: "boom", tag: "x",
                                                    exc: LogException(type: "Foundation.NSError", message: "d (1): bad \"x\"",
                                                                      stack: "at a()\n\tat b()\nCaused by: c"))),
            V(name: "exc_without_stack", line: LogLine(ts: ts, level: .fatal, msg: "dead",
                                                       exc: LogException(type: "MyApp.Err", message: "oops"))),
            V(name: "synthetic", line: LogLine(ts: ts, level: .warn, msg: "lines dropped before a session was available",
                                               tag: "rtv.pre_init_dropped", attrs: ["count": .int(3), "error_count": .int(1),
                                                                                   "first_ts": .int(ts - 5), "last_ts": .int(ts)]), synthetic: true),
            V(name: "truncated_msg", line: LogLine(ts: ts, level: .info, msg: String(repeating: "长", count: 2000))),
            V(name: "empty_attrs", line: LogLine(ts: ts, level: .info, msg: "no attrs", attrs: [:])),
            V(name: "attrs_32_keys", line: LogLine(ts: ts, level: .info, msg: "k32", attrs: keys32)),
            V(name: "attrs_40_keys_truncated", line: LogLine(ts: ts, level: .info, msg: "k40", attrs: keys40)),
            V(name: "empty_msg_negative_ts", line: LogLine(ts: -1, level: .debug, msg: "")),
        ]
    }

    /// 行体（不含行尾 \n）。
    static func body(_ v: V) -> String {
        var b = LineEncoder.encode(v.line, synthetic: v.synthetic).body
        b.removeLast()
        return String(decoding: b, as: UTF8.self)
    }

    func testIdentityRedactRoundTripIsByteExact() throws {
        let identity: @Sendable (LogLine) -> LogLine? = { $0 }
        var mismatches: [String] = []
        for v in RoundTripTests.vectors {
            let input = Array(RoundTripTests.body(v).utf8) + [0x0A]
            let d = try XCTUnwrap(LineDecoder.decode(input), v.name)
            var l = try XCTUnwrap(identity(d.line))
            l.ts = d.line.ts
            let output = LineEncoder.encode(l, synthetic: d.synthetic, truncated: d.truncated).body
            if output != input {
                mismatches.append("\(v.name)\n  in : \(String(decoding: input, as: UTF8.self))\n  out: \(String(decoding: output, as: UTF8.self))")
            }
        }
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    /// 同一组行体走真实收编路径（pre 文件 → 恒等钩子 → 段文件）：段里每行去掉 seq / oseq 前缀后与 pre 记录的行体逐字节相同。
    func testAdoptionWithIdentityHookKeepsBytes() async throws {
        let sh = SharedHarness()
        let identity: @Sendable (LogLine) -> LogLine? = { $0 }
        for v in RoundTripTests.vectors where !v.synthetic {
            sh.shared.log(v.line.level, v.line.msg, tag: v.line.tag, attrs: v.line.attrs)
        }
        let pre = sh.preDir.appendingPathComponent(sh.preFiles()[0])
        let bodies = preRecords(pre).dropFirst().map { String($0.dropFirst("{\"r\":0,".count)) }
        sh.configure(key: "") { $0.redact = identity; $0.uploadLevel = .debug }
        await sh.settle()
        let dir = sh.client.root.appendingPathComponent("proc-main/\(sh.client.writer.currentSessionId)")
        let raw = FS.list(dir).filter { Segments.parseName($0) != nil }.sorted().flatMap { n in
            (try! String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)).split(separator: "\n").dropFirst().map(String.init)
        }
        let stripped = raw.map { l -> String in String(l[l.range(of: "\"ts\":")!.lowerBound...]) }
        XCTAssertEqual(stripped, bodies)
    }

    /// 夹具与当前编码器一致（Android 用同一份）。
    func testFixtureMatchesEncoder() throws {
        let vs = RoundTripTests.vectors.map { ["name": $0.name, "body": RoundTripTests.body($0)] }
        if ProcessInfo.processInfo.environment["RTV_WRITE_FIXTURES"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: vs, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: RoundTripTests.fixture)
        }
        let fx = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: RoundTripTests.fixture)) as? [[String: String]])
        XCTAssertEqual(fx, vs)
    }
}

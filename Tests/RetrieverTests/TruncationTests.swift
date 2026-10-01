import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// UTF-8 截断（§3.1）：按字节、只在码点边界；单行序列化 ≤ 16 KB。
final class TruncationTests: XCTestCase {
    func decode(_ e: LineEncoder.Encoded, seq: Int64 = 9_007_199_254_740_991, oseq: Int64 = 9_007_199_254_740_991) throws -> ([String: Any], Int) {
        var full = LineEncoder.prefix(seq: seq, oseq: oseq)
        full.append(contentsOf: e.body.dropLast())
        // 物化 ctx 行时再插一个字段：上限也要容得下
        let withCtx = Segments.withCtx(full[...])
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(withCtx)) as? [String: Any])
        return (o, withCtx.count)
    }

    func testMsgCJKTruncatedAtCodePoint() throws {
        let msg = String(repeating: "日", count: 1400)   // 4200 B
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: msg))
        XCTAssertTrue(e.truncated)
        let (o, _) = try decode(e)
        let m = try XCTUnwrap(o["msg"] as? String)
        XCTAssertEqual(m.utf8.count, 4095)   // 1365 × 3 B，第 1366 个放不下
        XCTAssertEqual(o["truncated"] as? Bool, true)
        XCTAssertTrue(m.unicodeScalars.allSatisfy { $0 == "日" })
    }

    func testEmojiNotSplit() throws {
        let msg = "a" + String(repeating: "🐶", count: 1100)   // 1 + 4400 B
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: msg, tag: String(repeating: "🐱", count: 20)))
        let (o, _) = try decode(e)
        let m = try XCTUnwrap(o["msg"] as? String)
        XCTAssertEqual(m.utf8.count, 1 + 1023 * 4)
        XCTAssertEqual((o["tag"] as? String)?.utf8.count, 64)
        XCTAssertEqual((o["tag"] as? String)?.unicodeScalars.count, 16)
    }

    func testLoneSurrogateBecomesReplacementChar() throws {
        let broken = String(decoding: [0x61, 0xD83D, 0x62] as [UInt16], as: UTF16.self)
        XCTAssertEqual(broken.unicodeScalars.map(\.value), [0x61, 0xFFFD, 0x62])
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: broken))
        let (o, _) = try decode(e)
        XCTAssertEqual(o["msg"] as? String, "a\u{FFFD}b")
        XCTAssertEqual(Text.utf8Len("a\u{FFFD}b"), 5)
    }

    func testControlCharsEscapedLikeJSONStringify() {
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: "q\"b\\n\n t\t\u{1}\u{7f}/\u{2028}"))
        let s = String(decoding: e.body, as: UTF8.self)
        XCTAssertTrue(s.contains(#""msg":"q\"b\\n\n t\t\u0001"#), s)
        XCTAssertTrue(s.contains("\u{7f}/\u{2028}\""), s)
    }

    func testStackHeadAndTail() throws {
        let head = String(repeating: "h", count: 10_000)
        let tail = String(repeating: "t", count: 9_000) + "Caused by: IOError"
        let e = LineEncoder.encode(LogLine(ts: 1, level: .error, msg: "x", exc: LogException(type: "T", message: "m", stack: head + tail)))
        let (o, _) = try decode(e)
        let stack = try XCTUnwrap((o["exc"] as? [String: Any])?["stack"] as? String)
        XCTAssertLessThanOrEqual(stack.utf8.count, Limits.lineExcStackBytes)
        // 字段级：头 8 KB + 标记 + 尾（总长 ≤ 16 KB）
        let field = LineEncoder.headTail(head + tail)
        XCTAssertTrue(field.hasPrefix(String(repeating: "h", count: 8192) + "\n…[truncated]…\n"))
        XCTAssertEqual(field.utf8.count, Limits.lineExcStackBytes)
        // 行级：满额 stack 放不进 16 KB 的行，再按「头 + 标记 + 尾」收缩，尾部 `Caused by` 保住
        XCTAssertTrue(stack.hasPrefix(String(repeating: "h", count: 7900)))
        XCTAssertTrue(stack.contains("\n…[truncated]…\n"))
        XCTAssertTrue(stack.hasSuffix("Caused by: IOError"))
        XCTAssertEqual(o["truncated"] as? Bool, true)
    }

    func testExcFieldLimits() throws {
        let e = LineEncoder.encode(LogLine(ts: 1, level: .error, msg: "x",
                                           exc: LogException(type: String(repeating: "類", count: 100), message: String(repeating: "m", count: 2000))))
        let (o, _) = try decode(e)
        let exc = try XCTUnwrap(o["exc"] as? [String: Any])
        XCTAssertLessThanOrEqual((exc["type"] as? String ?? "").utf8.count, 256)
        XCTAssertEqual((exc["message"] as? String ?? "").utf8.count, 1024)
    }

    func testAttrsKeysAndBytesLimits() throws {
        var attrs: [String: AttrValue] = [:]
        for i in 0..<40 { attrs[String(format: "k%02d", i)] = .number(Double(i)) }
        attrs["inf"] = .number(.infinity)
        attrs["nan"] = .number(.nan)
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: "x", attrs: attrs))
        let (o, _) = try decode(e)
        let a = try XCTUnwrap(o["attrs"] as? [String: Any])
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(o["truncated"] as? Bool, true)
        // 非有限数转 string
        let e2 = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: "x", attrs: ["inf": .number(.infinity), "nan": .number(.nan), "n": .number(-.infinity)]))
        let a2 = try XCTUnwrap(try decode(e2).0["attrs"] as? [String: Any])
        XCTAssertEqual(a2["inf"] as? String, "Infinity")
        XCTAssertEqual(a2["nan"] as? String, "NaN")
        XCTAssertEqual(a2["n"] as? String, "-Infinity")
        // 序列化 ≤ 4096：贪心装入
        let big: [String: AttrValue] = ["a": .string(String(repeating: "x", count: 3000)), "b": .string(String(repeating: "y", count: 3000)), "c": .bool(true)]
        let (o3, _) = try decode(LineEncoder.encode(LogLine(ts: 1, level: .info, msg: "x", attrs: big)))
        let a3 = try XCTUnwrap(o3["attrs"] as? [String: Any])
        XCTAssertEqual(Set(a3.keys), ["a", "c"])
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: a3).count, 4096)
    }

    /// attrs 的值先截到预算再转义（ADR 0020 决定 3）：16 MB 的值不再整串转义（修复前约 0.5 s、数十 MB 分配）；
    /// 结果不变——装不下的键照样跳过并打 truncated，装得下的逐字节不变。
    func testHugeAttrValueBounded() throws {
        let huge = String(repeating: "\"", count: 16 * 1024 * 1024)
        let t0 = nowNs()
        let e = LineEncoder.encode(LogLine(ts: 1, level: .info, msg: "x", attrs: ["big": .string(huge), "ok": .bool(true)]))
        XCTAssertLessThan(elapsedMs(since: t0), 100, "只转义预算内的前缀")
        let (o, _) = try decode(e)
        XCTAssertEqual(o["attrs"] as? [String: Bool], ["ok": true])
        XCTAssertEqual(o["truncated"] as? Bool, true)
        let fits = String(repeating: "\"", count: 2000)
        let (j, t) = LineEncoder.encodeAttrs(["s": .string(fits)])
        XCTAssertFalse(t)
        XCTAssertEqual(j.map { String(decoding: $0, as: UTF8.self) }, "{\"s\":\"" + String(repeating: "\\\"", count: 2000) + "\"}")
    }

    /// `AttrValue.int`：安全范围内是 number（与 `.number(Double)` 逐字节相同），超出是十进制字符串；不新增 enum case。
    func testIntFactory() {
        XCTAssertEqual(AttrValue.int(42), .number(42))
        XCTAssertEqual(AttrValue.int(-9_007_199_254_740_991), .number(-9_007_199_254_740_991))
        XCTAssertEqual(AttrValue.int(9_007_199_254_740_992), .string("9007199254740992"))
        XCTAssertEqual(AttrValue.int(Int64.min), .string("-9223372036854775808"))
        XCTAssertEqual(AttrValue.int(Int64.max), .string("9223372036854775807"))
    }

    func testSerializedLineCapped16KB() throws {
        // attrs 4 KB + stack 16 KB（控制字符，转义 6 倍）+ msg 4 KB ASCII → 先删 attrs、再截 stack，msg 保住
        var attrs: [String: AttrValue] = [:]
        for i in 0..<8 { attrs["k\(i)"] = .string(String(repeating: "a", count: 450)) }
        let line = LogLine(ts: 1_790_668_800_000, level: .error, msg: String(repeating: "m", count: 4000),
                           tag: String(repeating: "t", count: 64), attrs: attrs,
                           exc: LogException(type: String(repeating: "T", count: 256), message: String(repeating: "\u{2}", count: 1024),
                                             stack: "HEAD" + String(repeating: "\u{3}", count: 20_000) + "Caused by: X"))
        let (o, n) = try decode(LineEncoder.encode(line))
        XCTAssertLessThanOrEqual(n, Limits.lineSerializedBytes)
        XCTAssertNil(o["attrs"], "attrs 先整个删掉")
        XCTAssertEqual(o["truncated"] as? Bool, true)
        XCTAssertEqual((o["msg"] as? String)?.utf8.count, 4000)
        let stack = try XCTUnwrap((o["exc"] as? [String: Any])?["stack"] as? String)
        XCTAssertTrue(stack.hasPrefix("HEAD"))
        XCTAssertTrue(stack.hasSuffix("Caused by: X"))

        // msg 本身转义后就超（4000 个控制字符 = 24 KB）→ stack 去掉后再截 msg
        let line2 = LogLine(ts: 1, level: .error, msg: String(repeating: "\u{1}", count: 4000),
                            exc: LogException(type: "T", message: "m", stack: String(repeating: "s", count: 5000)))
        let (o2, n2) = try decode(LineEncoder.encode(line2))
        XCTAssertLessThanOrEqual(n2, Limits.lineSerializedBytes)
        XCTAssertLessThan((o2["msg"] as? String)?.unicodeScalars.count ?? 0, 4000)
        XCTAssertEqual(o2["truncated"] as? Bool, true)
    }

    /// 与服务端逐字节核算：validator 的 JSON.stringify(行) ≤ 16384（含 ctx 字段与最大位数的 seq / oseq）。
    func testWorstCaseLinesFitServerLimit() throws {
        for msgChar in ["a", "\u{1}", "日", "🐶", "\""] {
            let line = LogLine(ts: 9_999_999_999_999, level: .fatal, msg: String(repeating: msgChar, count: 5000),
                               tag: String(repeating: msgChar, count: 100),
                               attrs: ["x": .string(String(repeating: msgChar, count: 5000))],
                               exc: LogException(type: String(repeating: msgChar, count: 300), message: String(repeating: msgChar, count: 2000),
                                                 stack: String(repeating: msgChar, count: 30_000)))
            let (_, n) = try decode(LineEncoder.encode(line, synthetic: true))
            XCTAssertLessThanOrEqual(n, Limits.lineSerializedBytes, msgChar)
        }
    }

    func testTruncateHelpers() {
        XCTAssertEqual(Text.truncate("abc", maxBytes: 2).0, "ab")
        XCTAssertEqual(Text.truncate("é", maxBytes: 1).0, "")
        XCTAssertEqual(Text.suffix("xyz日本", maxBytes: 4).utf8.count, 3)
        XCTAssertEqual(Text.sanitizeUserId("u\u{0}\u{85}1"), "u1")
        XCTAssertEqual(Text.sanitizeUserId(String(repeating: "用", count: 50))?.utf8.count, 126)
    }
}

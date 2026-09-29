import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// 写入纪律（宪法 R-1，方案 §3.3）。
final class WriteDisciplineTests: XCTestCase {
    func readSegment(_ path: String) -> [String] {
        // 用另一个 fd 直接读（不经 fsync）
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        var buf = [UInt8](repeating: 0, count: Int(st.st_size))
        _ = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, Int(st.st_size)) }
        return String(decoding: buf, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func testLineVisibleToOtherFdImmediately() throws {
        let h = Harness(key: "")
        let path = try XCTUnwrap(h.client.debugOpenSegmentPath)
        for i in 1...50 {
            h.client.log(i % 5 == 0 ? .warn : .info, "visible \(i)")
            let ls = readSegment(path)
            XCTAssertEqual(ls.count, i + 1, "header + \(i) lines")
            let last = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ls.last!.utf8)) as? [String: Any])
            XCTAssertEqual(int(last["seq"]), Int64(i))
            XCTAssertEqual(last["msg"] as? String, "visible \(i)")
            XCTAssertEqual(last["oseq"] != nil, i % 5 == 0)
        }
        // 段首行是 header
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(readSegment(path)[0].utf8)) as? [String: Any])
        XCTAssertEqual(int(header["v"]), 1)
        XCTAssertEqual(int(header["seg_no"]), 1)
        XCTAssertTrue(header["user_id"] is NSNull)
    }

    func testFieldOrderAndOptionalKeys() throws {
        let h = Harness(key: "")
        struct E: Error {}
        h.client.log(.error, "boom", tag: "net", attrs: ["b": .bool(true), "a": .number(1.5), "c": .string("x")], error: E())
        h.client.log(.debug, "plain")
        let ls = readSegment(try XCTUnwrap(h.client.debugOpenSegmentPath))
        XCTAssertTrue(ls[1].hasPrefix("{\"seq\":1,\"oseq\":1,\"ts\":"), ls[1])
        XCTAssertTrue(ls[1].contains("\"level\":\"error\",\"msg\":\"boom\",\"tag\":\"net\",\"attrs\":{\"a\":1.5,\"b\":true,\"c\":\"x\"},\"exc\":{\"type\":"), ls[1])
        XCTAssertFalse(ls[1].contains("\"stack\""))
        XCTAssertTrue(ls[2].hasPrefix("{\"seq\":2,\"ts\":"), ls[2])
        XCTAssertFalse(ls[2].contains("tag"))
        XCTAssertFalse(ls[2].contains("truncated"))
        let exc = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(ls[1].utf8)) as? [String: Any])?["exc"] as? [String: Any])
        XCTAssertTrue((exc["type"] as? String ?? "").hasSuffix("E"))
        let ns = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "offline"])
        let e2 = LineEncoder.exception(from: ns)
        XCTAssertEqual(e2.message, "NSURLErrorDomain (-1009): offline")
        XCTAssertNil(e2.stack)
    }

    func testRedactNilDoesNotConsumeSeq() {
        var o = Options()
        o.redact = { line in line.msg.contains("secret") ? nil : line }
        let h = Harness(key: "", options: o)
        h.client.log(.warn, "a")
        h.client.log(.warn, "secret token")
        h.client.log(.warn, "b")
        XCTAssertEqual(h.client.debugCounters.seq, 2)
        XCTAssertEqual(h.client.debugCounters.oseq, 2)
    }

    func testRedactCanRewriteAndReentrancyIgnored() throws {
        let box = ClientBox()
        var o = Options()
        o.redact = { line in
            box.client?.log(.error, "from inside redact")   // 重入：直接忽略
            var l = line
            l.msg = l.msg.replacingOccurrences(of: "pw=123", with: "pw=***")
            return l
        }
        let h = Harness(key: "", options: o)
        box.client = h.client
        h.client.log(.info, "login pw=123")
        XCTAssertEqual(h.client.debugCounters.seq, 1)
        let ls = readSegment(try XCTUnwrap(h.client.debugOpenSegmentPath))
        XCTAssertEqual(ls.count, 2)
        XCTAssertTrue(ls[1].contains("pw=***"))
    }

    func testLocalLevelFilterDoesNotConsumeSeq() {
        var o = Options()
        o.localLevel = .info
        let h = Harness(key: "", options: o)
        h.client.log(.debug, "dropped")
        h.client.log(.info, "kept")
        h.client.log(.debug, "dropped")
        XCTAssertEqual(h.client.debugCounters.seq, 1)
        XCTAssertEqual(h.client.debugCounters.oseq, 0)
    }

    func testSetEnabledFalseWritesNothing() {
        let h = Harness(key: "")
        h.client.setEnabled(false)
        h.client.log(.error, "nope")
        XCTAssertEqual(h.client.debugCounters.seq, 0)
        h.client.setEnabled(true)
        h.client.log(.error, "yes")
        XCTAssertEqual(h.client.debugCounters.seq, 1)
    }

    func testWriteFailureRecordsTombstoneAndNeverThrows() async throws {
        let h = Harness(key: "")
        h.client.log(.warn, "ok 1")
        // 模拟写失败：把当前段 fd 换成只读（write 返回 EBADF）
        let path = try XCTUnwrap(h.client.debugOpenSegmentPath)
        h.client.writer.debugBreakFd()
        h.client.log(.warn, "lost 2")
        h.client.log(.warn, "lost 3")
        h.client.log(.info, "lost, no oseq")
        XCTAssertEqual(h.client.debugCounters.seq, 4)
        XCTAssertEqual(h.client.debugCounters.oseq, 3)
        await h.work { $0.flushTombstones() }
        let drops = h.readJSONL("drops.jsonl")
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?["reason"] as? String, "write_failed")
        XCTAssertEqual(int(drops.first?["oseq_from"]), 2)
        XCTAssertEqual(int(drops.first?["oseq_to"]), 3)
        XCTAssertEqual(int(drops.first?["n"]), 2)
        XCTAssertEqual(int(drops.first?["last_ack_age_ms"]), -1)
        // 段文件里没有半行
        let ls = readSegment(path)
        XCTAssertEqual(ls.count, 2)
    }

    func testConcurrentLoggingKeepsSeqUnique() throws {
        let h = Harness(key: "")
        let c = h.client
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<500 { c.log(i % 3 == 0 ? .warn : .debug, "t\(t) i\(i)") }
        }
        XCTAssertEqual(c.debugCounters.seq, 4000)
        let dir = h.sessionDir()
        var seqs: [Int64] = []
        var oseqs: [Int64] = []
        for n in try FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ $0.hasPrefix("seg-") }).sorted() {
            for (i, l) in readSegment(dir.appendingPathComponent(n).path).enumerated() where i > 0 {
                let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
                seqs.append(int(o["seq"]))
                if let x = o["oseq"] as? NSNumber { oseqs.append(x.int64Value) }
            }
        }
        XCTAssertEqual(seqs, Array(1...4000))
        XCTAssertEqual(oseqs, Array(1...Int64(oseqs.count)))
    }
}

final class ClientBox: @unchecked Sendable {
    var client: RetrieverClient?
}

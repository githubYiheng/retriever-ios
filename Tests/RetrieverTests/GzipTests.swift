import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// gzip：标准 gunzip 能解开且为单段、无尾随字节（否则服务端按损坏隔离）。
final class GzipTests: XCTestCase {
    func run(_ exe: String, _ args: [String]) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, d)
    }

    func testSystemGunzipAcceptsSingleMember() throws {
        var input = [UInt8]()
        for i in 0..<200_000 { input.append(UInt8(truncatingIfNeeded: (i * 31) ^ (i >> 3))) }
        input.append(contentsOf: Array("日志🐶 {\"seq\":1}".utf8))
        let gz = try XCTUnwrap(Gzip.compress(input))
        XCTAssertEqual(Array(gz.prefix(3)), [0x1F, 0x8B, 0x08])
        // ISIZE = 原长 mod 2^32（小端），且就在文件末尾（无尾随字节）
        let isize = gz.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        XCTAssertEqual(isize, UInt32(input.count))
        let url = makeTempDir("rtv-gz").appendingPathComponent("b.gz")
        try Data(gz).write(to: url)
        XCTAssertEqual(try run("/usr/bin/gunzip", ["-t", url.path]).0, 0)
        let (st, out) = try run("/usr/bin/gunzip", ["-c", url.path])
        XCTAssertEqual(st, 0)
        XCTAssertEqual([UInt8](out), input)
        XCTAssertEqual(Gzip.decompress(gz), input)
        // 严格解压：多一个成员或尾随字节都拒绝
        XCTAssertNil(Gzip.decompress(gz + gz))
        XCTAssertNil(Gzip.decompress(gz + [0]))
        XCTAssertEqual(Gzip.compress([]).flatMap { Gzip.decompress($0) }, [])
    }

    func testOutboxFileIsExactRequestBodyAndGunzipClean() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .status(503, nil, [:])
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        let name = try XCTUnwrap(h.outboxFiles().first)
        let url = h.outbox.appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: url), h.transport.batchRequests.first?.body, "文件字节即请求体")
        XCTAssertEqual(try run("/usr/bin/gunzip", ["-t", url.path]).0, 0)
        // 重试原样重发
        await h.tick(advance: 5000)
        XCTAssertEqual(h.transport.batchRequests.count, 2)
        XCTAssertEqual(h.transport.batchRequests[0].body, h.transport.batchRequests[1].body)
    }
}

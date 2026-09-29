import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// `retry_after_s` 的解析必须饱和：巨大 / 负数 / 非数字都不能让 `Int(v)` trap（Android 子代理复核发现）。
final class RetryAfterTests: XCTestCase {
    func testSaturatesHugeAndNegative() {
        XCTAssertEqual(Engine.retryAfter(body: ["retry_after_s": 1e300], header: nil), 86_400)
        XCTAssertEqual(Engine.retryAfter(body: ["retry_after_s": -5.0], header: nil), 0)
        XCTAssertEqual(Engine.retryAfter(body: ["retry_after_s": 42.9], header: nil), 42)
        XCTAssertEqual(Engine.retryAfter(body: nil, header: "99999999999999999999"), nil)
        XCTAssertEqual(Engine.retryAfter(body: nil, header: " 30 "), 30)
        XCTAssertEqual(Engine.retryAfter(body: ["retry_after_s": Double.infinity], header: "7"), 7)
    }
}

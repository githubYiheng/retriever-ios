import Foundation
import XCTest
@_spi(RetrieverTesting) import Retriever

/// 记录适配器交给 Retriever 的调用。
final class Recorder: @unchecked Sendable {
    struct Call {
        var level: LogLevel
        var msg: String
        var tag: String?
        var attrs: [String: AttrValue]?
        var error: (any Error)?
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func add(_ c: Call) { lock.lock(); _calls.append(c); lock.unlock() }
}

final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: LogLevel = .debug
    var level: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _level }
        set { lock.lock(); _level = newValue; lock.unlock() }
    }
}

struct NullTransport: Transport {
    func send(_ request: HTTPRequest) async -> HTTPResponse? { nil }
    func cancelAll() {}
}

struct NullPlatform: PlatformHooks {
    func deviceFields() -> [String: String] {
        ["os": "macos", "os_version": "26.0", "model": "adapter-test", "app_version": "1.0", "build": "1", "locale": "en_US"]
    }
    func isForeground() -> Bool? { true }
    func beginBackgroundTask(name: String, onExpire: @escaping @Sendable () -> Void) -> Int? { nil }
    func endBackgroundTask(_ token: Int) {}
    func startObserving(_ sink: any PlatformEventSink) {}
    func isExpensiveNetwork() -> Bool { false }
    func availableBytes(at url: URL) -> Int64? { nil }
}

/// 真实实例（临时目录、不联网），验证适配器输出经 SDK 截断后的落盘结果。
func makeClient() -> RetrieverClient {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtv-adapter-\(UUID().uuidString.prefix(8))")
    return RetrieverClient(root: root, key: "", baseURL: URL(string: "https://invalid.example")!, options: Options(),
                           clock: SystemClock(), transport: NullTransport(), platform: NullPlatform())
}

/// 当前段里的行（不含 header）。
func segmentLines(_ c: RetrieverClient) throws -> [[String: Any]] {
    let path = try XCTUnwrap(c.debugOpenSegmentPath)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(separator: "\n").dropFirst().map {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

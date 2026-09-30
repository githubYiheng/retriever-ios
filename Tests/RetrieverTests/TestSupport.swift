import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

// MARK: 路径

enum Repo {
    /// 仓库根：本文件在 <repo>/sdk/ios/Tests/RetrieverTests/TestSupport.swift
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func golden(_ name: String) throws -> [String: Any] {
        let url = root.appendingPathComponent("packages/core/golden/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }
}

func makeTempDir(_ tag: String = "rtv") -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: 假时钟

final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64
    private var mono: Int64

    init(wall: Int64 = 1_790_668_800_000, mono: Int64 = 1_000_000) {
        self.wall = wall
        self.mono = mono
    }

    func wallMs() -> Int64 { lock.lock(); defer { lock.unlock() }; return wall }
    func monoMs() -> Int64 { lock.lock(); defer { lock.unlock() }; return mono }

    func advance(_ ms: Int64) {
        lock.lock()
        wall += ms
        mono += ms
        lock.unlock()
    }

    /// 流程内等待：直接推进假时间。
    func sleep(ms: Int64) async { advance(max(ms, 0)) }

    /// 调度器睡眠：永不自己醒（测试手动 tick），被取消时抛错。
    func timerSleep(ms: Int64) async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: 假传输

final class FakeTransport: Transport, @unchecked Sendable {
    enum Reply {
        case echo                                   // 200 回显本批 batch_id
        case echoWrong                              // 200 回显别的 batch_id
        case status(Int, [String: Any]?, [String: String])
        case network                                // 网络错误
        case hang                                   // 挂起直到 cancelAll
    }

    private let lock = NSLock()
    var script: [Reply] = []
    var defaultReply: Reply = .echo
    /// 按批决定回复（优先于 script）。
    var responder: ((String) -> Reply?)?
    var configBody: [String: Any]?
    var configEtag = "etag-0"
    private(set) var requests: [HTTPRequest] = []
    private(set) var cancelCount = 0
    private var hanging: [CheckedContinuation<HTTPResponse?, Never>] = []

    func setScript(_ s: [Reply]) { lock.lock(); script = s; lock.unlock() }

    var batchRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url.path.hasSuffix("/v1/batches") }
    }

    var configRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url.path.hasSuffix("/v1/config") }
    }

    var hangingCount: Int { lock.lock(); defer { lock.unlock() }; return hanging.count }

    private func decide(_ request: HTTPRequest) -> (Reply?, [String: Any]?, String, String?) {
        lock.withLock {
            requests.append(request)
            if request.url.path.hasSuffix("/v1/config") { return (nil, configBody, configEtag, nil) }
            let bid = FakeTransport.batchId(request.body)
            var reply: Reply
            if let r = responder, let x = r(bid ?? "") { reply = x }
            else if !script.isEmpty { reply = script.removeFirst() }
            else { reply = defaultReply }
            return (reply, nil, configEtag, bid)
        }
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse? {
        let (reply, cfg, etag, bid) = decide(request)
        guard let reply else {
            guard let cfg else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: json(cfg))
        }
        switch reply {
        case .echo:
            return HTTPResponse(status: 200, body: json(["batch_id": bid ?? "", "status": "stored", "config_etag": etag]))
        case .echoWrong:
            return HTTPResponse(status: 200, body: json(["batch_id": "00000000-0000-4000-8000-000000000000", "status": "stored", "config_etag": etag]))
        case .status(let code, let body, let headers):
            return HTTPResponse(status: code, headers: headers, body: body.map(json) ?? Data())
        case .network:
            return nil
        case .hang:
            return await withCheckedContinuation { c in
                lock.withLock { hanging.append(c) }
            }
        }
    }

    func cancelAll() {
        lock.lock()
        cancelCount += 1
        let h = hanging
        hanging = []
        lock.unlock()
        for c in h { c.resume(returning: nil) }
    }

    private func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    static func batchId(_ body: Data?) -> String? {
        guard let body, let env = decodeEnvelope(body) else { return nil }
        return env["batch_id"] as? String
    }
}

func decodeEnvelope(_ gz: Data) -> [String: Any]? {
    guard let raw = Gzip.decompress([UInt8](gz)) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any]
}

// MARK: 假平台

final class FakePlatform: PlatformHooks, @unchecked Sendable {
    private let lock = NSLock()
    var available: Int64? = nil
    var foreground = true
    private(set) var begun: [Int] = []
    private(set) var ended: [Int] = []
    private var expirations: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 7

    func deviceFields() -> [String: String] {
        ["os": "macos", "os_version": "26.0", "model": "Mac-test", "app_version": "1.2.3", "build": "45", "locale": "zh_CN"]
    }
    func isForeground() -> Bool? { foreground }
    func beginBackgroundTask(name: String, onExpire: @escaping @Sendable () -> Void) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let t = nextToken
        nextToken += 1
        begun.append(t)
        expirations[t] = onExpire
        return t
    }
    func endBackgroundTask(_ token: Int) {
        lock.lock(); ended.append(token); lock.unlock()
    }
    func expire(_ token: Int) {
        lock.lock(); let f = expirations[token]; lock.unlock()
        f?()
    }
    var endedTokens: [Int] { lock.lock(); defer { lock.unlock() }; return ended }
    var begunTokens: [Int] { lock.lock(); defer { lock.unlock() }; return begun }
    func startObserving(_ sink: any PlatformEventSink) {}
    func availableBytes(at url: URL) -> Int64? { available }
}

// MARK: 测试夹具

final class Harness {
    let root: URL
    let clock: FakeClock
    let transport: FakeTransport
    let platform: FakePlatform
    var client: RetrieverClient

    init(root: URL? = nil, key: String = "lk_test_demo_abc_12345678", options: Options = Options(),
         clock: FakeClock = FakeClock(), transport: FakeTransport = FakeTransport(), platform: FakePlatform = FakePlatform()) {
        self.root = root ?? makeTempDir()
        self.clock = clock
        self.transport = transport
        self.platform = platform
        client = RetrieverClient(root: self.root, key: key, baseURL: URL(string: "https://logs-test.invalid")!, options: options,
                                 clock: clock, transport: transport, platform: platform)
    }

    var engine: Engine { client.engine }
    var outbox: URL { root.appendingPathComponent("outbox") }

    func settle() async { await client.settle() }

    /// 立即封当前段并处理（不走定时器）。
    func seal(_ reason: SealReason = .timer) async {
        client.writer.rotate(reason)
        let c = client
        await c.onWork { _ = c.engine.processSeals() }
        await settle()
    }

    /// 封当前段并按正常路径触发排空（封段是排空触发点之一）。
    func sealAndDrain(_ reason: SealReason = .timer) async {
        client.writer.rotate(reason)
        let c = client
        await c.onWork { c.afterSeal() }
        await settle()
    }

    func tick(advance ms: Int64 = 0) async {
        if ms > 0 { clock.advance(ms) }
        await client.tickNow()
    }

    func enableUpload(_ key: String = "lk_test_demo_abc_12345678", options: Options = Options()) async {
        client.reconfigure(key: key, baseURL: URL(string: "https://logs-test.invalid")!, options: options)
        await settle()
    }

    func work<T: Sendable>(_ body: @escaping @Sendable (Engine) -> T) async -> T {
        let c = client
        return await c.onWork { body(c.engine) }
    }

    func outboxFiles(_ prefix: String? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? [])
            .filter { $0.hasSuffix(".gz") && (prefix == nil || $0.hasPrefix(prefix!)) }
            .sorted()
    }

    func envelopes(_ prefix: String? = nil) -> [(String, [String: Any])] {
        outboxFiles(prefix).compactMap { n in
            guard let d = try? Data(contentsOf: outbox.appendingPathComponent(n)), let e = decodeEnvelope(d) else { return nil }
            return (n, e)
        }
    }

    func readJSONL(_ name: String) -> [[String: Any]] {
        guard let s = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func sessionDir(_ client: RetrieverClient? = nil) -> URL {
        let c = client ?? self.client
        return root.appendingPathComponent("proc-main").appendingPathComponent(c.writer.currentSessionId)
    }

    func log(_ level: LogLevel, _ msg: String, count: Int = 1, pad: Int = 0) {
        for i in 0..<count {
            client.log(level, count > 1 ? "\(msg) \(i)" + String(repeating: "p", count: pad) : msg + String(repeating: "p", count: pad))
        }
    }
}

func lines(of env: [String: Any]) -> [[String: Any]] { (env["lines"] as? [[String: Any]]) ?? [] }
func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? -999 }

/// 跨语言校验：把信封 JSON 写成文件，跑 `npx tsx packages/core/scripts/validate-envelope.ts <files>`（cwd = 仓库根）。
func runValidator(_ envelopes: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
    let dir = makeTempDir("rtv-validate")
    var paths: [String] = []
    for (i, e) in envelopes.enumerated() {
        let p = dir.appendingPathComponent("env-\(i).json")
        try JSONSerialization.data(withJSONObject: e).write(to: p)
        paths.append(p.path)
    }
    return try runValidatorFiles(paths)
}

func runValidatorFiles(_ paths: [String]) throws -> [[String: Any]] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["npx", "--no-install", "tsx", "packages/core/scripts/validate-envelope.ts"] + paths
    p.currentDirectoryURL = Repo.root
    var env = ProcessInfo.processInfo.environment
    let extra = [env["NVM_BIN"], "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
    env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
    p.environment = env
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let results = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    if results.count != paths.count {
        XCTFail("validator output mismatch: \(text) \(String(decoding: errData, as: UTF8.self))")
    }
    return results
}

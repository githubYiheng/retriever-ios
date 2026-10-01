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

    private var timerSleeps: [Int64] = []

    /// 调度器请求过的睡眠时长（断言调度地板用）。
    var timerSleepRequests: [Int64] { lock.lock(); defer { lock.unlock() }; return timerSleeps }

    /// 调度器睡眠：永不自己醒（测试手动 tick），被取消时抛错。
    func timerSleep(ms: Int64) async throws {
        lock.withLock { timerSleeps.append(ms) }
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
        case raw(Int, Data, [String: String])       // 任意响应体（HTML 等）
        case network                                // 网络错误
        case hang                                   // 挂起直到 cancelAll
        case heldConfig                             // 配置请求挂起直到 releaseHeldConfigs（按请求时刻的 configBody 回 200）
        case heldStatus(Int, [String: Any]?)        // 批请求挂起直到 releaseHeldBatches，届时回该状态与响应体（在途请求竞态）
    }

    private let lock = NSLock()
    var script: [Reply] = []
    var defaultReply: Reply = .echo
    /// 按批决定回复（优先于 script）。
    var responder: ((String) -> Reply?)?
    var configBody: [String: Any]?
    var configEtag = "etag-0"
    /// 配置请求挂起直到 cancelAll（拉配置在途）。
    var configHang = false
    /// 配置请求挂起直到 releaseHeldConfigs()，届时按请求时刻的 configBody 回 200（身份切换竞态）。
    var configHold = false
    /// 回显模式（与 ingest 一致，ADR 0022）：configBody 当作合并后的远程文档，没有有效值的四个宿主型字段按请求头补齐，
    /// 并给出 `from_host`。
    var configEcho = false
    private(set) var requests: [HTTPRequest] = []
    private(set) var cancelCount = 0
    private var hanging: [CheckedContinuation<HTTPResponse?, Never>] = []
    private var held: [(CheckedContinuation<HTTPResponse?, Never>, [String: Any]?)] = []
    private var heldBatches: [(CheckedContinuation<HTTPResponse?, Never>, HTTPResponse)] = []

    func setScript(_ s: [Reply]) { lock.lock(); script = s; lock.unlock() }

    var heldBatchCount: Int { lock.lock(); defer { lock.unlock() }; return heldBatches.count }

    /// 放行 heldStatus 挂住的批请求：各自回预定的状态与响应体。
    func releaseHeldBatches() {
        lock.lock()
        let h = heldBatches
        heldBatches = []
        lock.unlock()
        for (c, r) in h { c.resume(returning: r) }
    }

    var batchRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url.path.hasSuffix("/v1/batches") }
    }

    var configRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url.path.hasSuffix("/v1/config") }
    }

    var hangingCount: Int { lock.lock(); defer { lock.unlock() }; return hanging.count }
    var heldConfigCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    /// 放行 configHold 挂住的配置请求：各自回请求时刻的 configBody。
    func releaseHeldConfigs() {
        lock.lock()
        let h = held
        held = []
        lock.unlock()
        for (c, cfg) in h {
            c.resume(returning: cfg.map { HTTPResponse(status: 200, body: json($0)) } ?? HTTPResponse(status: 404))
        }
    }

    private func decide(_ request: HTTPRequest) -> (Reply?, [String: Any]?, String, String?) {
        lock.withLock {
            requests.append(request)
            if request.url.path.hasSuffix("/v1/config") {
                let body = configEcho ? FakeTransport.echo(configBody ?? [:], request.headers) : configBody
                return (configHold ? .heldConfig : (configHang ? .hang : nil), body, configEtag, nil)
            }
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
        case .raw(let code, let body, let headers):
            return HTTPResponse(status: code, headers: headers, body: body)
        case .network:
            return nil
        case .hang:
            return await withCheckedContinuation { c in
                lock.withLock { hanging.append(c) }
            }
        case .heldConfig:
            return await withCheckedContinuation { c in
                lock.withLock { held.append((c, cfg)) }
            }
        case .heldStatus(let code, let body):
            let r = HTTPResponse(status: code, body: body.map(json) ?? Data())
            return await withCheckedContinuation { c in
                lock.withLock { heldBatches.append((c, r)) }
            }
        }
    }

    func cancelAll() {
        lock.lock()
        cancelCount += 1
        let h = hanging + held.map(\.0) + heldBatches.map(\.0)
        hanging = []
        held = []
        heldBatches = []
        lock.unlock()
        for c in h { c.resume(returning: nil) }
    }

    private func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    /// ingest 的回显：宿主型字段没有有效值时取请求头里的宿主默认（`hostDefaults` + `mergeConfigWithProvenance`）。
    static func echo(_ raw: [String: Any], _ h: [String: String]) -> [String: Any] {
        var out = raw
        let derived = ConfigRules.hostDerivedFields(raw)
        for f in derived {
            switch f {
            case "upload_level": out[f] = h["X-Rtv-Upload-Level"] ?? "warn"
            case "local_level": out[f] = h["X-Rtv-Local-Level"] ?? "debug"
            case "local_cap_bytes": out[f] = Int(h["X-Rtv-Local-Cap-Bytes"] ?? "") ?? Limits.localCapBytesDefault
            case "daily_batch_cap": out[f] = Int(h["X-Rtv-Daily-Batch-Cap"] ?? "") ?? 0
            default: break
            }
        }
        out["from_host"] = derived
        return out
    }

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

    /// 当前 OPEN 段里的行（不含 header）。
    func openSegmentLines() -> [[String: Any]] {
        guard let p = client.debugOpenSegmentPath, let s = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").dropFirst().compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func json(_ name: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func log(_ level: LogLevel, _ msg: String, count: Int = 1, pad: Int = 0) {
        for i in 0..<count {
            client.log(level, count > 1 ? "\(msg) \(i)" + String(repeating: "p", count: pad) : msg + String(repeating: "p", count: pad))
        }
    }
}

/// 线程安全的一次性标志 / 盒子（回调里记下值，测试线程读）。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
}

/// 真实时间（毫秒），量宿主线程上的调用耗时。
func elapsedMs(since t0: UInt64) -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6 }
func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// 把实例的 work 队列堵住（模拟引擎忙：冷启动恢复、驱逐……），返回放行函数；最长堵 seconds 秒兜底。
func blockWork(_ c: RetrieverClient, seconds: Double = 3) async -> @Sendable () -> Void {
    let gate = DispatchSemaphore(value: 0)
    let entered = Box<Bool>()
    c.work.async {
        entered.set(true)
        _ = gate.wait(timeout: .now() + seconds)
    }
    await waitFor { entered.value == true }
    return { gate.signal() }
}

/// purgeLocal 并等它的完成回调；返回回调里读到的 installId。
@discardableResult
func purgeAndWait(_ c: RetrieverClient) async -> String? {
    await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
        c.purgeLocal { k.resume(returning: c.installId) }
    }
}

/// root 同级的禁用标记 / 清空残留。
func disabledMarker(_ root: URL) -> URL { Engine.sibling(of: root, suffix: ".disabled") }
func purgeSiblings(_ root: URL) -> [String] {
    FS.list(root.deletingLastPathComponent()).filter { $0.hasPrefix(root.lastPathComponent + ".purge-") }
}

/// 等后台任务（detached Task）达成条件：最长约 5 s 真实时间（与 Android 同类等待一致，负载高时不偶发），不推进假时钟。
func waitFor(_ cond: () -> Bool) async {
    var n = 0
    while !cond() && n < 2500 {
        try? await Task.sleep(nanoseconds: 2_000_000)
        n += 1
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

// MARK: 共享入口夹具（静态 `Retriever.*` 的实现，ADR 0023）

/// 走共享入口（`SharedClient`）：configure 之前没有实例，只有 pre 文件。root = base/<appGroup ?? "default">。
final class SharedHarness {
    let base: URL
    let clock: FakeClock
    let transport: FakeTransport
    let platform: FakePlatform
    let shared: SharedClient
    static let key = "lk_test_demo_abc_12345678"
    static let url = URL(string: "https://logs-test.invalid")!

    init(base: URL? = nil, clock: FakeClock = FakeClock(), transport: FakeTransport = FakeTransport(),
         platform: FakePlatform = FakePlatform()) {
        let b = base ?? makeTempDir("rtv-shared")
        self.base = b
        self.clock = clock
        self.transport = transport
        self.platform = platform
        let t = transport
        shared = SharedClient(rootFor: { b.appendingPathComponent($0 ?? "default") }, clock: clock, platform: platform,
                              transport: { t })
    }

    var defaultRoot: URL { base.appendingPathComponent("default") }
    var preDir: URL { defaultRoot.appendingPathComponent("pre") }
    var client: RetrieverClient { shared.instanceForTesting! }

    func configure(key: String = SharedHarness.key, _ edit: (inout Options) -> Void = { _ in }) {
        var o = Options()
        edit(&o)
        shared.configure(key: key, baseURL: SharedHarness.url, options: o)
    }

    func settle() async { if let c = shared.instanceForTesting { await c.settle() } }

    func preFiles() -> [String] { FS.list(preDir).filter { $0.hasSuffix(".jsonl") }.sorted() }

    /// 某个 root 下某进程目录里全部会话（按 session_no）。
    func sessions(_ root: URL? = nil, process: String = "main") -> [(sid: String, meta: [String: Any])] {
        let p = (root ?? defaultRoot).appendingPathComponent("proc-\(process)")
        return FS.list(p).filter(IDs.isUuid).compactMap { sid -> (String, [String: Any])? in
            guard let d = try? Data(contentsOf: p.appendingPathComponent(sid).appendingPathComponent("meta.json")),
                  let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            return (sid, m)
        }.sorted { int($0.1["session_no"]) < int($1.1["session_no"]) }
    }

    func outboxFiles(_ root: URL? = nil) -> [String] {
        FS.list((root ?? defaultRoot).appendingPathComponent("outbox")).filter { $0.hasSuffix(".gz") }.sorted()
    }

    func envelopes(_ root: URL? = nil) -> [[String: Any]] {
        let o = (root ?? defaultRoot).appendingPathComponent("outbox")
        return outboxFiles(root).compactMap { n in (try? Data(contentsOf: o.appendingPathComponent(n))).flatMap(decodeEnvelope) }
    }
}

/// 会话目录里全部段的行（不含段头），按段号、行序。
func segmentLines(_ dir: URL) -> [[String: Any]] {
    FS.list(dir).compactMap { n -> (Int, String)? in Segments.parseName(n).map { ($0.0, n) } }.sorted { $0.0 < $1.0 }
        .flatMap { (_, n) -> [[String: Any]] in
            guard let s = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) else { return [] }
            return s.split(separator: "\n").dropFirst()
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
}

/// 会话目录里各段的段头。
func segmentHeaders(_ dir: URL) -> [[String: Any]] {
    FS.list(dir).compactMap { n -> (Int, String)? in Segments.parseName(n).map { ($0.0, n) } }.sorted { $0.0 < $1.0 }
        .compactMap { (_, n) -> [String: Any]? in
            guard let s = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8),
                  let first = s.split(separator: "\n").first else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any]
        }
}

/// pre 文件的原始记录行。
func preRecords(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

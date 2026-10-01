// 只给测试用（真杀进程验收 R-1，方案 §3.11）：用给定 root 写 N 行（含 warn / error），
// 可选在最后写半行（模拟撕裂的 write）或一条 fatal（封段物化只投递到后台，ADR 0020），然后立刻 SIGKILL 自己——不给任何收尾机会。
//
//   RetrieverKillHelper --root <dir> [--n 5000] [--torn] [--fatal] [--process main]
import Foundation
@_spi(RetrieverTesting) import Retriever

struct NoTransport: Transport {
    func send(_ request: HTTPRequest) async -> HTTPResponse? { nil }
    func cancelAll() {}
}

struct HeadlessPlatform: PlatformHooks {
    func deviceFields() -> [String: String] {
        ["os": "macos", "os_version": "26.0", "model": "helper", "app_version": "1.0.0", "build": "1", "locale": "en_US"]
    }
    func isForeground() -> Bool? { true }
    func beginBackgroundTask(name: String, onExpire: @escaping @Sendable () -> Void) -> Int? { nil }
    func endBackgroundTask(_ token: Int) {}
    func startObserving(_ sink: any PlatformEventSink) {}
    func availableBytes(at url: URL) -> Int64? { nil }
}

var root: String?
var n = 5000
var torn = false
var fatal = false
var process = "main"
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--root": root = args.next()
    case "--n": n = Int(args.next() ?? "") ?? n
    case "--torn": torn = true
    case "--fatal": fatal = true
    case "--process": process = args.next() ?? process
    default: break
    }
}
guard let root else {
    FileHandle.standardError.write("usage: RetrieverKillHelper --root <dir> [--n N] [--torn] [--fatal]\n".data(using: .utf8)!)
    exit(2)
}

var options = Options()
options.processName = process
// key 为空：不上传（不联网），只验证落盘与恢复
let client = RetrieverClient(root: URL(fileURLWithPath: root), key: "", baseURL: URL(string: "https://invalid.example")!,
                             options: options, clock: SystemClock(), transport: NoTransport(), platform: HeadlessPlatform())
for i in 1...n {
    let level: LogLevel
    if i % 1000 == 0 { level = .error } else if i % 10 == 0 { level = .warn } else if i % 2 == 0 { level = .info } else { level = .debug }
    client.log(level, "line \(i) " + String(repeating: "x", count: 64), tag: "kill", attrs: ["i": .number(Double(i))])
}
if torn, let path = client.debugOpenSegmentPath {
    // 模拟撕裂：下一行只写一半（前缀在同一次 write 里先写，所以能认出 seq / oseq）
    let c = client.debugCounters
    let half = "{\"seq\":\(c.seq + 1),\"oseq\":\(c.oseq + 1),\"ts\":1,\"level\":\"warn\",\"msg\":\"to"
    let fd = open(path, O_WRONLY | O_APPEND)
    _ = half.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}
if fatal {
    // log() 返回时这一行已交给内核；紧接着被杀，后台的封段物化来不及也不丢
    client.log(.fatal, "fatal line", tag: "kill")
}
// 输出计数给测试核对，然后自杀
let c = client.debugCounters
print("seq=\(c.seq) oseq=\(c.oseq)")
fflush(stdout)
kill(getpid(), SIGKILL)

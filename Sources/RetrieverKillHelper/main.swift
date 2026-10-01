// 只给测试用（真杀进程验收 R-1，方案 §3.11）：用给定 root 写 N 行（含 warn / error），
// 可选在最后写半行（模拟撕裂的 write）或一条 fatal（封段物化只投递到后台，ADR 0020），然后立刻 SIGKILL 自己——不给任何收尾机会。
//
//   RetrieverKillHelper --root <dir> [--n 5000] [--torn] [--fatal] [--process main]
//
// configure 之前 / 收编中途被杀（ADR 0023；简报 §11 D / E）：走共享入口（root 注入），configure 之前写 N 行（debug / info / warn /
// error 混合；--user 时第 N/2 行之前 setUser），然后
//   --preconfigure                 不 configure，直接 SIGKILL（pre 文件成为孤儿）；
//   --adopt-crash <point>          configure(key "")，在收编的 <point>（adopt_begin | adopt_mid | adopt_before_commit |
//                                  adopt_after_commit）SIGKILL；
//   --adopt-hold-write <m>         configure(key "")，收编停在 adopt_mid 时宿主再写 m 行（r = 1，进 pre 文件），然后 SIGKILL。
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
var preconfigure = false
var adoptCrash: String?
var user: String?
var holdWrite: Int?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--root": root = args.next()
    case "--n": n = Int(args.next() ?? "") ?? n
    case "--torn": torn = true
    case "--fatal": fatal = true
    case "--process": process = args.next() ?? process
    case "--preconfigure": preconfigure = true
    case "--adopt-crash": adoptCrash = args.next()
    case "--user": user = args.next()
    case "--adopt-hold-write": holdWrite = Int(args.next() ?? "")
    default: break
    }
}
guard let root else {
    FileHandle.standardError.write("usage: RetrieverKillHelper --root <dir> [--n N] [--torn] [--fatal]\n".data(using: .utf8)!)
    exit(2)
}

if preconfigure || adoptCrash != nil || holdWrite != nil {
    let r = URL(fileURLWithPath: root)
    let shared = SharedClient(rootFor: { _ in r }, clock: SystemClock(), platform: HeadlessPlatform(), transport: { NoTransport() })
    for i in 1...n {
        if let u = user, i == n / 2 { shared.setUser(u) }
        let level: LogLevel
        if i % 50 == 0 { level = .error } else if i % 10 == 0 { level = .warn } else if i % 2 == 0 { level = .info } else { level = .debug }
        shared.log(level, "pre \(i)", tag: "kill", attrs: ["i": .number(Double(i))])
    }
    print("lines=\(n)")
    fflush(stdout)
    if let m = holdWrite {
        let entered = DispatchSemaphore(value: 0)
        RetrieverTestHooks.setAdoptionHook { p in
            if p == "adopt_mid" {
                entered.signal()
                while true { pause() }     // 收编停在这里，直到进程被杀
            }
        }
        shared.configure(key: "", baseURL: URL(string: "https://invalid.example")!, options: Options())
        guard entered.wait(timeout: .now() + 10) == .success else { exit(4) }
        for i in 1...m { shared.log(i % 5 == 0 ? .warn : .info, "post \(i)", tag: "kill") }
        print("post=\(m)")
        fflush(stdout)
        kill(getpid(), SIGKILL)
        while true { pause() }
    }
    if let point = adoptCrash {
        RetrieverTestHooks.setAdoptionHook { p in
            // 对自己发 SIGKILL 是异步送达的：kill() 返回后本线程还能再跑几条指令（可能恰好 unlink 提交）。
            // 发完就把这个线程停住，崩溃点才确定
            if p == point {
                kill(getpid(), SIGKILL)
                while true { pause() }
            }
        }
        var o = Options()
        o.processName = process
        shared.configure(key: "", baseURL: URL(string: "https://invalid.example")!, options: o)
        // 收编在引擎线程上跑，走到 <point> 就被杀；等不到说明钩子没触发
        Thread.sleep(forTimeInterval: 10)
        exit(3)
    }
    kill(getpid(), SIGKILL)
    while true { pause() }     // 送达是异步的：别往下走到建实例
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

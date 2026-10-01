import Foundation
#if canImport(Darwin)
import Darwin
#endif

// configure 之前的 pre 文件（ADR 0023；简报 §1.1）：`<默认 root>/pre/<uuid>.jsonl`，本进程一个，进程内首次写时创建并持 flock
// （持锁 = 写它的进程还活着）。每条记录一行 JSON、一次 write(2) 追加：
//   头记录    {"pre":1,"started_ms":N,"process":"…","device":{os,os_version,model,app_version,build,locale,sdk}}
//   用户切换  {"pre_user":"<清洗后的 id>"} | {"pre_user":null}
//   行记录    {"r":0,"ts":…}   ← `{"r":0,` + 行体（LineEncoder 的 `"ts":…}`，不含 seq / oseq）；r = 是否已过 redact
// 收编（configure 后在引擎线程）逐条读：无 redact 钩子时不解码行体，只把 `{"r":R,` 换成 `{"seq":N[,"oseq":M],`。

/// pre 文件名：`<小写 uuid v4>.jsonl`。
enum PreName {
    static let suffix = ".jsonl"

    static func make() -> String { IDs.newV4() + suffix }

    static func isValid(_ name: String) -> Bool {
        name.hasSuffix(suffix) && IDs.isUuid(String(name.dropLast(suffix.count)))
    }
}

/// 进程内的「没落盘的行」计数（ADR 0024 决定 1；简报 §4.1）：总数、error 及以上数、首末时刻。只在内存。
/// 一旦有可写会话就以合成 warn `rtv.pre_init_dropped` 上报并清零。
final class DropCounter: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var count: Int64
        var errorCount: Int64
        var firstTs: Int64
        var lastTs: Int64
    }

    private let lock = NSLock()
    private var s = Snapshot(count: 0, errorCount: 0, firstTs: 0, lastTs: 0)

    func add(level: LogLevel, ts: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if s.count == 0 {
            s.firstTs = ts
            s.lastTs = ts
        } else {
            s.firstTs = min(s.firstTs, ts)
            s.lastTs = max(s.lastTs, ts)
        }
        s.count += 1
        if level.rank >= LogLevel.error.rank { s.errorCount += 1 }
    }

    /// 段文件随会话目录消失时，按段统计并入（行已写进被删掉的 inode）。
    func add(segment info: SegInfo) {
        guard info.lineCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if s.count == 0 {
            s.firstTs = info.firstTs
            s.lastTs = info.lastTs
        } else {
            s.firstTs = min(s.firstTs, info.firstTs)
            s.lastTs = max(s.lastTs, info.lastTs)
        }
        s.count += Int64(info.lineCount)
        s.errorCount += Int64(info.errorLines)
    }

    /// 取走（并清零）；为零返回 nil。
    func take() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard s.count > 0 else { return nil }
        let out = s
        s = Snapshot(count: 0, errorCount: 0, firstTs: 0, lastTs: 0)
        return out
    }

    /// 上报没写成：放回。
    func putBack(_ x: Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        if s.count == 0 {
            s = x
        } else {
            s.count += x.count
            s.errorCount += x.errorCount
            s.firstTs = min(s.firstTs, x.firstTs)
            s.lastTs = max(s.lastTs, x.lastTs)
        }
    }

    func reset() {
        lock.lock()
        s = Snapshot(count: 0, errorCount: 0, firstTs: 0, lastTs: 0)
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return s
    }

    static let tag = "rtv.pre_init_dropped"
    static let msg = "lines dropped before a session was available"

    static func line(_ x: Snapshot, ts: Int64) -> LogLine {
        LogLine(ts: ts, level: .warn, msg: msg, tag: tag,
                attrs: ["count": .int(x.count), "error_count": .int(x.errorCount), "first_ts": .int(x.firstTs), "last_ts": .int(x.lastTs)])
    }
}

/// 本进程的 pre 文件（写侧）。不自带锁：交接前由 `PreLog` 的锁串行，交接给实例后由 writer 锁串行。
final class PreFile: @unchecked Sendable {
    let url: URL
    let name: String
    private(set) var fd: Int32
    private(set) var size: Int64
    /// configure 之前的记录（`r` = 0 行、交接前的用户切换）一条没装下之后，交接前不再写（简报 §1.1：到 1 MB 后不再写，转入计数）。
    /// 交接之后（收编中）的 `r` = 1 行与用户切换不受 1 MB 限制、也不看它：那是已 configure 的行，R-1 照常（量受收编窗口约束）。
    private(set) var full = false

    private init(url: URL, fd: Int32, size: Int64) {
        self.url = url
        self.name = url.lastPathComponent
        self.fd = fd
        self.size = size
    }

    /// 建文件（O_EXCL）、持 flock、写头记录。任何一步失败返回 nil（不留半成品）。
    static func create(dir: URL, header: [UInt8]) -> PreFile? {
        guard FS.ensureDir(dir) else { return nil }
        let url = dir.appendingPathComponent(PreName.make())
        // 建文件与加锁一步完成（O_EXLOCK）：别的进程的孤儿扫描不会在 open 与 flock 之间抢到锁、把空文件当孤儿删掉
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        let fl = fcntl(fd, F_GETFL)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) }
        FS.markFile(url)
        guard header.withUnsafeBytes({ FS.writeAll(fd, $0) }) else {
            unlink(url.path)
            Darwin.close(fd)
            return nil
        }
        return PreFile(url: url, fd: fd, size: Int64(header.count))
    }

    /// configure 之前的用户切换记录没写成：交接前不再写（之后的行计数），免得后面的行挂到错的用户名下。
    func markFull() { full = true }

    /// 追加一条记录（一次 write 循环）。`capped`（交接前的记录）：超上限 → 置 full、不写；写到一半失败 → 截回追加前的长度。
    func append(_ bytes: [UInt8], capped: Bool) -> Bool {
        guard fd >= 0 else { return false }
        if Faults.failsPreAppend(url) { return false }
        if capped {
            if full { return false }
            if size + Int64(bytes.count) > ClientConstants.preFileMaxBytes {
                full = true
                return false
            }
        }
        if bytes.withUnsafeBytes({ FS.writeAll(fd, $0) }) {
            size += Int64(bytes.count)
            return true
        }
        _ = ftruncate(fd, off_t(size))
        return false
    }

    static let r0 = Array("{\"r\":0,".utf8)
    static let r1 = Array("{\"r\":1,".utf8)

    /// 行记录：`{"r":0|1,` + 行体（`"ts":…}\n`）。
    func appendLine(redacted: Bool, body: [UInt8]) -> Bool {
        var b = redacted ? PreFile.r1 : PreFile.r0
        b.reserveCapacity(b.count + body.count)
        b.append(contentsOf: body)
        return append(b, capped: !redacted)
    }

    /// `capped`：configure 之前的用户切换（受 1 MB 限制）；收编中（交接之后）的不受限。
    func appendUser(_ u: String?, capped: Bool) -> Bool {
        append(PreFile.userRecord(u), capped: capped)
    }

    static func userRecord(_ u: String?) -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"pre_user\":"); o.stringOrNull(u)
        o.raw("}\n")
        return o.bytes
    }

    static func header(startedMs: Int64, process: String, device: Device) -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"pre\":1,\"started_ms\":"); o.int(startedMs)
        o.raw(",\"process\":"); o.string(process)
        o.raw(",\"device\":"); device.encode(into: &o)
        o.raw("}\n")
        return o.bytes
    }

    /// 读侧用的独立描述符（dup：收编读到的是同一个 inode，root 被改名 / 删掉也读得到）。
    func dupForReading() -> Int32 { fd >= 0 ? dup(fd) : -1 }

    /// 提交点（ADR 0023）：unlink 成功（或本来就不在）；unlink 失败时把自己持有的 fd 截成空文件也算——空的 pre 文件不可能被再次收编
    /// （恢复判定：meta.pre 所指文件长度为 0 = 已提交；空 / 只有头的孤儿直接删）。两个都失败返回 false（调用方稍后重试）。
    static func commit(url: URL, fd: Int32) -> Bool {
        if Faults.failsPreCommit(url) { return false }
        if unlink(url.path) == 0 || errno == ENOENT { return true }
        return fd >= 0 && ftruncate(fd, 0) == 0
    }

    /// 关闭（放 flock）。
    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}

/// pre 文件头记录。
struct PreHeader: Sendable {
    var startedMs: Int64
    var process: String
    var device: Device
}

/// pre 文件里的一条记录（按行首固定字节判定，不按子串嗅探）。
enum PreRecord {
    case header(PreHeader)
    case user(String?)
    /// `body` = `"ts":…}\n`（与 LineEncoder 输出逐字节相同）；level / ts 按位置解析。
    case line(redacted: Bool, level: LogLevel, ts: Int64, body: [UInt8])
    /// 解析不了的完整行（磁盘损坏）：跳过。
    case garbage

    static let headerPrefix = Array("{\"pre\":1,".utf8)
    static let userPrefix = Array("{\"pre_user\":".utf8)

    static func parse(_ d: ArraySlice<UInt8>) -> PreRecord {
        if d.starts(with: PreFile.r0) || d.starts(with: PreFile.r1) {
            let redacted = d.starts(with: PreFile.r1)
            var body = Array(d.dropFirst(PreFile.r0.count))
            guard let (ts, level) = PreRecord.tsLevel(body) else { return .garbage }
            body.append(0x0A)
            return .line(redacted: redacted, level: level, ts: ts, body: body)
        }
        if d.starts(with: userPrefix) {
            guard let o = JSONIn.object(Array(d)), o.keys.contains("pre_user") else { return .garbage }
            if o["pre_user"] is NSNull { return .user(nil) }
            guard let u = o["pre_user"] as? String else { return .garbage }
            return .user(Text.sanitizeUserId(u))
        }
        if d.starts(with: headerPrefix) {
            guard let o = JSONIn.object(Array(d)), let started = JSONIn.int64(o["started_ms"]),
                  let dev = Device.decode(o["device"]) else { return .garbage }
            let proc = RetrieverClient.sanitizeProcessName((o["process"] as? String) ?? "main")
            return .header(PreHeader(startedMs: started, process: proc, device: dev.sanitized()))
        }
        return .garbage
    }

    private static let pTs = Array("\"ts\":".utf8)
    private static let pLevel = Array(",\"level\":\"".utf8)

    /// 行体开头的 `"ts":T,"level":"L"`（固定位置）。
    static func tsLevel(_ b: [UInt8]) -> (Int64, LogLevel)? {
        guard b.starts(with: pTs) else { return nil }
        var i = pTs.count
        var neg = false
        if i < b.count && b[i] == 0x2D { neg = true; i += 1 }
        var v: Int64 = 0
        var any = false
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
            v = v &* 10 &+ Int64(b[i] - 0x30)
            i += 1
            any = true
        }
        guard any, i + pLevel.count <= b.count, Array(b[i..<(i + pLevel.count)]) == pLevel else { return nil }
        i += pLevel.count
        var j = i
        while j < b.count && b[j] != 0x22 { j += 1 }
        guard j < b.count, let lvl = LogLevel(rawValue: String(decoding: b[i..<j], as: UTF8.self)) else { return nil }
        return (neg ? -v : v, lvl)
    }
}

/// pre 文件的增量读取（收编用）：每次读到当前文件尾，只交出以 `\n` 结尾的完整记录；残行留到下次（或永远不交出）。
final class PreReader: @unchecked Sendable {
    private var fd: Int32
    private(set) var offset: Int64 = 0

    init(fd: Int32) { self.fd = fd }

    /// 孤儿 / 重做：尽量以读写打开（提交时 unlink 失败要能截成空文件），打不开退回只读。
    convenience init?(url: URL) {
        var fd = open(url.path, O_RDWR | O_CLOEXEC)
        if fd < 0 { fd = open(url.path, O_RDONLY | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        self.init(fd: fd)
    }

    var descriptor: Int32 { fd }

    /// 文件已被 unlink（别的进程收编完删掉、随后放了锁）：拿到锁之后要再确认它还在，否则会重复收编。
    var isUnlinked: Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && st.st_nlink == 0
    }

    /// nil = 读失败（不推进）。
    func readAvailable() -> [PreRecord]? {
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let size = Int64(st.st_size)
        guard size > offset else { return [] }
        let n = Int(size - offset)
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, n - got, off_t(offset) + off_t(got)) }
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            if r == 0 { break }
            return nil
        }
        guard let lastNL = buf[0..<got].lastIndex(of: 0x0A) else { return [] }
        var out: [PreRecord] = []
        var start = 0
        for i in 0...lastNL where buf[i] == 0x0A {
            if i > start { out.append(PreRecord.parse(buf[start..<i])) }
            start = i + 1
        }
        offset += Int64(lastNL + 1)
        return out
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}

/// 行体解码（收编时给 redact 钩子看；只解我们自己写出的格式）。
enum LineDecoder {
    struct Decoded {
        var line: LogLine
        var synthetic: Bool
        var truncated: Bool
    }

    /// `body` = `"ts":…}`（可带尾随 `\n`）。
    static func decode(_ body: [UInt8]) -> Decoded? {
        var b = body
        if b.last == 0x0A { b.removeLast() }
        guard let o = JSONIn.object([0x7B] + b), let ts = JSONIn.int64(o["ts"]),
              let level = (o["level"] as? String).flatMap(LogLevel.init(rawValue:)), let msg = o["msg"] as? String else { return nil }
        var attrs: [String: AttrValue]? = nil
        if let a = o["attrs"] as? [String: Any] {
            var m: [String: AttrValue] = [:]
            for (k, v) in a {
                if JSONIn.isBool(v) { m[k] = .bool((v as? NSNumber)?.boolValue ?? false) }
                else if let d = JSONIn.double(v) { m[k] = .number(d) }
                else if let s = v as? String { m[k] = .string(s) }
            }
            attrs = m
        }
        var exc: LogException? = nil
        if let e = o["exc"] as? [String: Any], let t = e["type"] as? String, let m = e["message"] as? String {
            exc = LogException(type: t, message: m, stack: e["stack"] as? String)
        }
        let line = LogLine(ts: ts, level: level, msg: msg, tag: o["tag"] as? String, attrs: attrs, exc: exc)
        return Decoded(line: line, synthetic: JSONIn.bool(o["synthetic"]) ?? false, truncated: JSONIn.bool(o["truncated"]) ?? false)
    }
}

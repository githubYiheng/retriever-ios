import Foundation

/// 段文件读侧（§3.3-5 / §3.4）：按 `\n` 切行、逐行校验，丢弃尾部残行与全 0 块并计 corrupt。
struct SegLine {
    var seq: Int64
    /// 0 = 非义务行
    var oseq: Int64
    var ts: Int64
    var levelRank: Int
    /// 行字节在 data 里的范围（不含 `\n`）
    var range: Range<Int>
}

struct SegmentHeader {
    var segNo: Int
    var userId: String?
    var startedMs: Int64

    func encode() -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"v\":1,\"seg_no\":"); o.int(segNo)
        o.raw(",\"user_id\":"); o.stringOrNull(userId)
        o.raw(",\"started_ms\":"); o.int(startedMs)
        o.raw("}\n")
        return o.bytes
    }
}

struct SegmentFile {
    var url: URL
    var segNo: Int
    var header: SegmentHeader?
    var data: [UInt8]
    var lines: [SegLine]
    /// 最后一个完整行（或 header）结束处的字节偏移（截残行用）。
    var validEnd: Int
    /// 无法解析的块数（残行、全 0 块、坏 JSON）。
    var corruptChunks: Int
    /// 尾部残行里能认出的 (seq, oseq)（前缀在同一次 write 里先写，残行通常保住前缀）。
    var tornSeq: Int64?
    var tornOseq: Int64?

    var sealed: Bool { url.lastPathComponent.hasSuffix(".sealed") }
}

enum Segments {
    static func name(_ segNo: Int, open: Bool) -> String {
        let n = String(segNo)
        return "seg-" + String(repeating: "0", count: max(0, 6 - n.count)) + n + (open ? ".open" : ".sealed")
    }

    /// `seg-000123.open|.sealed` → (123, isOpen)
    static func parseName(_ name: String) -> (Int, Bool)? {
        guard name.hasPrefix("seg-") else { return nil }
        let isOpen: Bool
        let stem: Substring
        if name.hasSuffix(".open") { isOpen = true; stem = name.dropFirst(4).dropLast(5) }
        else if name.hasSuffix(".sealed") { isOpen = false; stem = name.dropFirst(4).dropLast(7) }
        else { return nil }
        guard let n = Int(stem), n > 0 else { return nil }
        return (n, isOpen)
    }

    /// 读段文件。`validate` = 逐行 JSON 校验（恢复孤儿段时用；平时只解析前缀）。
    static func read(_ url: URL, validate: Bool) -> SegmentFile? {
        guard let data = FS.read(url) else { return nil }
        return parse(url, data, validate: validate)
    }

    /// 严格读（物化用，ADR 0024 决定 3）：读失败（含读不全）与「文件确已不存在」分开。
    enum StrictRead {
        case ok(SegmentFile)
        case missing
        case failed
    }

    static func readStrict(_ url: URL) -> StrictRead {
        switch FS.readStrict(url) {
        case .missing: return .missing
        case .failed: return .failed
        case .ok(let data):
            guard let f = parse(url, data, validate: false) else { return .failed }
            return .ok(f)
        }
    }

    static func parse(_ url: URL, _ data: [UInt8], validate: Bool) -> SegmentFile? {
        guard let (segNo, _) = parseName(url.lastPathComponent) else { return nil }
        var seg = SegmentFile(url: url, segNo: segNo, header: nil, data: data, lines: [], validEnd: 0, corruptChunks: 0)
        var start = 0
        var first = true
        let n = data.count
        while start < n {
            var end = start
            while end < n && data[end] != 0x0A { end += 1 }
            var s = start
            while s < end && data[s] == 0 { s += 1 }
            if end == n {
                // 尾部残行（没有 `\n` 结尾）：计 corrupt；前缀在同一次 write 里先写，尽量认出 seq / oseq
                seg.corruptChunks += 1
                if s < end {
                    if let p = parsePrefix(data, s..<end) { seg.tornSeq = p.seq; seg.tornOseq = p.oseq }
                    else if let (sq, oq) = parseSeqOnly(data, s..<end) { seg.tornSeq = sq; seg.tornOseq = oq }
                }
                break
            }
            seg.validEnd = end + 1
            if s > start { seg.corruptChunks += 1 }   // 全 0 块
            if s == end { start = end + 1; continue }
            if first {
                first = false
                if s == start, let h = parseHeader(data, s..<end) {
                    seg.header = h
                    start = end + 1
                    continue
                }
            }
            if let p = parsePrefix(data, s..<end), !validate || isValidJSON(data, s..<end) {
                seg.lines.append(SegLine(seq: p.seq, oseq: p.oseq, ts: p.ts, levelRank: p.levelRank, range: s..<end))
            } else {
                seg.corruptChunks += 1
            }
            start = end + 1
        }
        return seg
    }

    static func isValidJSON(_ data: [UInt8], _ r: Range<Int>) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(data[r]), options: [])) is [String: Any]
    }

    static func parseHeader(_ data: [UInt8], _ r: Range<Int>) -> SegmentHeader? {
        guard data[r].starts(with: Array("{\"v\":".utf8)) else { return nil }
        guard let o = JSONIn.object(Data(data[r])), let segNo = JSONIn.int64(o["seg_no"]) else { return nil }
        let user = o["user_id"] as? String
        return SegmentHeader(segNo: Int(segNo), userId: user, startedMs: JSONIn.int64(o["started_ms"]) ?? 0)
    }

    struct Prefix {
        var seq: Int64
        var oseq: Int64
        var ts: Int64
        var levelRank: Int
        /// 级别值结尾引号之后的位置（下一个字段从这里开始）。
        var end: Int = 0
    }

    private static let pSeq = Array("{\"seq\":".utf8)
    private static let pOseq = Array("\"oseq\":".utf8)
    private static let pTs = Array("\"ts\":".utf8)
    private static let pLevel = Array(",\"level\":\"".utf8)

    /// 解析我方写出的固定前缀 `{"seq":N[,"oseq":M],"ts":T,"level":"L"`。
    static func parsePrefix(_ d: [UInt8], _ r: Range<Int>) -> Prefix? {
        var i = r.lowerBound
        let end = r.upperBound
        func expect(_ p: [UInt8]) -> Bool {
            guard end - i >= p.count else { return false }
            for k in 0..<p.count where d[i + k] != p[k] { return false }
            i += p.count
            return true
        }
        func number() -> Int64? {
            var v: Int64 = 0
            var any = false
            while i < end, d[i] >= 0x30, d[i] <= 0x39 {
                v = v &* 10 &+ Int64(d[i] - 0x30)
                i += 1
                any = true
            }
            return any ? v : nil
        }
        guard expect(pSeq), let seq = number(), i < end, d[i] == 0x2C else { return nil }
        i += 1
        var oseq: Int64 = 0
        if expect(pOseq) {
            guard let o = number(), i < end, d[i] == 0x2C else { return nil }
            oseq = o
            i += 1
        }
        guard expect(pTs), let ts = number(), expect(pLevel) else { return nil }
        var j = i
        while j < end && d[j] != 0x22 { j += 1 }
        guard j < end, let lvl = LogLevel(rawValue: String(decoding: d[i..<j], as: UTF8.self)) else { return nil }
        return Prefix(seq: seq, oseq: oseq, ts: ts, levelRank: lvl.rank, end: j + 1)
    }

    /// 残行只剩前缀一部分时尽量认出 seq / oseq。
    static func parseSeqOnly(_ d: [UInt8], _ r: Range<Int>) -> (Int64, Int64)? {
        guard d[r].starts(with: pSeq) else { return nil }
        var i = r.lowerBound + pSeq.count
        var seq: Int64 = 0
        var any = false
        while i < r.upperBound, d[i] >= 0x30, d[i] <= 0x39 { seq = seq &* 10 &+ Int64(d[i] - 0x30); i += 1; any = true }
        guard any, i < r.upperBound, d[i] == 0x2C else { return nil }
        i += 1
        var oseq: Int64 = 0
        if r.upperBound - i >= pOseq.count, Array(d[i..<(i + pOseq.count)]) == pOseq {
            i += pOseq.count
            var v: Int64 = 0
            var got = false
            while i < r.upperBound, d[i] >= 0x30, d[i] <= 0x39 { v = v &* 10 &+ Int64(d[i] - 0x30); i += 1; got = true }
            // 数字后必须跟逗号才可信（否则可能被截在数字中间）
            if got, i < r.upperBound, d[i] == 0x2C { oseq = v }
        }
        return (seq, oseq)
    }

    // MARK: 按位置判定（ADR 0024 决定 9）：行尾的固定字段与 msg 之后的 tag；attrs 里的同名键不会命中

    private static let tailTruncated = Array(",\"truncated\":true".utf8)
    private static let tailSynthetic = Array(",\"synthetic\":true".utf8)
    private static let tailCtx = Array(",\"ctx\":true".utf8)

    /// 行尾的固定字段（按写出顺序 `…[,"ctx":true][,"synthetic":true][,"truncated":true]}`，从行尾往回认）。
    /// 字符串值里的 `"` 一律转义，attrs / exc 以 `}` 结尾，所以这些模式只可能是顶层字段。
    struct Tail { var ctx = false; var synthetic = false; var truncated = false }

    static func tail(_ raw: ArraySlice<UInt8>) -> Tail {
        var t = Tail()
        guard let last = raw.last, last == 0x7D else { return t }
        var end = raw.endIndex - 1
        func strip(_ p: [UInt8]) -> Bool {
            guard end - raw.startIndex >= p.count else { return false }
            let s = raw[(end - p.count)..<end]
            guard s.elementsEqual(p) else { return false }
            end -= p.count
            return true
        }
        t.truncated = strip(tailTruncated)
        t.synthetic = strip(tailSynthetic)
        t.ctx = strip(tailCtx)
        return t
    }

    private static let pMsg = Array(",\"msg\":\"".utf8)
    private static let pTag = Array(",\"tag\":\"".utf8)

    /// 行的 tag（紧跟 msg 之后的固定位置；没有 tag 返回 nil）。`raw` 是带前缀的整行（段文件 / 信封里的行）。
    static func tag(_ raw: ArraySlice<UInt8>) -> String? {
        let d = Array(raw)
        guard let p = parsePrefix(d, 0..<d.count) else { return nil }
        var i = p.end
        guard i + pMsg.count <= d.count, Array(d[i..<(i + pMsg.count)]) == pMsg else { return nil }
        i += pMsg.count
        // 跳过 msg 字符串（转义感知）
        var esc = false
        while i < d.count {
            let c = d[i]
            if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { break }
            i += 1
        }
        guard i < d.count else { return nil }
        i += 1
        guard i + pTag.count <= d.count, Array(d[i..<(i + pTag.count)]) == pTag else { return nil }
        i += pTag.count
        let start = i
        esc = false
        while i < d.count {
            let c = d[i]
            if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { break }
            i += 1
        }
        guard i < d.count else { return nil }
        // 我们写出的 tag 只可能含转义序列；按 JSON 字符串解出来比较
        let lit = [0x22] + Array(d[start..<i]) + [0x22]
        return (try? JSONSerialization.jsonObject(with: Data(lit), options: [.fragmentsAllowed])) as? String
    }

    private static let ctxInsertBefore: [[UInt8]] = [
        Array(",\"synthetic\":true,\"truncated\":true}".utf8),
        Array(",\"synthetic\":true}".utf8),
        Array(",\"truncated\":true}".utf8),
    ]
    private static let ctxField = Array(",\"ctx\":true".utf8)

    /// 物化 ctx 行：在固定位置（exc 之后、synthetic / truncated 之前）插入 `"ctx":true`。
    /// 段里的非义务行没有 oseq，字节原样保留，只插一个字段。
    static func withCtx(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        for suf in ctxInsertBefore where Bytes.hasSuffix(raw, suf) {
            var out = Array(raw.dropLast(suf.count))
            out.append(contentsOf: ctxField)
            out.append(contentsOf: suf)
            return out
        }
        var out = Array(raw.dropLast(1))
        out.append(contentsOf: ctxField)
        out.append(0x7D)
        return out
    }
}

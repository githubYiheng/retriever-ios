import Foundation

/// 行 JSON 手写编码（§3.1）。字段顺序固定：seq, oseq, ts, level, msg, tag, attrs, exc, ctx, synthetic, truncated；
/// 可选字段缺省不输出键。本编码器只产出 seq / oseq 之后的部分（`"ts":…}` + `\n`），seq / oseq 前缀在锁内拼上；
/// `ctx` 只在物化进信封时插入（段文件里没有）。
enum LineEncoder {
    /// 行 JSON 里 body 之外可能出现的最大字节：`{"seq":<16 位>,"oseq":<16 位>,`（48 B）+ 物化时插入的 `"ctx":true,`（11 B）。
    static let reservedBytes = 48 + 11
    static var bodyBudget: Int { Limits.lineSerializedBytes - reservedBytes }

    struct Encoded {
        /// `"ts":…}\n`
        var body: [UInt8]
        var truncated: Bool
    }

    /// 从宿主参数构造 exc（§3.1）：type = String(reflecting:)；NSError 用 domain / code / localizedDescription；Swift 无栈 → stack nil。
    static func exception(from error: any Error) -> LogException {
        let t = type(of: error)
        if t is NSError.Type {
            let ns = error as NSError
            return LogException(type: String(reflecting: t), message: "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)", stack: nil)
        }
        return LogException(type: String(reflecting: t), message: String(describing: error), stack: nil)
    }

    /// `truncated`：行原本已被截断（收编时重编码过 redact 的 pre 行：与原值取或，ADR 0023）。
    static func encode(_ line: LogLine, synthetic: Bool = false, truncated alreadyTruncated: Bool = false) -> Encoded {
        var truncated = alreadyTruncated

        let (msg0, tm) = Text.truncate(line.msg, maxBytes: Limits.lineMsgBytes)
        var msg = msg0
        truncated = truncated || tm

        var tag: String? = nil
        if let t = line.tag {
            let (t2, tt) = Text.truncate(t, maxBytes: Limits.lineTagBytes)
            tag = t2
            truncated = truncated || tt
        }

        var attrsJSON: [UInt8]? = nil
        if let a = line.attrs, !a.isEmpty {
            let (j, ta) = encodeAttrs(a)
            attrsJSON = j
            truncated = truncated || ta
        }

        var exc: LogException? = nil
        if let e = line.exc {
            let (type, t1) = Text.truncate(e.type, maxBytes: Limits.lineExcTypeBytes)
            let (message, t2) = Text.truncate(e.message, maxBytes: Limits.lineExcMessageBytes)
            var stack = e.stack
            var t3 = false
            if let s = stack, s.utf8.count > Limits.lineExcStackBytes {
                stack = headTail(s)
                t3 = true
            }
            exc = LogException(type: type, message: message, stack: stack)
            truncated = truncated || t1 || t2 || t3
        }

        // 单行上限：超出先删 attrs、再截 stack、再截 msg（按转义后字节核算）。
        var body = build(ts: line.ts, level: line.level, msg: msg, tag: tag, attrs: attrsJSON, exc: exc,
                         synthetic: synthetic, truncated: truncated)
        if body.count - 1 > bodyBudget, attrsJSON != nil {
            attrsJSON = nil
            truncated = true
            body = build(ts: line.ts, level: line.level, msg: msg, tag: tag, attrs: nil, exc: exc, synthetic: synthetic, truncated: true)
        }
        if body.count - 1 > bodyBudget, let e = exc, let s = e.stack {
            // 再截 stack：仍按「头 + 标记 + 尾」保住 `Caused by`，按转义后字节核算
            let excess = body.count - 1 - bodyBudget
            let current = JSONOut.escapedLength(s) - 2
            var e2 = e
            e2.stack = headTailEscaped(s, budget: current - excess)
            exc = e2
            truncated = true
            body = build(ts: line.ts, level: line.level, msg: msg, tag: tag, attrs: nil, exc: exc, synthetic: synthetic, truncated: true)
        }
        if body.count - 1 > bodyBudget {
            let excess = body.count - 1 - bodyBudget
            let current = JSONOut.escapedLength(msg) - 2
            msg = Text.truncateEscaped(msg, budget: max(current - excess, 0))
            truncated = true
            body = build(ts: line.ts, level: line.level, msg: msg, tag: tag, attrs: nil, exc: exc, synthetic: synthetic, truncated: true)
        }
        return Encoded(body: body, truncated: truncated)
    }

    /// stack 超长：头 8 KB + 标记 + 尾（8 KB − 标记字节，保证总长 ≤ 16 KB 的服务端硬上限）。
    static func headTail(_ s: String) -> String {
        let marker = ClientConstants.stackMarker
        let head = Text.truncate(s, maxBytes: Limits.lineExcStackHeadBytes).0
        let tailBudget = Limits.lineExcStackBytes - head.utf8.count - marker.utf8.count
        let tail = Text.suffix(s, maxBytes: min(Limits.lineExcStackTailBytes, tailBudget))
        return head + marker + tail
    }

    /// 转义后 ≤ budget 的「头 + 标记 + 尾」；budget 连标记都放不下时返回 nil（去掉 stack）。
    static func headTailEscaped(_ s: String, budget: Int) -> String? {
        let marker = ClientConstants.stackMarker
        let markerEsc = JSONOut.escapedLength(marker) - 2
        let room = budget - markerEsc
        if room < 2 { return budget > 0 ? Text.truncateEscaped(s, budget: budget) : nil }
        let head = Text.truncateEscaped(s, budget: room / 2)
        let headEsc = JSONOut.escapedLength(head) - 2
        let tail = Text.suffixEscaped(s, budget: room - headEsc)
        return head + marker + tail
    }

    /// attrs：键按字典序；≤ 32 键；贪心装入直到序列化 ≤ 4096 B；非有限数转 string。返回 (JSON 或 nil, 是否截断)。
    /// 字符串值先截到预算再转义（ADR 0020 决定 3）：超过预算的值本来就装不下、照样跳过，只是不再为它整串转义（分配有上限）。
    static func encodeAttrs(_ attrs: [String: AttrValue]) -> ([UInt8]?, Bool) {
        var truncated = false
        var keys = attrs.keys.sorted()
        if keys.count > Limits.lineAttrsKeys {
            keys = Array(keys.prefix(Limits.lineAttrsKeys))
            truncated = true
        }
        var out: [UInt8] = [0x7B]
        var count = 0
        for k in keys {
            var item = JSONOut(capacity: 32)
            if count > 0 { item.raw(",") }
            item.string(k)
            item.raw(":")
            switch attrs[k]! {
            case .string(let s): item.string(Text.truncate(s, maxBytes: Limits.lineAttrsBytes).0)
            case .bool(let b): item.bool(b)
            case .number(let d):
                if d.isFinite { item.number(d) } else { item.string(d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity")) }
            }
            if out.count + item.bytes.count + 1 > Limits.lineAttrsBytes {
                truncated = true
                continue
            }
            out.append(contentsOf: item.bytes)
            count += 1
        }
        if count == 0 { return (nil, truncated || !attrs.isEmpty) }
        out.append(0x7D)
        return (out, truncated)
    }

    static func build(ts: Int64, level: LogLevel, msg: String, tag: String?, attrs: [UInt8]?, exc: LogException?,
                      synthetic: Bool, truncated: Bool) -> [UInt8] {
        var o = JSONOut(capacity: 64 + msg.utf8.count)
        o.raw("\"ts\":"); o.int(ts)
        o.raw(",\"level\":\""); o.raw(level.rawValue); o.raw("\"")
        o.raw(",\"msg\":"); o.string(msg)
        if let tag { o.raw(",\"tag\":"); o.string(tag) }
        if let attrs { o.raw(",\"attrs\":"); o.raw(attrs) }
        if let exc {
            o.raw(",\"exc\":{\"type\":"); o.string(exc.type)
            o.raw(",\"message\":"); o.string(exc.message)
            if let st = exc.stack { o.raw(",\"stack\":"); o.string(st) }
            o.raw("}")
        }
        if synthetic { o.raw(",\"synthetic\":true") }
        if truncated { o.raw(",\"truncated\":true") }
        o.raw("}\n")
        return o.bytes
    }

    /// 锁内拼前缀：`{"seq":N,` 或 `{"seq":N,"oseq":M,`。
    @inline(__always)
    static func prefix(seq: Int64, oseq: Int64) -> [UInt8] {
        var o = JSONOut(capacity: 48)
        o.raw("{\"seq\":"); o.int(seq)
        if oseq > 0 { o.raw(",\"oseq\":"); o.int(oseq) }
        o.raw(",")
        return o.bytes
    }
}

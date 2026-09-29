import Foundation

/// 手写 JSON 输出：控制字段顺序、转义与字节核算（与 JS `JSON.stringify` 逐字节一致：
/// 只转义 `"`、`\`、C0 控制字符；`\b \t \n \f \r` 用短形式，其余 `\u00xx` 小写十六进制）。
struct JSONOut {
    var bytes: [UInt8] = []

    init(capacity: Int = 256) { bytes.reserveCapacity(capacity) }

    mutating func raw(_ s: StaticString) {
        s.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    mutating func raw(_ s: String) { bytes.append(contentsOf: s.utf8) }

    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    mutating func string(_ s: String) {
        bytes.append(0x22)
        JSONOut.appendEscaped(s, into: &bytes)
        bytes.append(0x22)
    }

    mutating func stringOrNull(_ s: String?) {
        if let s { string(s) } else { raw("null") }
    }

    mutating func int(_ v: Int64) { raw(String(v)) }
    mutating func int(_ v: Int) { raw(String(v)) }

    mutating func bool(_ v: Bool) { v ? raw("true") : raw("false") }

    mutating func number(_ d: Double) { raw(JSONOut.jsNumber(d)) }

    static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    static func appendEscaped(_ s: String, into out: inout [UInt8]) {
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x08: out.append(0x5C); out.append(0x62)
            case 0x09: out.append(0x5C); out.append(0x74)
            case 0x0A: out.append(0x5C); out.append(0x6E)
            case 0x0C: out.append(0x5C); out.append(0x66)
            case 0x0D: out.append(0x5C); out.append(0x72)
            case 0..<0x20:
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0xF)]])
            default: out.append(b)
            }
        }
    }

    /// 单个标量转义后的字节数。
    @inline(__always)
    static func escapedWidth(_ sc: Unicode.Scalar) -> Int {
        let v = sc.value
        switch v {
        case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return 2
        case 0..<0x20: return 6
        case 0..<0x80: return 1
        case 0..<0x800: return 2
        case 0..<0x10000: return 3
        default: return 4
        }
    }

    /// 字符串值（含两侧引号）序列化后的字节数。
    static func escapedLength(_ s: String) -> Int {
        var n = 2
        for b in s.utf8 {
            switch b {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: n += 2
            case 0..<0x20: n += 6
            default: n += 1
            }
        }
        return n
    }

    /// ECMAScript Number::toString（JSON.stringify 的数字格式），保证与服务端校验的字节核算一致。
    /// 调用方保证 d 有限。
    static func jsNumber(_ d: Double) -> String {
        if d == 0 { return "0" }
        if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return String(Int64(d)) }
        // 取 Swift 的最短往返十进制表示，拆成数字串与小数点位置 n（值 = 0.d1d2… × 10^n）。
        let desc = String(describing: abs(d))
        var mantissa = desc
        var exp = 0
        if let eIdx = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(desc[..<eIdx])
            exp = Int(desc[desc.index(after: eIdx)...]) ?? 0
        }
        var intPart = mantissa
        var fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = Array(intPart + fracPart)
        var n = intPart.count + exp
        while let f = digits.first, f == "0", digits.count > 1 { digits.removeFirst(); n -= 1 }
        while let l = digits.last, l == "0", digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let ds = String(digits)
        var out: String
        if k <= n && n <= 21 {
            out = ds + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            out = String(digits[0..<n]) + "." + String(digits[n...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + ds
        } else {
            let e = n - 1
            let sign = e >= 0 ? "+" : "-"
            if k == 1 {
                out = ds + "e" + sign + String(abs(e))
            } else {
                out = String(digits[0]) + "." + String(digits[1...]) + "e" + sign + String(abs(e))
            }
        }
        return d < 0 ? "-" + out : out
    }
}

/// 读 JSON（本地状态文件与信封头）：JSONSerialization 的结果加类型安全的取值。
enum JSONIn {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    static func object(_ bytes: [UInt8]) -> [String: Any]? {
        object(Data(bytes))
    }

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func bool(_ v: Any?) -> Bool? {
        isBool(v) ? (v as? NSNumber)?.boolValue : nil
    }

    /// JS `typeof x === "number"`：NSNumber 且不是布尔。
    static func double(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBool(v) else { return nil }
        return n.doubleValue
    }

    static func int64(_ v: Any?) -> Int64? {
        guard let d = double(v), d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_991 else { return nil }
        return Int64(d)
    }

    static func string(_ v: Any?) -> String? { v as? String }
}

/// 字节级小工具：在 JSON 文本里找模式（我们写出的 JSON 中字符串内的 `"` 一律被转义，
/// 所以以 `"` 开头的键模式不会在字符串值内部误中）。
enum Bytes {
    static func find(_ pattern: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, hay.count >= pattern.count else { return nil }
        let first = pattern[0]
        var i = from
        let last = hay.count - pattern.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < pattern.count && hay[i + j] == pattern[j] { j += 1 }
                if j == pattern.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func contains(_ pattern: [UInt8], in hay: ArraySlice<UInt8>) -> Bool {
        guard hay.count >= pattern.count else { return false }
        let first = pattern[0]
        var i = hay.startIndex
        let last = hay.endIndex - pattern.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < pattern.count && hay[i + j] == pattern[j] { j += 1 }
                if j == pattern.count { return true }
            }
            i += 1
        }
        return false
    }

    static func hasSuffix(_ s: ArraySlice<UInt8>, _ suffix: [UInt8]) -> Bool {
        guard s.count >= suffix.count else { return false }
        return s.suffix(suffix.count).elementsEqual(suffix)
    }
}

import Foundation

/// UTF-8 字节核算与码点边界截断（方案开头：所有长度按 UTF-8 字节，只在码点边界截断）。
/// Swift `String` 必为合法 Unicode：宿主传入的孤立代理项在桥接时已变成 U+FFFD（3 字节），
/// 与服务端 `utf8Len` 对孤立代理项的计法一致。
enum Text {
    @inline(__always)
    static func utf8Len(_ s: String) -> Int { s.utf8.count }

    /// 截到 ≤ max 字节（码点边界）；返回 (结果, 是否截断)。
    static func truncate(_ s: String, maxBytes: Int) -> (String, Bool) {
        if s.utf8.count <= maxBytes { return (s, false) }
        var n = 0
        var end = s.unicodeScalars.startIndex
        for idx in s.unicodeScalars.indices {
            let w = UTF8.width(s.unicodeScalars[idx])
            if n + w > maxBytes { break }
            n += w
            end = s.unicodeScalars.index(after: idx)
        }
        return (String(s.unicodeScalars[..<end]), true)
    }

    /// 保留尾部 ≤ max 字节（码点边界）。
    static func suffix(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var n = 0
        var start = s.unicodeScalars.endIndex
        var idx = s.unicodeScalars.endIndex
        while idx > s.unicodeScalars.startIndex {
            let prev = s.unicodeScalars.index(before: idx)
            let w = UTF8.width(s.unicodeScalars[prev])
            if n + w > maxBytes { break }
            n += w
            start = prev
            idx = prev
        }
        return String(s.unicodeScalars[start...])
    }

    /// 截到「JSON 转义后（不含引号）」≤ budget 字节，码点边界。
    static func truncateEscaped(_ s: String, budget: Int) -> String {
        if budget <= 0 { return "" }
        var n = 0
        var end = s.unicodeScalars.startIndex
        for idx in s.unicodeScalars.indices {
            let w = JSONOut.escapedWidth(s.unicodeScalars[idx])
            if n + w > budget { break }
            n += w
            end = s.unicodeScalars.index(after: idx)
        }
        return String(s.unicodeScalars[..<end])
    }

    /// 保留尾部「JSON 转义后（不含引号）」≤ budget 字节，码点边界。
    static func suffixEscaped(_ s: String, budget: Int) -> String {
        if budget <= 0 { return "" }
        var n = 0
        var start = s.unicodeScalars.endIndex
        var idx = s.unicodeScalars.endIndex
        while idx > s.unicodeScalars.startIndex {
            let prev = s.unicodeScalars.index(before: idx)
            let w = JSONOut.escapedWidth(s.unicodeScalars[prev])
            if n + w > budget { break }
            n += w
            start = prev
            idx = prev
        }
        return String(s.unicodeScalars[start...])
    }

    /// user_id：≤ 128 B、不含 C0 / DEL / C1 控制字符（服务端校验规则；不合规的批会进隔离区，所以在源头清洗）。
    /// 清洗后为空（`""`、纯空白、纯控制字符）= nil（ADR 0024 决定 10：否则所有用 `""` 表示未登录的设备在服务端归到同一个用户）。
    /// 空白 = Unicode White_Space（`CharacterSet.whitespacesAndNewlines`）；非空白的值原样保留（不 trim）。
    static func sanitizeUserId(_ s: String?) -> String? {
        guard let s else { return nil }
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isControl($0) }))
        if cleaned.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return nil }
        return truncate(cleaned, maxBytes: Limits.userIdBytes).0
    }

    static func isControl(_ sc: Unicode.Scalar) -> Bool {
        let v = sc.value
        return v <= 0x1F || (v >= 0x7F && v <= 0x9F)
    }
}

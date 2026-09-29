import Foundation
import CryptoKit

/// 标识符（packages/core/src/ids.ts）：UUID_RE 整串匹配、RFC 4122 UUIDv5、确定性 batch_id。
enum IDs {
    /// Retriever 的 UUIDv5 命名空间（固定常量，永不改）。
    static let namespace = "9a1d7c3e-5b2f-4e8a-8c6d-2f1e0b3a7d95"

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$`，整串匹配（不依赖 `$` 的行尾语义）。
    static func isUuid(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            switch i {
            case 8, 13, 18, 23:
                if c != 0x2D { return false }
            case 14:
                if !(c >= 0x31 && c <= 0x38) { return false }
            default:
                if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) { return false }
            }
        }
        return true
    }

    static func uuidBytes(_ s: String) -> [UInt8]? {
        let hex = Array(s.utf8).filter { $0 != 0x2D }
        guard hex.count == 32 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(16)
        var i = 0
        while i < 32 {
            guard let hi = hexVal(hex[i]), let lo = hexVal(hex[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    static func format(_ b: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(36)
        for (i, x) in b.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 { s.append("-") }
            s.append(Character(Unicode.Scalar(JSONOut.hex[Int(x >> 4)])))
            s.append(Character(Unicode.Scalar(JSONOut.hex[Int(x & 0xF)])))
        }
        return s
    }

    /// RFC 4122 UUIDv5（SHA-1），name 按 UTF-8。namespace 必须满足 isUuid。
    static func uuidv5(namespace: String, name: String) -> String? {
        guard isUuid(namespace), let ns = uuidBytes(namespace) else { return nil }
        var input = ns
        input.append(contentsOf: Array(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input)).prefix(16).map { $0 }
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return format(b)
    }

    enum BatchKind: String { case primary, backfill }

    /// `${install_id}:${session_id}:${kind}:${n}`；n = primary 的 oseq_from / backfill 的 seg_no。
    static func batchIdName(installId: String, sessionId: String, kind: BatchKind, n: Int64) -> String {
        "\(installId):\(sessionId):\(kind.rawValue):\(n)"
    }

    /// 输入不合规（非小写 UUID、n 为负）返回 nil（TS 侧抛错）。
    static func batchId(installId: String, sessionId: String, kind: BatchKind, n: Int64) -> String? {
        guard isUuid(installId), isUuid(sessionId), n >= 0 else { return nil }
        return uuidv5(namespace: namespace, name: batchIdName(installId: installId, sessionId: sessionId, kind: kind, n: n))
    }

    /// 新的随机 UUID（v4，小写）。
    static func newV4() -> String { UUID().uuidString.lowercased() }
}

/// 日期（packages/core/src/object-key.ts）：ms UTC → `YYYY-MM-DD`；客户端 day 规则。
enum Day {
    static func fromMs(_ ms: Int64) -> String {
        // floor 除法（负数也正确），再用 Howard Hinnant 的 civil_from_days。
        var days = ms / ClientConstants.dayMs
        if ms % ClientConstants.dayMs < 0 { days -= 1 }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        if m <= 2 { y += 1 }
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
    }

    private static func pad(_ v: Int64, _ w: Int) -> String {
        let s = String(v)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }

    /// day = UTC 日期(clamp(批内最早行 ts, created − 30 d, created))。
    static func clientDay(tsMinMs: Int64, createdMs: Int64) -> String {
        let lo = createdMs - Int64(Limits.dayClampPastDaysClient) * ClientConstants.dayMs
        let t = min(max(tsMinMs, lo), createdMs)
        return fromMs(t)
    }
}

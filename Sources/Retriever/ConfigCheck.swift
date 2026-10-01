import Foundation
import zlib

// 配置诊断（ADR 0025；简报 §13）：key / baseURL 写错时在系统日志里说出来。只出诊断、不改行为——请求照发，服务端是唯一裁决者；
// 唯一的行为变化是 configure 先修剪 key（带空白的 key 本来必然 401）。消息是写死的英文句子（两端逐字一致），绝不含 key 的任何部分。
// 出口见 `ConfigDiagnostics`。

/// 纯函数检查（与 Android 同名同序）：修剪、key 格式与 crc、env 与端点、baseURL 形状。结果只用来写诊断，不拦请求。
enum ConfigCheck {
    /// 一条诊断：code（lower_snake，与 Android 同名）+ 消息。
    enum Diagnostic: Sendable, Equatable {
        case noKey
        case keyTrimmed
        case keyMalformed
        case keyEnvMismatch
        case baseURLInvalid
        /// 服务端拒绝 key、进入鉴权暂停：`reason` 已清洗，`minutes` = 本次暂停时长向上取整到分钟。
        case keyRejected(status: Int, reason: String, minutes: Int64)

        var code: String {
            switch self {
            case .noKey: return "no_key"
            case .keyTrimmed: return "key_trimmed"
            case .keyMalformed: return "key_malformed"
            case .keyEnvMismatch: return "key_env_mismatch"
            case .baseURLInvalid: return "base_url_invalid"
            case .keyRejected: return "key_rejected"
            }
        }

        var message: String {
            switch self {
            case .noKey:
                return "no key configured; logs are written locally and never uploaded"
            case .keyTrimmed:
                return "key had leading or trailing whitespace; it was trimmed"
            case .keyMalformed:
                return "key is not a valid Retriever key (format or checksum mismatch); the server will reject it"
            case .keyEnvMismatch:
                return "key environment does not match the endpoint (test key with production endpoint, or live key with staging endpoint); the server will reject it"
            case .baseURLInvalid:
                return "baseUrl is not a valid http(s) URL; uploads will fail"
            case .keyRejected(let status, let reason, let minutes):
                return "server rejected the key (HTTP \(status), reason=\(reason)); uploads paused for \(minutes) min; logs are kept locally"
            }
        }
    }

    static let productionHost = "logs.revdog.org"
    static let stagingHost = "logs-staging.revdog.org"

    /// 去掉首尾的空白与控制字符：码点 ≤ 0x20、0x7F–0x9F、Unicode White_Space。中间的不动。
    static func trim(_ s: String) -> String {
        let u = s.unicodeScalars
        guard let first = u.firstIndex(where: { !trimmable($0) }),
              let last = u.lastIndex(where: { !trimmable($0) }) else { return "" }
        if first == u.startIndex && u.index(after: last) == u.endIndex { return s }
        return String(u[first...last])
    }

    private static func trimmable(_ c: Unicode.Scalar) -> Bool {
        c.value <= 0x20 || (0x7F...0x9F).contains(c.value) || c.properties.isWhitespace
    }

    /// 本地检查，顺序固定：`no_key`（此时不判 2–4）→ `key_trimmed` → `key_malformed` → `key_env_mismatch` → `base_url_invalid`。
    /// `rawKey` = 宿主给的原值，`key` = 修剪后的值。iOS 的 baseURL 是 `URL`：不修剪，只按 scheme / host 判。
    static func check(rawKey: String, key: String, baseURL: URL) -> [Diagnostic] {
        var out: [Diagnostic] = []
        if key.isEmpty {
            out.append(.noKey)
        } else {
            if !rawKey.unicodeScalars.elementsEqual(key.unicodeScalars) { out.append(.keyTrimmed) }
            if let env = keyEnv(key) {
                // 只判两个已知主机；自定义主机（自建、本地）不判
                let host = baseURL.absoluteURL.host?.lowercased()
                if (host == productionHost && env == "test") || (host == stagingHost && env == "live") {
                    out.append(.keyEnvMismatch)
                }
            } else {
                out.append(.keyMalformed)
            }
        }
        if !isHTTPURL(baseURL) { out.append(.baseURLInvalid) }
        return out
    }

    /// scheme ∈ {http, https}（不分大小写）且主机非空的绝对 URL。
    static func isHTTPURL(_ u: URL) -> Bool {
        let a = u.absoluteURL
        guard let s = a.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return !(a.host ?? "").isEmpty
    }

    /// key 合法（格式与 crc 都对，同 `packages/core/src/apikey.ts` 的 `parseApiKey`）时返回 env（`live` | `test`），否则 nil。
    /// 格式 `^lk_(live|test)_([a-z0-9][a-z0-9_-]{1,31})_([0-9a-f]{32})_([0-9a-f]{8})$`；app 可含 `_`：按「末尾固定 42 字符 =
    /// `_<32hex>_<8hex>`」切。crc 作用于最后一个 `_` 之前的全部 UTF-8 字节。
    static func keyEnv(_ key: String) -> String? {
        let b = Array(key.utf8)
        let n = b.count
        // "lk_" + "live_" / "test_" + app（≥ 2）+ 末尾 42
        guard n >= 3 + 5 + 2 + 42, b.starts(with: "lk_".utf8) else { return nil }
        let env: String
        if b[3..<8].elementsEqual("live_".utf8) {
            env = "live"
        } else if b[3..<8].elementsEqual("test_".utf8) {
            env = "test"
        } else {
            return nil
        }
        let tail = n - 42
        let app = b[8..<tail]
        guard app.count <= 32, let a0 = app.first, isLowerAlnum(a0),
              app.dropFirst().allSatisfy({ isLowerAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }) else { return nil }
        guard b[tail] == UInt8(ascii: "_"), b[(tail + 1)..<(tail + 33)].allSatisfy(isLowerHex),
              b[tail + 33] == UInt8(ascii: "_"), b[(tail + 34)...].allSatisfy(isLowerHex) else { return nil }
        return crc32Hex(b[..<(tail + 33)]).utf8.elementsEqual(b[(tail + 34)...]) ? env : nil
    }

    private static func isLowerAlnum(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
    }

    private static func isLowerHex(_ c: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(c)
    }

    /// CRC-32/IEEE（反射多项式 0xEDB88320，init / xorout 0xFFFFFFFF；系统 zlib 的 `crc32`），8 位小写十六进制。
    static func crc32Hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let v = Array(bytes).withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) }
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }

    /// 服务端 reason 清洗：只留 `[a-z0-9_]`、最多 40 字符；清洗后为空写 `unknown`。
    static func sanitizeReason(_ r: String) -> String {
        var out = String.UnicodeScalarView()
        for c in r.unicodeScalars {
            guard out.count < 40 else { break }
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "_" { out.append(c) }
        }
        return out.isEmpty ? "unknown" : String(out)
    }

    /// 暂停时长向上取整到分钟。
    static func pauseMinutes(_ ms: Int64) -> Int64 {
        ms <= 0 ? 0 : (ms + 59_999) / 60_000
    }
}

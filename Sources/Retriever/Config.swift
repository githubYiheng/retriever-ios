import Foundation

/// 远程配置（方案 §5；packages/core/src/config.ts）。
struct RemoteConfig: Equatable, Sendable {
    var etag: String
    var ttlS: Int
    var uploadEnabled: Bool
    var uploadLevel: LogLevel
    var localLevel: LogLevel
    var contextLines: Int
    var contextBytes: Int
    var flushIntervalS: Int
    var localCapBytes: Int
    var fullDump: Bool
    var fullDumpTtlS: Int
    var dailyBatchCap: Int
}

/// 宿主在 configure 里给的默认（ADR 0004 / 0005）。`localLevel` / `dailyBatchCap` 可缺省。
struct HostDefaults: Sendable, Equatable {
    var uploadLevel: LogLevel
    var localLevel: LogLevel?
    var dailyBatchCap: Int?
    /// 宿主 `localCapBytes`（缓存过期时 local_cap 放大回落的目标；不参与 clampConfig）。
    var localCapBytes: Int = Limits.localCapBytesDefault

    init(uploadLevel: LogLevel, localLevel: LogLevel? = nil, dailyBatchCap: Int? = nil, localCapBytes: Int = Limits.localCapBytesDefault) {
        self.uploadLevel = uploadLevel
        self.localLevel = localLevel
        self.dailyBatchCap = dailyBatchCap
        self.localCapBytes = localCapBytes
    }

    init(_ o: Options) {
        uploadLevel = o.uploadLevel
        localLevel = o.localLevel
        dailyBatchCap = o.dailyBatchCap
        localCapBytes = ConfigRules.clampHostCap(o.localCapBytes)
    }
}

enum ConfigRules {
    /// full_dump_ttl_s 上限：覆盖默认 ttl × 7（= 7 天）。
    static let fullDumpTtlSMax = Limits.overrideTtlSDefault * 7

    /// `clampConfig` 逐字移植（config.ts）：越界取边界，类型错 / 未知枚举取默认；raw 非对象 → 全默认。
    static func clamp(_ raw: Any?, host: HostDefaults) -> RemoteConfig {
        let r: [String: Any] = (raw as? [String: Any]) ?? [:]
        let hostUpload = host.uploadLevel
        let hostLocal = host.localLevel ?? .debug
        let hostCap = clampInt(host.dailyBatchCap.map { Double($0) }, 0, Limits.dailyBatchCapMax, Limits.dailyBatchCapDefault)
        return RemoteConfig(
            etag: JSONIn.string(r["etag"]) ?? "",
            ttlS: clampInt(JSONIn.double(r["ttl_s"]), Limits.configTtlSMin, Limits.configTtlSMax, Limits.configTtlSDefault),
            uploadEnabled: JSONIn.bool(r["upload_enabled"]) ?? true,
            uploadLevel: level(r["upload_level"]) ?? hostUpload,
            localLevel: level(r["local_level"]) ?? hostLocal,
            contextLines: clampInt(JSONIn.double(r["context_lines"]), 0, Limits.ctxLinesMax, Limits.ctxLinesDefault),
            contextBytes: clampInt(JSONIn.double(r["context_bytes"]), 0, Limits.ctxBytesMax, Limits.ctxBytesDefault),
            flushIntervalS: clampInt(JSONIn.double(r["flush_interval_s"]), Limits.flushIntervalSMin, Limits.flushIntervalSMax, Limits.flushIntervalSDefault),
            localCapBytes: clampInt(JSONIn.double(r["local_cap_bytes"]), Limits.localCapBytesMin, Limits.localCapBytesMax, Limits.localCapBytesDefault),
            fullDump: JSONIn.bool(r["full_dump"]) ?? false,
            fullDumpTtlS: clampInt(JSONIn.double(r["full_dump_ttl_s"]), 0, fullDumpTtlSMax, 0),
            dailyBatchCap: clampInt(JSONIn.double(r["daily_batch_cap"]), 0, Limits.dailyBatchCapMax, hostCap)
        )
    }

    static func level(_ v: Any?) -> LogLevel? {
        guard let s = v as? String else { return nil }
        return LogLevel(rawValue: s)
    }

    /// 有限 number 先向下取整再夹到 [min, max]（按浮点比较，避免大数溢出）；其它一律取默认。
    static func clampInt(_ x: Double?, _ min: Int, _ max: Int, _ dflt: Int) -> Int {
        guard let x, x.isFinite else { return dflt }
        let v = x.rounded(.down)
        if v <= Double(min) { return min }
        if v > Double(max) { return max }
        return Int(v)
    }

    static func clampHostCap(_ v: Int) -> Int {
        Swift.min(Swift.max(v, Limits.localCapBytesMin), Limits.localCapBytesMax)
    }

    /// 序列化成与服务端同名字段的 JSON（缓存到 config.json）。
    static func encode(_ c: RemoteConfig) -> [UInt8] {
        var o = JSONOut()
        o.raw("{\"etag\":"); o.string(c.etag)
        o.raw(",\"ttl_s\":"); o.int(c.ttlS)
        o.raw(",\"upload_enabled\":"); o.bool(c.uploadEnabled)
        o.raw(",\"upload_level\":"); o.string(c.uploadLevel.rawValue)
        o.raw(",\"local_level\":"); o.string(c.localLevel.rawValue)
        o.raw(",\"context_lines\":"); o.int(c.contextLines)
        o.raw(",\"context_bytes\":"); o.int(c.contextBytes)
        o.raw(",\"flush_interval_s\":"); o.int(c.flushIntervalS)
        o.raw(",\"local_cap_bytes\":"); o.int(c.localCapBytes)
        o.raw(",\"full_dump\":"); o.bool(c.fullDump)
        o.raw(",\"full_dump_ttl_s\":"); o.int(c.fullDumpTtlS)
        o.raw(",\"daily_batch_cap\":"); o.int(c.dailyBatchCap)
        o.raw("}")
        return o.bytes
    }
}

/// 配置请求时的身份（ADR 0019 决定 12）：响应只在它仍等于当前身份时缓存并生效。
struct ConfigIdentity: Equatable, Sendable {
    var installId: String
    var userId: String?
}

/// 生效配置：缓存 + 到期回落（§5）。
struct EffectiveConfig: Equatable, Sendable {
    var config: RemoteConfig
    var fullDumpActive: Bool
    /// 生效 upload_level（full_dump 生效期间降为 debug）。
    var uploadLevel: LogLevel
    var expired: Bool
}

/// 缓存的远程配置。单调时钟只在本进程内有效；跨进程（重启）用墙钟兜底。
struct ConfigCache: Sendable {
    var config: RemoteConfig
    var fetchedWallMs: Int64
    /// 本进程拉到时的单调时刻；从文件恢复的缓存为 nil（改用墙钟）。
    var fetchedMonoMs: Int64?
    /// 身份（install_id, user_id）变了（ADR 0019 决定 12）：这份配置属于上一个身份，按过期处理直到新身份的响应到达
    /// （新响应是新的缓存对象，标志随之清掉）。只在内存，不写进 config.json。
    var identityStale = false

    func elapsedMs(nowWall: Int64, nowMono: Int64) -> Int64 {
        if let m = fetchedMonoMs { return nowMono - m }
        return nowWall - fetchedWallMs
    }

    /// 生效配置：过期后放大型字段（full_dump、低于宿主默认的 upload_level、高于默认的 context_*、
    /// 低于默认的 flush_interval、高于宿主默认的 local_cap）回落到宿主默认 / 内置默认（宪法 U-2）。
    /// 只是身份过期（TTL 未到）时 local_cap 不回落：它决定本地已有数据的去留、不放大上传，回落会把超出宿主默认的义务批当
    /// buffer_overflow 驱逐。
    static func effective(_ cache: ConfigCache?, host: HostDefaults, nowWall: Int64, nowMono: Int64) -> EffectiveConfig {
        guard let cache else {
            var c = ConfigRules.clamp([String: Any](), host: host)
            c.localCapBytes = host.localCapBytes
            return EffectiveConfig(config: c, fullDumpActive: false, uploadLevel: c.uploadLevel, expired: true)
        }
        var c = cache.config
        let elapsed = cache.elapsedMs(nowWall: nowWall, nowMono: nowMono)
        let ttlExpired = elapsed < 0 || elapsed >= Int64(c.ttlS) * 1000
        let expired = cache.identityStale || ttlExpired
        if expired {
            c.fullDump = false
            c.fullDumpTtlS = 0
            if c.uploadLevel < host.uploadLevel { c.uploadLevel = host.uploadLevel }
            if c.contextLines > Limits.ctxLinesDefault { c.contextLines = Limits.ctxLinesDefault }
            if c.contextBytes > Limits.ctxBytesDefault { c.contextBytes = Limits.ctxBytesDefault }
            if c.flushIntervalS < Limits.flushIntervalSDefault { c.flushIntervalS = Limits.flushIntervalSDefault }
            if ttlExpired && c.localCapBytes > host.localCapBytes { c.localCapBytes = host.localCapBytes }
        }
        let fullDumpActive = c.fullDump && elapsed >= 0 && elapsed < Int64(c.fullDumpTtlS) * 1000
        return EffectiveConfig(config: c, fullDumpActive: fullDumpActive,
                               uploadLevel: fullDumpActive ? .debug : c.uploadLevel, expired: expired)
    }

    /// 下一次生效配置可能变化的单调时刻（过期 / full_dump 到期），供调度器唤醒。
    func nextChangeMono(nowWall: Int64, nowMono: Int64) -> Int64? {
        if identityStale { return nil }
        let elapsed = elapsedMs(nowWall: nowWall, nowMono: nowMono)
        var cands: [Int64] = []
        let ttl = Int64(config.ttlS) * 1000
        if elapsed < ttl { cands.append(nowMono + (ttl - elapsed)) }
        if config.fullDump {
            let fd = Int64(config.fullDumpTtlS) * 1000
            if elapsed < fd { cands.append(nowMono + (fd - elapsed)) }
        }
        return cands.min()
    }
}

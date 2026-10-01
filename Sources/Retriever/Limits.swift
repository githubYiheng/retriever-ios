// 线上限与默认值：逐字取自 packages/core/src/limits.ts（改数 = 改契约，同 commit 改方案）。
enum Limits {
    // ---- 单行（§3.1）----
    static let lineMsgBytes = 4096
    static let lineTagBytes = 64
    static let lineAttrsKeys = 32
    static let lineAttrsBytes = 4096
    static let lineExcTypeBytes = 256
    static let lineExcMessageBytes = 1024
    static let lineExcStackBytes = 16 * 1024
    static let lineExcStackHeadBytes = 8 * 1024
    static let lineExcStackTailBytes = 8 * 1024
    static let lineSerializedBytes = 16 * 1024

    // ---- 段与批（§3.4 / §3.5）----
    static let segmentBytes = 512 * 1024
    static let batchUncompressedBytesClient = 768 * 1024
    static let ctxLinesDefault = 200
    static let ctxLinesMax = 500
    static let ctxBytesDefault = 128 * 1024
    static let ctxBytesMax = 256 * 1024
    static let dropsPerBatch = 100
    static let closedSessionsPerBatch = 20
    static let userIdBytes = 128
    static let processBytes = 64
    static let deviceFieldBytes = 128

    // ---- 日期（§4）----
    static let dayClampPastDaysClient = 30

    // ---- 队列与退避（§3.7）----
    static let minRequestSpacingMs: Int64 = 2000
    static let backoffBaseMs: Int64 = 1000
    static let backoffMaxMs: Int64 = 15 * 60 * 1000
    static let backoffJitter = 0.2
    static let retryAfterMinS = 1
    static let retryAfterMaxS = 3600
    static let pause401BaseMs: Int64 = 60 * 60 * 1000
    static let pause401MaxMs: Int64 = 24 * 60 * 60 * 1000
    static let poisonConsecutiveFails = 5
    static let errorDebounceMs: Int64 = 2000
    static let errorSealMinIntervalMs: Int64 = 10_000
    static let ringMaxAgeDays = 7

    // ---- 远程配置默认与钳制（§5）----
    static let flushIntervalSDefault = 300
    static let flushIntervalSMin = 30
    static let flushIntervalSMax = 3600
    static let localCapBytesDefault = 20 * 1024 * 1024
    static let localCapBytesMin = 2 * 1024 * 1024
    static let localCapBytesMax = 100 * 1024 * 1024
    static let dailyBatchCapDefault = 0
    static let dailyBatchCapMax = 10_000
    static let configTtlSDefault = 1800
    static let configTtlSMin = 60
    static let configTtlSMax = 86_400
    static let overrideTtlSDefault = 86_400
    static let configPollIntervalS = 1800
    static let mappingRefreshMs: Int64 = 24 * 60 * 60 * 1000
}

/// 方案正文里有、limits.ts 未收录的客户端数字（§3.2 / §3.6 / §3.7 / §3.8）。
enum ClientConstants {
    /// §3.8 `drops.jsonl` 自身上限：超出先无损合并，仍超出删最旧的未在途条目（ADR 0019 决定 4）。
    static let dropsFileMaxEntries = 1000
    /// `sessions.jsonl` 自身上限：超出删最旧的未在途条目（ADR 0019 决定 3）。
    static let sessionsFileMaxEntries = 1000
    /// 禁用标记没写成时的重试间隔（ADR 0020 决定 2：每次调度 tick 重试，这里保证有 tick）。
    static let markerRetryMs: Int64 = 60_000
    /// §3.8 可用空间余量。
    static let diskReserveBytes: Int64 = 64 * 1024 * 1024
    /// §3.7 隔离批 24 h 后再试。
    static let quarantineRetryMs: Int64 = 24 * 60 * 60 * 1000
    /// §3.7 传输请求超时。
    static let requestTimeoutS: Double = 30
    /// 调度器地板：任何候选已到期时也至少等 1 s，杜绝 0 ms 自旋（发版前审查 H2）。
    static let schedulerMinDelayMs: Int64 = 1000
    /// configure 之前的 pre 文件上限（ADR 0023；含头记录）：追加后会超过它的记录不写、计数（之后整个文件不再写）。
    static let preFileMaxBytes: Int64 = 1024 * 1024
    /// 从不 configure 的宿主：进程内首次建 pre 文件之前，没有活持有者的旧 pre 文件总量 / 个数超过它们时从 mtime 最旧的删起（R-5）。
    static let preDirMaxBytes: Int64 = 4 * 1024 * 1024
    static let preDirMaxFiles = 8
    /// 不属于活进程且 mtime 超过它的 pre 文件在驱逐时删除（R-5）。
    static let preOrphanMaxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// fatal 节流窗口（ADR 0024 决定 8）：距上一次 fatal 强制换段不足它的 fatal 行不强制换段、并入 error 去抖。
    static let fatalWindowMs: Int64 = 10_000
    /// 收编 / 重新 bootstrap 未完成时的重试间隔。
    static let adoptionRetryMs: Int64 = 5_000
    /// §3.1 stack 超长时中间插入的标记。
    static let stackMarker = "\n…[truncated]…\n"
    static let dayMs: Int64 = 24 * 60 * 60 * 1000
}

import Foundation
#if canImport(os)
import os
#endif

/// 配置诊断的出口（ADR 0025；简报 §13；检查见 `ConfigCheck`）：系统日志
/// `os.Logger(subsystem: "org.revdog.retriever", category: "diagnostics")`，`no_key` 用 `.info`、其余 `.notice`，
/// 消息 `.public`。同一（code, key 指纹, baseURL）每进程最多一次。出口抛任何东西都吞掉；调用方不得持任何 SDK 锁、不在 work 队列上。
/// 禁用（`setEnabled(false)` / 盘上标记）时照常出——接入者正需要看。
enum ConfigDiagnostics {
    static let subsystem = "org.revdog.retriever"
    static let category = "diagnostics"
    /// 测试替换出口用：收到 (code, message)。
    typealias Sink = @Sendable (String, String) throws -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: Set<String> = []
    nonisolated(unsafe) private static var sink: Sink?

    static func emit(_ d: ConfigCheck.Diagnostic, keyFp: String, baseURL: String) {
        lock.lock()
        let first = seen.insert(d.code + "\n" + keyFp + "\n" + baseURL).inserted
        let s = sink
        lock.unlock()
        guard first else { return }
        let message = d.message
        do {
            if let s { try s(d.code, message) } else { system(d, message) }
        } catch {}
    }

    private static func system(_ d: ConfigCheck.Diagnostic, _ message: String) {
        #if canImport(os)
        let log = os.Logger(subsystem: subsystem, category: category)
        if d == .noKey {
            log.info("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
        #endif
    }

    /// 测试：替换出口（nil = 回到系统日志）。
    static func setSinkForTesting(_ s: Sink?) {
        lock.lock(); defer { lock.unlock() }
        sink = s
    }

    /// 测试：清空去重集合并复位出口。
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        seen = []
        sink = nil
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 出站队列与响应分类（§3.6 / §3.7，宪法 R-2 / R-3）。决策在 work 队列上，网络在队列外。
extension Engine {
    enum SendStep {
        case send(name: String, request: HTTPRequest)
        case stop(reason: String, wakeMono: Int64?)
    }

    struct ResponseEffect {
        var fetchConfig = false
        var acked = false
    }

    /// 选下一批：p0 > p1 > p2，同级 created_ms 升序（失败过的批让到后面，避免头阻塞）；单在途；相邻请求 ≥ 2 s；
    /// 全局或对应类别未暂停。
    func nextSend() -> SendStep {
        let nowMono = clock.monoMs()
        if key.isEmpty { return .stop(reason: "not_configured", wakeMono: nil) }
        if !enabled { return .stop(reason: "disabled", wakeMono: nil) }
        if !effective.config.uploadEnabled { return .stop(reason: "upload_disabled", wakeMono: nil) }
        let pauseActive = backoff.pausedUntilMono > nowMono
        if pauseActive && backoff.pausedCategories.contains("all") {
            return .stop(reason: "paused", wakeMono: backoff.pausedUntilMono)
        }
        if backoff.nextAtMonoMs > nowMono {
            return .stop(reason: backoff.reason == "network" ? "offline" : "backoff", wakeMono: backoff.nextAtMonoMs)
        }
        if let last = lastRequestMono, nowMono < last + Limits.minRequestSpacingMs {
            return .stop(reason: "spacing", wakeMono: last + Limits.minRequestSpacingMs)
        }
        reconcileOutbox()
        let candidates = metas.values.filter { $0.prio < 3 }
        if candidates.isEmpty { return .stop(reason: "empty", wakeMono: nil) }
        let pausedCats = pauseActive ? Set(backoff.pausedCategories) : []
        let eligible = candidates.filter { m in
            if let c = m.category, pausedCats.contains(c) { return false }
            return true
        }.sorted {
            let f0 = (fails[$0.name]?.count ?? 0) > 0 ? 1 : 0
            let f1 = (fails[$1.name]?.count ?? 0) > 0 ? 1 : 0
            return (f0, $0.prio, $0.createdMs, $0.name) < (f1, $1.prio, $1.createdMs, $1.name)
        }
        // candidates 非空时 eligible 为空只可能是类别暂停
        guard let pick = eligible.first else { return .stop(reason: "paused", wakeMono: backoff.pausedUntilMono) }
        guard acquireUploadLock() else { return .stop(reason: "locked", wakeMono: nowMono + 60_000) }
        guard let body = FS.read(outboxDir.appendingPathComponent(pick.name)), let inst = install else {
            metas.removeValue(forKey: pick.name)
            return nextSend()
        }
        let req = HTTPRequest(method: "POST", url: baseURL.appendingPathComponent("v1/batches"), headers: [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "Content-Encoding": "gzip",
            "X-Rtv-Install": inst.installId,
            "X-Rtv-Sent-Ms": String(clock.wallMs()),
            "X-Rtv-Sdk": sdkHeader,
        ], body: Data(body))
        inFlight = pick.name
        lastRequestMono = nowMono
        return .send(name: pick.name, request: req)
    }

    // MARK: 上传锁（多进程：只有拿到 upload.lock 的一方排空；进后台前释放）

    func acquireUploadLock() -> Bool {
        if uploadLockFd >= 0 { return true }
        let fd = open(uploadLockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        FS.markFile(uploadLockURL)
        uploadLockFd = fd
        return true
    }

    func releaseUploadLock() {
        guard uploadLockFd >= 0 else { return }
        flock(uploadLockFd, LOCK_UN)
        close(uploadLockFd)
        uploadLockFd = -1
    }

    // MARK: 响应分类

    func handleResponse(name: String, response: HTTPResponse?) -> ResponseEffect {
        var eff = ResponseEffect()
        if inFlight == name { inFlight = nil }
        guard let meta = metas[name] else { return eff }
        guard let r = response else {
            failure(name, retryAfterS: nil, reason: "network", countFail: true)
            return eff
        }
        let body = JSONIn.object(r.body)
        switch r.status {
        case 200..<300:
            // 回显的 batch_id 与本批一致才算确认（防 captive portal）；stored 与 quarantined 都算
            if let b = body, (b["batch_id"] as? String) == meta.batchId {
                ack(meta)
                eff.acked = true
                if let e = b["config_etag"] as? String, e != (configCache?.config.etag ?? "") { eff.fetchConfig = true }
            } else {
                failure(name, retryAfterS: nil, reason: "echo_mismatch", countFail: true)
            }
        case 401, 403:
            authPause(reason: (body?["reason"] as? String) ?? String(r.status))
        case 413:
            split413(name)
        case 429:
            categoryPause(body: body, header: r.headers["retry-after"])
        case 503:
            failure(name, retryAfterS: Engine.retryAfter(body: body, header: r.headers["retry-after"]), reason: "http_503", countFail: false)
        default:
            failure(name, retryAfterS: nil, reason: "http_\(r.status)", countFail: true)
        }
        return eff
    }

    static func retryAfter(body: [String: Any]?, header: String?) -> Int? {
        // 饱和到 [0, 86 400]：服务端若回 1e300 之类，`Int(v)` 会直接 trap（Android 版同样饱和）。
        if let v = JSONIn.double(body?["retry_after_s"]), v.isFinite { return Int(min(max(v, 0), 86_400)) }
        if let h = header, let v = Int(h.trimmingCharacters(in: .whitespaces)) { return min(max(v, 0), 86_400) }
        return nil
    }

    static func clampRetryAfterMs(_ s: Int) -> Int64 {
        Int64(min(max(s, Limits.retryAfterMinS), Limits.retryAfterMaxS)) * 1000
    }

    static func jitter(_ ms: Int64) -> Int64 {
        Int64((Double(ms) * Double.random(in: (1 - Limits.backoffJitter)...(1 + Limits.backoffJitter))).rounded())
    }

    /// backoff(attempt) = min(1 s × 2^attempt, 15 min) × (1 ± 20%)
    static func backoffMs(attempt: Int) -> Int64 {
        let shift = min(attempt, 30)
        let base = min(Limits.backoffBaseMs << Int64(shift), Limits.backoffMaxMs)
        return jitter(base)
    }

    private func ack(_ meta: BatchMeta) {
        let nowWall = clock.wallMs()
        FS.remove(outboxDir.appendingPathComponent(meta.name))
        metas.removeValue(forKey: meta.name)
        fails.removeValue(forKey: meta.name)
        for k in fails.keys { fails[k]?.otherSuccess = true }
        if meta.kind == .primary && meta.oseqFrom > 0 {
            ackedRanges.append((meta.sessionId, meta.oseqFrom, meta.oseqTo))
            if ackedRanges.count > 512 { ackedRanges.removeFirst(ackedRanges.count - 512) }
        }
        // 删已报墓碑与会话终态（按原样匹配）
        if !meta.drops.isEmpty || !meta.closed.isEmpty {
            FS.withDirLock(root) {
                if !meta.drops.isEmpty {
                    let gone = Set(meta.drops)
                    let rest = readDropsLocked().filter { !gone.contains($0) }
                    FS.writeAtomic(dropsURL, JSONL.encodeDrops(rest))
                }
                if !meta.closed.isEmpty {
                    let gone = Set(meta.closed.map(\.sessionId))
                    let rest = readClosedLocked().filter { !gone.contains($0.sessionId) }
                    FS.writeAtomic(sessionsURL, JSONL.encodeClosed(rest))
                }
            }
            embeddedDrops.subtract(meta.drops)
            embeddedClosed.subtract(meta.closed.map(\.sessionId))
        }
        if let u = meta.mappingUser, let d = meta.mappingDigest {
            let m = MappingState(userId: u, deviceDigest: d, ackedMs: nowWall)
            mapping = m
            FS.writeAtomic(mappingURL, m.encode())
            if let p = pendingMapping, p.user == u, p.digest == d { pendingMapping = nil }
        }
        backoff.attempt = 0
        backoff.nextAtMonoMs = 0
        backoff.nextAtWallMs = 0
        backoff.lastAckMs = nowWall
        if !backoff.pausedCategories.contains("all") { backoff.reason = "" }
        persistBackoff()
    }

    /// 全局退避：next = now + max(clamp(Retry-After), backoff)；非 429 的失败计入该批 fail（毒批判定）。
    private func failure(_ name: String, retryAfterS: Int?, reason: String, countFail: Bool) {
        let nowMono = clock.monoMs()
        let nowWall = clock.wallMs()
        var wait = Engine.backoffMs(attempt: backoff.attempt)
        if let ra = retryAfterS { wait = max(wait, Engine.clampRetryAfterMs(ra)) }
        backoff.attempt += 1
        backoff.nextAtMonoMs = nowMono + wait
        backoff.nextAtWallMs = nowWall + wait
        if !backoff.reason.hasPrefix("auth:") { backoff.reason = reason }
        persistBackoff()
        guard countFail else { return }
        var f = fails[name] ?? (0, false)
        f.count += 1
        fails[name] = f
        // 同一批连续 5 次非 429 失败、且期间有别的批成功过 → 隔离；所有批都在失败则视为服务端故障，不隔离
        if f.count >= Limits.poisonConsecutiveFails && f.otherSuccess { quarantine(name) }
    }

    /// 401 / 403：全局暂停 1 h 起倍增到 24 h；照常写本地、照常拉配置；不删任何文件。
    private func authPause(reason: String) {
        let prev: Int64? = backoff.reason.hasPrefix("auth:") ? Int64(backoff.reason.dropFirst(5)) : nil
        let dur = prev.map { min($0 * 2, Limits.pause401MaxMs) } ?? Limits.pause401BaseMs
        backoff.pausedCategories = ["all"]
        backoff.pausedUntilMono = clock.monoMs() + dur
        backoff.pausedUntilMs = clock.wallMs() + dur
        backoff.reason = "auth:\(dur)"
        persistBackoff()
    }

    /// 429：按 categories 暂停到 now + retry_after_s（单调；钳制 1 s–1 h；±20% 抖动）；`all` = 全局。不计毒批。
    private func categoryPause(body: [String: Any]?, header: String?) {
        let ra = Engine.retryAfter(body: body, header: header) ?? 60
        let wait = Engine.jitter(Engine.clampRetryAfterMs(ra))
        let cats = ((body?["categories"] as? [Any]) ?? []).compactMap { $0 as? String }
        let known = cats.filter { $0 == "info" || $0 == "backfill" }
        backoff.pausedCategories = (cats.contains("all") || known.isEmpty) ? ["all"] : known
        backoff.pausedUntilMono = clock.monoMs() + wait
        backoff.pausedUntilMs = clock.wallMs() + wait
        if !backoff.reason.hasPrefix("auth:") { backoff.reason = "429:\((body?["reason"] as? String) ?? "")" }
        persistBackoff()
    }

    /// 排空的下一次唤醒（退避 / 暂停到期）。
    func uploadWakeMono() -> Int64? {
        guard !key.isEmpty, enabled, effective.config.uploadEnabled else { return nil }
        guard metas.values.contains(where: { $0.prio < 3 }) else { return nil }
        let now = clock.monoMs()
        var w: [Int64] = []
        if backoff.nextAtMonoMs > now { w.append(backoff.nextAtMonoMs) }
        if backoff.pausedUntilMono > now { w.append(backoff.pausedUntilMono) }
        if let l = lastRequestMono, l + Limits.minRequestSpacingMs > now { w.append(l + Limits.minRequestSpacingMs) }
        return w.max()
    }

    // MARK: 远程配置（§5）

    func configRequest() -> HTTPRequest? {
        guard !key.isEmpty, let inst = install else { return nil }
        var h: [String: String] = [
            "Authorization": "Bearer \(key)",
            "X-Rtv-Install": inst.installId,
            "X-Rtv-Sdk": sdkHeader,
            "X-Rtv-App-Version": device.appVersion,
            "X-Rtv-Upload-Level": host.uploadLevel.rawValue,
            "X-Rtv-Local-Level": (host.localLevel ?? .debug).rawValue,
            "X-Rtv-Daily-Batch-Cap": String(host.dailyBatchCap ?? 0),
            "X-Rtv-Local-Cap-Bytes": String(host.localCapBytes),
        ]
        if let u = writer.currentUser {
            // 值一律 percent-encode（ASCII 字母数字以外全部编码，服务端 decodeURIComponent）
            h["X-Rtv-User"] = u.addingPercentEncoding(withAllowedCharacters: Engine.asciiAlnum) ?? ""
        }
        return HTTPRequest(method: "GET", url: baseURL.appendingPathComponent("v1/config"), headers: h, body: nil)
    }

    static let asciiAlnum = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// 拉到配置：钳制后缓存并生效；拉不到 / 非 200 / 非对象 → 用缓存（不放大）。
    func applyConfigResponse(_ r: HTTPResponse?) -> ConfigEffect {
        lastConfigFetchMono = clock.monoMs()
        guard let r, r.status == 200, let o = JSONIn.object(r.body) else { return ConfigEffect() }
        let cfg = ConfigRules.clamp(o, host: host)
        let nowWall = clock.wallMs()
        configCache = ConfigCache(config: cfg, fetchedWallMs: nowWall, fetchedMonoMs: clock.monoMs())
        var file = JSONOut()
        file.raw("{\"fetched_ms\":"); file.int(nowWall)
        file.raw(",\"config\":"); file.raw(ConfigRules.encode(cfg))
        file.raw("}")
        FS.writeAtomic(configURL, file.bytes)
        return applyEffective()
    }

    struct ConfigEffect {
        var sealed = false
        var backfill = false
    }

    /// 重新计算生效配置并推给写入侧；full_dump 生效 / upload_enabled 变化触发封段，full_dump 生效生成 backfill。
    @discardableResult
    func applyEffective() -> ConfigEffect {
        var eff = ConfigEffect()
        let old = effective
        effective = ConfigCache.effective(configCache, host: host, nowWall: clock.wallMs(), nowMono: clock.monoMs())
        writer.setLevels(upload: effective.uploadLevel, local: effective.config.localLevel, flushIntervalS: effective.config.flushIntervalS)
        if !old.fullDumpActive && effective.fullDumpActive {
            writer.rotate(.fullDump)
            processSeals()
            materializeBackfill()
            eff.sealed = true
            eff.backfill = true
        }
        if old.config.uploadEnabled != effective.config.uploadEnabled {
            if writer.rotate(.uploadEnabled) { processSeals() }
            eff.sealed = true
        }
        if old.config.localCapBytes != effective.config.localCapBytes { evictIfNeeded() }
        return eff
    }

    func configPollDue(nowMono: Int64) -> Bool {
        guard !key.isEmpty else { return false }
        guard let l = lastConfigFetchMono else { return true }
        return nowMono - l >= Int64(Limits.configPollIntervalS) * 1000
    }
}

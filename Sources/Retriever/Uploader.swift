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
    /// 全局或对应类别未暂停。读不出的批跳过、试下一个（不递归：出站箱每轮都会把它重新载回）。
    func nextSend() -> SendStep {
        let nowMono = clock.monoMs()
        if key.isEmpty { return .stop(reason: "not_configured", wakeMono: nil) }
        if !uploadAllowed() { return .stop(reason: "disabled", wakeMono: nil) }
        // 未 bootstrap（install.json 读改写失败）：不碰磁盘，等 retryBootstrap
        guard let inst = install else { return .stop(reason: "not_bootstrapped", wakeMono: nil) }
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
        if eligible.isEmpty { return .stop(reason: "paused", wakeMono: backoff.pausedUntilMono) }
        guard acquireUploadLock() else { return .stop(reason: "locked", wakeMono: nowMono + 60_000) }
        for pick in eligible {
            // 读不出（fd 耗尽、保护类异常等）：跳过，不删、不隔离、不计 fail；留在出站箱下一轮再试，最终由容量驱逐兜底
            guard let body = FS.read(outboxDir.appendingPathComponent(pick.name)) else { continue }
            // 请求头取批自身信封里的 install_id（ADR 0019 决定 10）：多进程 purge 窗口里别的进程写进来的批按自己的归属上报
            let req = HTTPRequest(method: "POST", url: baseURL.appendingPathComponent("v1/batches"), headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json",
                "Content-Encoding": "gzip",
                "X-Rtv-Install": pick.installId.isEmpty ? inst.installId : pick.installId,
                "X-Rtv-Sent-Ms": String(clock.wallMs()),
                "X-Rtv-Sdk": sdkHeader,
            ], body: Data(body))
            inFlight = pick.name
            lastRequestMono = nowMono
            return .send(name: pick.name, request: req)
        }
        return .stop(reason: "unreadable", wakeMono: nil)
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
                ack(meta, stored: (b["status"] as? String) == "stored")
                eff.acked = true
                if let e = b["config_etag"] as? String, e != (configCache?.config.etag ?? "") { eff.fetchConfig = true }
            } else {
                failure(name, retryAfterS: nil, reason: "echo_mismatch", countFail: true)
            }
        case 401, 403:
            // 只认服务端的明确表态（JSON 对象且 reason 是字符串，未知值同样算）；边缘 / WAF / captive portal 替服务端回的
            // 401 / 403（HTML、空体、无 reason）按「其它」：全局退避 + 计毒批（ADR 0011）
            if let reason = body?["reason"] as? String {
                authPause(reason: reason)
            } else {
                failure(name, retryAfterS: nil, reason: "http_\(r.status)", countFail: true)
            }
        case 413:
            // 切分写不出（磁盘满等）：原批保留，按普通失败退避（不计毒批，批本身没错），免得每 2 s 重发一次再 413
            if !split413(name) { failure(name, retryAfterS: nil, reason: "http_413", countFail: false) }
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

    private func ack(_ meta: BatchMeta, stored: Bool) {
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
            // 服务端只在 stored 时写 D1 映射：隔离回的 200 不算映射已确认；别的 install 的批也不算（ADR 0019 决定 10）。
            // 在途标记照样清掉，下一批重新带映射
            if stored && meta.installId == install?.installId {
                let m = MappingState(userId: u, deviceDigest: d, ackedMs: nowWall)
                mapping = m
                FS.writeAtomic(mappingURL, m.encode())
            }
            if let p = pendingMapping, p.user == u, p.digest == d { pendingMapping = nil }
        }
        backoff.attempt = 0
        backoff.nextAtMonoMs = 0
        backoff.nextAtWallMs = 0
        backoff.lastAckMs = nowWall
        // 任何 2xx 都复位暂停倍增状态（ADR 0011）：已到期的暂停一并清掉；仍在生效的类别暂停（info / backfill）不动
        backoff.reason = ""
        if backoff.pausedUntilMono <= clock.monoMs() {
            backoff.pausedCategories = []
            backoff.pausedUntilMono = 0
            backoff.pausedUntilMs = 0
        }
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

    /// 带 reason 的 401 / 403：全局暂停 1 h 起倍增到 24 h（2xx 确认后复位）；照常写本地、照常拉配置；不删任何文件。
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

    /// 配置请求与它所属的身份；未配置 key、未 bootstrap、禁用（内存开关或盘上标记）时不拉（ADR 0020 决定 2）。
    func configRequest() -> (request: HTTPRequest, identity: ConfigIdentity)? {
        guard !key.isEmpty, uploadAllowed(), let inst = install else { return nil }
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
        let user = writer.currentUser
        if let u = user {
            // 值一律 percent-encode（ASCII 字母数字以外全部编码，服务端 decodeURIComponent）
            h["X-Rtv-User"] = u.addingPercentEncoding(withAllowedCharacters: Engine.asciiAlnum) ?? ""
        }
        // 发起即记尝试时刻（响应回来再记一次）：在途期间轮询候选不会停在过去，调度器不空转
        lastConfigFetchMono = clock.monoMs()
        return (HTTPRequest(method: "GET", url: baseURL.appendingPathComponent("v1/config"), headers: h, body: nil),
                ConfigIdentity(installId: inst.installId, userId: user))
    }

    static let asciiAlnum = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// 当前身份 (install_id, user_id)；未 bootstrap 为 nil。
    var configIdentity: ConfigIdentity? {
        install.map { ConfigIdentity(installId: $0.installId, userId: writer.currentUser) }
    }

    /// 身份变了（setUser 值变化）：缓存从此刻起按过期处理，放大型字段立即回落保守默认（ADR 0019 决定 12）；
    /// 不动拉取时刻（local_cap 只随真正的 TTL 过期回落）。
    func expireConfigForNewIdentity() {
        guard configCache != nil else { return }
        configCache?.identityStale = true
        applyEffective()
    }

    /// 拉到配置：钳制后缓存并生效；拉不到 / 非 200 / 非对象 → 用缓存（不放大）。
    /// 配置属于请求时的身份：请求发出后身份变了（setUser / purge）的响应丢弃，`stale` 让调用方按新身份重拉（ADR 0019 决定 12）。
    func applyConfigResponse(_ r: HTTPResponse?, requestedFor identity: ConfigIdentity) -> ConfigEffect {
        lastConfigFetchMono = clock.monoMs()
        guard configIdentity == identity else { return ConfigEffect(stale: true) }
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
        /// 响应属于旧身份、已丢弃：按当前身份重拉。
        var stale = false
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

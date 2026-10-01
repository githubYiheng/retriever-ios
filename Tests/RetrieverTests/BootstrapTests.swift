import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// bootstrap 失败与 install.json 损坏（发版前审查 A1；ADR 0019 决定 6–9）：未 bootstrap 时排空不递归、不碰磁盘；
/// 读到了但解析不了 = 损坏 → 从会话 meta 的冗余副本修复身份（不换 id），无副本才清空后新建，均留痕；
/// 读不到（首次解锁前 / 权限）→ 绝不重建，稍后重试沿用原 install_id。
final class BootstrapTests: XCTestCase {
    func metaURLs(_ root: URL) -> [URL] {
        FS.list(root).filter { $0.hasPrefix("proc-") }.flatMap { p -> [URL] in
            let pdir = root.appendingPathComponent(p)
            return FS.list(pdir).filter(IDs.isUuid).map { pdir.appendingPathComponent($0).appendingPathComponent("meta.json") }
        }.filter { FS.exists($0) }
    }

    /// 出站箱有批、install == nil → 排空停在 not_bootstrapped，批文件还在（修复前：递归到栈溢出）。
    func testDrainWithoutInstallStopsNotBootstrapped() async throws {
        let h = Harness()
        await h.settle()
        h.transport.defaultReply = .network
        h.client.log(.warn, "w")
        await h.sealAndDrain()
        let files = h.outboxFiles()
        XCTAssertEqual(files.count, 1)
        await h.work { $0.install = nil }
        await h.tick(advance: 60_000)
        XCTAssertEqual(h.client.debugLastStopReason, "not_bootstrapped")
        XCTAssertEqual(h.outboxFiles(), files)
        XCTAssertEqual(h.transport.batchRequests.count, 1)
    }

    /// install.json 是垃圾字节 / 0 字节，且没有任何带 install_id 的会话 meta（无副本，ADR 0019 决定 8）→ 清空后新建
    /// （新 install_id、计数器从 0 起），新会话首行是合成的 rtv.install_reset，attrs 带作废的出站箱批数 / 会话目录数。
    func testCorruptInstallJsonIsRegeneratedWithTrace() async throws {
        for bytes in [Array("{\"install_id\":\"not-a-uuid\"".utf8), []] {
            let root = makeTempDir()
            let a = Harness(root: root, key: "")
            await a.settle()
            let oldId = try XCTUnwrap(a.client.installId)
            a.client.simulateCrash()
            for m in metaURLs(root) { try FileManager.default.removeItem(at: m) }   // 无副本
            let url = root.appendingPathComponent("install.json")
            try Data(bytes).write(to: url)

            let b = Harness(root: root, key: "")
            await b.settle()
            let newId = try XCTUnwrap(b.client.installId, "bootstrap 成功")
            XCTAssertNotEqual(newId, oldId)
            XCTAssertTrue(IDs.isUuid(newId))
            let inst = try XCTUnwrap(InstallInfo.decode([UInt8](Data(contentsOf: url))))
            XCTAssertEqual(inst.installId, newId)
            XCTAssertEqual(inst.sessionCounter, 1)
            let ls = b.openSegmentLines()
            XCTAssertEqual(ls.count, 1)
            let l = try XCTUnwrap(ls.first)
            XCTAssertEqual(l["tag"] as? String, "rtv.install_reset")
            XCTAssertEqual(l["level"] as? String, "warn")
            XCTAssertEqual(l["msg"] as? String, "install.json unreadable; local state discarded")
            XCTAssertEqual(l["attrs"] as? [String: Int], ["batches": 0, "sessions": 1])
            XCTAssertEqual(l["synthetic"] as? Bool, true)
            XCTAssertEqual(int(l["oseq"]), 1, "warn ≥ 默认 upload_level：义务行，随批上报")

            // 此后正常重启沿用新 id，不再留痕
            b.client.simulateCrash()
            let c = Harness(root: root, key: "")
            await c.settle()
            XCTAssertEqual(c.client.installId, newId)
            XCTAssertEqual(c.client.debugCounters.seq, 0)
        }
    }

    /// install.json 存在但读不了 → 不重建（内容不变、bootstrap 失败）；期间回前台排空不崩；
    /// 可读后（首次解锁通知 → retryBootstrap）成功并沿用原 install_id，旧批照常上传。
    func testUnreadableInstallJsonIsNotRegenerated() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        let oldId = try XCTUnwrap(a.client.installId)
        a.client.log(.warn, "left in outbox")
        await a.seal()
        XCTAssertEqual(a.outboxFiles().count, 1)
        a.client.simulateCrash()
        let url = root.appendingPathComponent("install.json")
        let before = try Data(contentsOf: url)
        XCTAssertEqual(chmod(url.path, 0), 0)

        let b = Harness(root: root)
        await b.settle()
        XCTAssertNil(b.client.installId, "bootstrap 失败")
        b.client.platformEvent(.willEnterForeground)
        await b.settle()
        XCTAssertEqual(b.client.debugLastStopReason, "not_bootstrapped")
        XCTAssertEqual(b.transport.batchRequests.count, 0)
        XCTAssertEqual(b.transport.configRequests.count, 0, "未 bootstrap 不拉配置")
        XCTAssertEqual(b.outboxFiles().count, 1)

        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(try Data(contentsOf: url), before, "读失败时不重建")
        b.client.platformEvent(.protectedDataDidBecomeAvailable)
        await b.settle()
        XCTAssertEqual(b.client.installId, oldId)
        XCTAssertEqual(b.transport.batchRequests.first?.headers["X-Rtv-Install"], oldId)
        await b.tick(advance: Limits.minRequestSpacingMs)
        XCTAssertEqual(b.outboxFiles(), [], "旧批 + 恢复出的 unclean_exit 批都已确认")
        let inst = try XCTUnwrap(InstallInfo.decode([UInt8](Data(contentsOf: url))))
        XCTAssertEqual(inst.installId, oldId)
        XCTAssertEqual(inst.sessionCounter, 2)
    }

    /// install.json 损坏、会话 meta 带 install_id（ADR 0019 决定 6 / 7）：身份从 meta 修复、不换 id，计数续上；
    /// 旧会话的补报、出站箱旧批、映射都属于同一 install（修复前：换新 id，旧批请求头与信封不符、新 install 24 h 不发映射）。
    func testCorruptInstallJsonRepairsIdentityFromMeta() async throws {
        let root = makeTempDir()
        let a = Harness(root: root)
        await a.settle()
        let oldId = try XCTUnwrap(a.client.installId)
        a.client.log(.warn, "acked")
        await a.sealAndDrain()
        XCTAssertNotNil(a.json("mapping.json"), "已确认批：映射在")
        a.transport.defaultReply = .network
        a.clock.advance(Limits.minRequestSpacingMs)
        a.client.log(.warn, "left in outbox")
        await a.sealAndDrain()
        XCTAssertEqual(a.outboxFiles().count, 1)
        a.client.log(.warn, "unsealed")
        let aSid = a.client.writer.currentSessionId
        a.client.simulateCrash()                                   // 前台崩溃
        let meta = try XCTUnwrap(a.json("proc-main/\(aSid)/meta.json"))
        XCTAssertEqual(meta["install_id"] as? String, oldId, "meta 带 install 身份的冗余副本")
        let url = root.appendingPathComponent("install.json")
        try Data("garbage".utf8).write(to: url)

        let b = Harness(root: root, clock: a.clock)
        await b.settle()
        XCTAssertEqual(b.client.installId, oldId, "不换 id")
        let inst = try XCTUnwrap(InstallInfo.decode([UInt8](Data(contentsOf: url))))
        XCTAssertEqual(inst.installId, oldId)
        XCTAssertEqual(inst.sessionCounter, 2, "计数续上")
        XCTAssertTrue(b.client.supportCode?.hasSuffix("-2") ?? false)
        let l = try XCTUnwrap(b.openSegmentLines().first)
        XCTAssertEqual(l["tag"] as? String, "rtv.install_repaired")
        XCTAssertEqual(l["msg"] as? String, "install.json unreadable; identity repaired from session meta")
        XCTAssertEqual(l["level"] as? String, "warn")
        XCTAssertEqual(l["synthetic"] as? Bool, true)
        b.client.log(.warn, "b own")
        await b.seal()
        for _ in 0..<6 where !b.outboxFiles().isEmpty { await b.tick(advance: Limits.minRequestSpacingMs) }
        XCTAssertEqual(b.outboxFiles(), [])
        let envs = b.transport.batchRequests.map { ($0, decodeEnvelope($0.body ?? Data()) ?? [:]) }
        XCTAssertGreaterThanOrEqual(envs.count, 3, "旧批 + 旧会话补报 + 新会话")
        for (r, e) in envs {
            XCTAssertEqual(e["install_id"] as? String, oldId)
            XCTAssertEqual(r.headers["X-Rtv-Install"], oldId, "请求头 == 信封 install")
        }
        let own = try XCTUnwrap(envs.first { $0.1["session_id"] as? String == b.client.writer.currentSessionId }?.1)
        XCTAssertNil(own["mapping"], "映射仍属同一 install、24 h 内已确认：不重复发")
        XCTAssertTrue(envs.contains { ($0.1["closed_sessions"] as? [[String: Any]] ?? []).contains { $0["session_id"] as? String == aSid } })
    }

    /// install.json 损坏、只有 0.1.x 写的无 install_id 的 meta（无副本，ADR 0019 决定 8 / 9）：容器无法归属 → 整个清空后新建；
    /// 旧的终态 / 墓碑 / 映射 / 出站箱一概不带进新 install，作废数量写进合成行（修复前：旧状态挂到新 install 名下）。
    func testCorruptInstallJsonWithoutEvidencePurges() async throws {
        let root = makeTempDir()
        let a = Harness(root: root)
        await a.settle()
        let oldId = try XCTUnwrap(a.client.installId)
        a.client.log(.warn, "acked")
        await a.sealAndDrain()
        a.transport.defaultReply = .network
        a.clock.advance(Limits.minRequestSpacingMs)
        a.client.log(.warn, "left in outbox")
        await a.sealAndDrain()
        XCTAssertEqual(a.outboxFiles().count, 1)
        a.client.simulateCrash()
        // 0.1.x 形态：meta 没有 install_id；另有待报的终态与墓碑
        for m in metaURLs(root) {
            var sm = try XCTUnwrap(SessionMeta.decode([UInt8](Data(contentsOf: m))))
            sm.installId = nil
            try Data(sm.encode()).write(to: m)
        }
        FS.append(root.appendingPathComponent("sessions.jsonl"), JSONL.encodeClosed([
            ClosedSession(sessionId: IDs.newV4(), sessionNo: 9, startedMs: 1, endedMs: 2, lastSeq: 3, lastOseq: 3, exit: "clean_bg")]))
        FS.append(root.appendingPathComponent("drops.jsonl"), JSONL.encodeDrops([
            DropEntry(sessionId: IDs.newV4(), oseqFrom: 1, oseqTo: 2, n: 2, reason: "buffer_overflow", atMs: 1, lastAckAgeMs: -1)]))
        try Data("{".utf8).write(to: root.appendingPathComponent("install.json"))

        let b = Harness(root: root, key: "", clock: a.clock)
        await b.settle()
        let newId = try XCTUnwrap(b.client.installId)
        XCTAssertNotEqual(newId, oldId)
        for gone in ["mapping.json", "sessions.jsonl", "drops.jsonl", "backoff.json"] {
            XCTAssertFalse(FS.exists(root.appendingPathComponent(gone)), gone)
        }
        XCTAssertEqual(b.outboxFiles(), [])
        XCTAssertEqual(FS.list(root.appendingPathComponent("proc-main")), [b.client.writer.currentSessionId], "旧会话目录一并作废")
        XCTAssertEqual(purgeSiblings(root), [], "改名出去的旧 root 已删")
        let l = try XCTUnwrap(b.openSegmentLines().first)
        XCTAssertEqual(l["tag"] as? String, "rtv.install_reset")
        XCTAssertEqual(l["msg"] as? String, "install.json unreadable; local state discarded")
        XCTAssertEqual(l["attrs"] as? [String: Int], ["batches": 1, "sessions": 1])
        b.client.log(.warn, "fresh")
        await b.seal()
        let e = try XCTUnwrap(b.envelopes().first?.1)
        XCTAssertEqual(e["install_id"] as? String, newId)
        XCTAssertNotNil(e["mapping"], "新 install 首批带映射")
        XCTAssertNil(e["closed_sessions"], "无外来终态")
        XCTAssertNil(e["drops"], "无外来墓碑")
    }

    /// install.json 损坏、有 meta 存在却读不了 → 同「install.json 读不了」：本次失败、稍后重试，绝不重建；可读后按 meta 修复。
    func testUnreadableMetaDefersRepair() async throws {
        try XCTSkipIf(getuid() == 0, "root 无视文件权限")
        let root = makeTempDir()
        let a = Harness(root: root, key: "")
        await a.settle()
        let oldId = try XCTUnwrap(a.client.installId)
        a.client.simulateCrash()
        let meta = try XCTUnwrap(metaURLs(root).first)
        let url = root.appendingPathComponent("install.json")
        let garbage = Data("garbage".utf8)
        try garbage.write(to: url)
        XCTAssertEqual(chmod(meta.path, 0), 0)
        defer { chmod(meta.path, 0o600) }

        let b = Harness(root: root, key: "")
        await b.settle()
        XCTAssertNil(b.client.installId, "bootstrap 失败")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "绝不重建")
        XCTAssertEqual(chmod(meta.path, 0o600), 0)
        b.client.platformEvent(.protectedDataDidBecomeAvailable)
        await b.settle()
        XCTAssertEqual(b.client.installId, oldId)
    }

    /// 清空 = 先改名再删（ADR 0019 决定 9）：启动时清掉残留的 `<root>.purge-*`；purgeLocal 之后 root 下只有新 install 的文件。
    func testPurgeLeftoverIsCleaned() async throws {
        let root = makeTempDir()
        let leftover = Engine.sibling(of: root, suffix: ".purge-" + IDs.newV4())
        try FileManager.default.createDirectory(at: leftover.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leftover.appendingPathComponent("install.json"))
        let h = Harness(root: root, key: "")
        await h.settle()
        XCTAssertFalse(FS.exists(leftover))
        let oldId = h.client.installId
        h.client.log(.warn, "old")
        await h.seal()
        FS.append(root.appendingPathComponent("sessions.jsonl"), JSONL.encodeClosed([
            ClosedSession(sessionId: IDs.newV4(), sessionNo: 1, startedMs: 1, endedMs: 2, lastSeq: 1, lastOseq: 1, exit: "clean_bg")]))
        let newId = await purgeAndWait(h.client)
        XCTAssertNotEqual(newId, oldId)
        XCTAssertEqual(purgeSiblings(root), [])
        XCTAssertEqual(Set(FS.list(root)).subtracting(["install.json", "proc-main", "outbox", "config.json", "backoff.json", "upload.lock"]), [])
        XCTAssertEqual(FS.list(root.appendingPathComponent("proc-main")), [h.client.writer.currentSessionId])
        XCTAssertEqual(h.outboxFiles(), [])
        XCTAssertEqual(InstallInfo.decode([UInt8](try Data(contentsOf: root.appendingPathComponent("install.json"))))?.installId, newId)
    }
}

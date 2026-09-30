import Foundation
import XCTest
@testable @_spi(RetrieverTesting) import Retriever

/// bootstrap 失败与 install.json 损坏（发版前审查 A1）：未 bootstrap 时排空不递归、不碰磁盘；
/// 读到了但解析不了 = 损坏 → 重建并留痕；读不到（首次解锁前 / 权限）→ 绝不重建，稍后重试沿用原 install_id。
final class BootstrapTests: XCTestCase {
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

    /// install.json 是垃圾字节 / 0 字节 → 原子重建（新 install_id、计数器从 0 起），新会话首行是合成的 rtv.install_reset。
    func testCorruptInstallJsonIsRegeneratedWithTrace() async throws {
        for bytes in [Array("{\"install_id\":\"not-a-uuid\"".utf8), []] {
            let root = makeTempDir()
            let a = Harness(root: root, key: "")
            await a.settle()
            let oldId = try XCTUnwrap(a.client.installId)
            a.client.simulateCrash()
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
            let seg = try String(contentsOfFile: XCTUnwrap(b.client.debugOpenSegmentPath), encoding: .utf8)
            let ls = seg.split(separator: "\n").dropFirst().compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            XCTAssertEqual(ls.count, 1)
            let l = try XCTUnwrap(ls.first)
            XCTAssertEqual(l["tag"] as? String, "rtv.install_reset")
            XCTAssertEqual(l["level"] as? String, "warn")
            XCTAssertEqual(l["msg"] as? String, "install.json unreadable; install_id regenerated")
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
}

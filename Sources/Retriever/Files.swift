import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 文件系统纪律（§3.2 / §3.3）：
/// - 目录与每个新建文件都设 isExcludedFromBackup（某些操作会重置，保存后再设一次）；
/// - iOS 显式设 FileProtectionType.completeUntilFirstUserAuthentication（不依赖宿主的默认保护类）；
/// - 状态文件一律 tmp → fsync → rename；段文件 POSIX open/write，不经任何用户态缓冲。
enum FS {
    static func markFile(_ url: URL) {
        protect(url)
        excludeFromBackup(url)
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }

    /// 建目录（含父目录）并打标。
    @discardableResult
    static func ensureDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return false
        }
        markFile(url)
        return true
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 禁用标记的三态判定（ADR 0024 决定 6）：stat 成功 = 存在；ENOENT = 不存在；其它错误（目录不可读、权限、I/O）= 未知。
    /// 未知一律按禁用处理（fail-closed）。
    enum MarkerState: Sendable { case present, absent, unknown }

    /// 文件大小的三态（「已提交」判定用，ADR 0023）：确实不存在 / 长度 / stat 出错（非 ENOENT）。
    enum SizeState: Equatable { case missing, size(Int64), error }

    static func sizeState(_ url: URL) -> SizeState {
        var st = stat()
        if stat(url.path, &st) == 0 { return .size(Int64(st.st_size)) }
        return errno == ENOENT ? .missing : .error
    }

    static func markerState(_ url: URL) -> MarkerState {
        var st = stat()
        if stat(url.path, &st) == 0 { return .present }
        return errno == ENOENT ? .absent : .unknown
    }

    /// 严格读：区分「文件确已不存在」与「读失败」（ADR 0024 决定 3：读失败 ≠ 没有内容）。读不全（中途出错）也算失败。
    enum ReadResult {
        case ok([UInt8])
        case missing
        case failed
    }

    static func readStrict(_ url: URL) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .missing : .failed }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { return .failed }
        let size = Int(st.st_size)
        var out = [UInt8](repeating: 0, count: size)
        var off = 0
        while off < size {
            let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, size - off) }
            if r > 0 { off += r; continue }
            if r < 0 && errno == EINTR { continue }
            return .failed
        }
        return .ok(out)
    }

    /// 文件上的 flock 是否可得（= 没有活着的持有者）。可得时在持锁状态下调 body（例如删除），随后放锁。
    /// 打不开 → false（不执行 body）。
    @discardableResult
    static func withFreeFileLock(_ url: URL, _ body: () -> Void = {}) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        body()
        flock(fd, LOCK_UN)
        return true
    }

    /// 先改名再删（ADR 0019 决定 9）的第一步（实例的 purge 与 configure 之前的 purge 共用）：把 root 改名为同级的
    /// `<root>.purge-<uuid>`，返回 (改名后的目录, true)；root 本来就不存在返回 (nil, true)；
    /// 改名失败（极少见，如 root 所在目录只读）返回 (nil, false)，调用方退回逐项删除。
    static func moveAside(_ root: URL) -> (moved: URL?, ok: Bool) {
        let dst = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".purge-" + IDs.newV4())
        if rename(root.path, dst.path) == 0 { return (dst, true) }
        return (nil, errno == ENOENT)
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func list(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// 列目录，区分「不是目录（[]）」与「是目录却列不出（nil）」：身份修复要靠后者判断「本次失败、稍后重试」。
    static func listStrict(_ dir: URL) -> [String]? {
        var st = stat()
        if stat(dir.path, &st) != 0 { return errno == ENOENT ? [] : nil }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        return try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    /// 删一个文件；本来就不存在也算成功。
    static func unlinkIfPresent(_ url: URL) -> Bool {
        unlink(url.path) == 0 || errno == ENOENT
    }

    static func read(_ url: URL) -> [UInt8]? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { return nil }
        let size = Int(st.st_size)
        var out = [UInt8](repeating: 0, count: size)
        var off = 0
        while off < size {
            let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, size - off) }
            if r > 0 { off += r; continue }
            if r < 0 && errno == EINTR { continue }
            break
        }
        if off < size { out.removeSubrange(off...) }
        return out
    }

    static func size(_ url: URL) -> Int64? {
        var st = stat()
        if stat(url.path, &st) != 0 { return nil }
        return Int64(st.st_size)
    }

    static func mtimeMs(_ url: URL) -> Int64? {
        var st = stat()
        if stat(url.path, &st) != 0 { return nil }
        return Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
    }

    static func touch(_ url: URL, wallMs: Int64) {
        var times = [timeval(tv_sec: Int(wallMs / 1000), tv_usec: Int32((wallMs % 1000) * 1000)),
                     timeval(tv_sec: Int(wallMs / 1000), tv_usec: Int32((wallMs % 1000) * 1000))]
        _ = utimes(url.path, &times)
    }

    /// write(2) 循环补写；EINTR 重试；失败返回 false。
    @discardableResult
    static func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) -> Bool {
        guard let base = buf.baseAddress else { return true }
        var off = 0
        let n = buf.count
        while off < n {
            let r = write(fd, base + off, n - off)
            if r > 0 { off += r; continue }
            if r < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// 原子写：同目录 tmp（O_CREAT|O_EXCL）→ write → fsync → rename；成功后再打标。
    @discardableResult
    static func writeAtomic(_ url: URL, _ bytes: [UInt8]) -> Bool {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { return false }
        protect(tmp)
        let ok = bytes.withUnsafeBytes { writeAll(fd, $0) } && fsync(fd) == 0
        close(fd)
        if !ok || rename(tmp.path, url.path) != 0 {
            unlink(tmp.path)
            return false
        }
        markFile(url)
        return true
    }

    /// 追加一段字节（一次 write 循环）；文件不存在则创建并打标。
    /// 追加到一半失败：截回追加前的长度（ADR 0019 决定 5），半行不会和下一条粘连、连累下一条被读侧丢掉。
    @discardableResult
    static func append(_ url: URL, _ bytes: [UInt8]) -> Bool {
        let existed = exists(url)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 { return false }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return false
        }
        let ok = bytes.withUnsafeBytes { writeAll(fd, $0) }
        if !ok { _ = ftruncate(fd, st.st_size) }
        close(fd)
        if !existed { markFile(url) }
        return ok
    }

    /// 以 root 目录 fd 做进程间互斥（flock 在目录 fd 上可用）：保护 install.json 计数器与根级共享状态文件的读改写。
    /// 同一进程内不可嵌套（flock 按打开的文件描述冲突）。
    /// 拿不到锁（打不开目录、fd 耗尽、flock 出错）返回 nil、**不执行** body：调用方按本次失败处理、稍后重试
    /// （ADR 0024 决定 3；此前打不开目录时不加锁直接执行，读改写失去互斥）。
    static func withDirLock<T>(_ dir: URL, _ body: () -> T) -> T? {
        if Faults.failsDirLock(dir) { return nil }
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var r: Int32
        repeat { r = flock(fd, LOCK_EX) } while r != 0 && errno == EINTR
        guard r == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// 可用空间（重要用途口径）。
    static func availableBytes(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let c = v?.volumeAvailableCapacityForImportantUsage { return c }
        let v2 = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return v2?.volumeAvailableCapacity.map { Int64($0) }
    }
}

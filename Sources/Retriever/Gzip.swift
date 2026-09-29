import Foundation
import zlib

/// gzip（§3.9）：系统 zlib `deflateInit2` windowBits 31 → 单段标准 gzip、无尾随字节
/// （Compression 框架只产 raw DEFLATE，不用）。解压用于读回出站箱批次（元数据、413 切分、驱逐墓碑）。
enum Gzip {
    static func compress(_ input: [UInt8]) -> [UInt8]? {
        var strm = z_stream()
        let initRC = deflateInit2_(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initRC == Z_OK else { return nil }
        defer { deflateEnd(&strm) }
        let bound = Int(deflateBound(&strm, uLong(input.count))) + 64
        var out = [UInt8](repeating: 0, count: bound)
        var src = input
        let rc: Int32 = src.withUnsafeMutableBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                strm.next_in = inBuf.baseAddress
                strm.avail_in = uInt(inBuf.count)
                strm.next_out = outBuf.baseAddress
                strm.avail_out = uInt(outBuf.count)
                return deflate(&strm, Z_FINISH)
            }
        }
        guard rc == Z_STREAM_END else { return nil }
        out.removeSubrange(Int(strm.total_out)...)
        return out
    }

    /// 严格解压：必须恰好一个 gzip 成员、正常结束、无尾随字节；解压后超过 limit 视为失败。
    static func decompress(_ input: [UInt8], limit: Int = 64 * 1024 * 1024) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        var strm = z_stream()
        guard inflateInit2_(&strm, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&strm) }
        var src = input
        var out = [UInt8]()
        out.reserveCapacity(min(input.count * 6, limit))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var finished = false
        let ok: Bool = src.withUnsafeMutableBufferPointer { inBuf in
            strm.next_in = inBuf.baseAddress
            strm.avail_in = uInt(inBuf.count)
            while true {
                let (rc, produced): (Int32, Int) = chunk.withUnsafeMutableBufferPointer { cBuf in
                    strm.next_out = cBuf.baseAddress
                    strm.avail_out = uInt(cBuf.count)
                    let rc = inflate(&strm, Z_NO_FLUSH)
                    return (rc, cBuf.count - Int(strm.avail_out))
                }
                if produced > 0 {
                    out.append(contentsOf: chunk[0..<produced])
                    if out.count > limit { return false }
                }
                if rc == Z_STREAM_END { finished = true; return strm.avail_in == 0 }
                if rc != Z_OK { return false }
                if produced == 0 && strm.avail_in == 0 { return false }
            }
        }
        return (ok && finished) ? out : nil
    }
}

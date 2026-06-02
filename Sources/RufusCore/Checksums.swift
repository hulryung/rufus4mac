import Foundation
import CryptoKit

public struct ChecksumResult: Sendable, Equatable {
    public let md5: String
    public let sha1: String
    public let sha256: String
}

/// Computes MD5, SHA-1, and SHA-256 of an image in a single pass (lowercase hex).
public enum Checksums {
    public static func compute(of source: ImageSource,
                               chunkSize: Int = Sector.chunkSize,
                               isCancelled: () -> Bool,
                               progress: (WriteProgress) -> Void) throws -> ChecksumResult {
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        let total = source.size
        var done: UInt64 = 0
        while true {
            if isCancelled() { throw WriteError.cancelled }
            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            done += UInt64(chunk.count)
            progress(WriteProgress(bytesWritten: done, totalBytes: total))
        }
        func hex(_ bytes: some Sequence<UInt8>) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        return ChecksumResult(md5: hex(md5.finalize()), sha1: hex(sha1.finalize()),
                              sha256: hex(sha256.finalize()))
    }
}

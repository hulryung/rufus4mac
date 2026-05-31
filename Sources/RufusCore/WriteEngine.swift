import Foundation
import CryptoKit

/// Streams an image to a block destination in sector-aligned chunks,
/// padding the final partial sector with zeros (required by raw devices),
/// reporting progress, and honoring cancellation.
public final class WriteEngine: Sendable {
    private let chunkSize: Int
    private let sectorSize: Int

    public init(chunkSize: Int = Sector.chunkSize, sectorSize: Int = Sector.size) {
        precondition(chunkSize % sectorSize == 0, "chunkSize must be a multiple of sectorSize")
        self.chunkSize = chunkSize
        self.sectorSize = sectorSize
    }

    /// Write the entire `source` to `writer`.
    /// - `isCancelled`: polled between chunks; if true, throws `.cancelled`.
    /// - `progress`: called after each flush with cumulative bytes written
    ///   (counted against the *image* size, not the padded size).
    ///
    /// The caller owns `source` and must `close()` it; this method never closes it.
    /// `writer.finish()` is called only on successful completion — a thrown error
    /// or cancellation intentionally leaves the device un-finalized.
    public func write(
        source: ImageSource,
        to writer: BlockWriter,
        isCancelled: () -> Bool,
        progress: (WriteProgress) -> Void
    ) throws {
        let total = source.size
        var imageBytesWritten: UInt64 = 0
        // Bytes read but not yet written. Holds a sub-sector remainder between
        // iterations (transiently larger while a freshly read chunk is appended).
        var buffer = Data()

        while true {
            if isCancelled() { throw WriteError.cancelled }

            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Flush every complete sector; keep a sub-sector remainder buffered.
            // This guarantees every intermediate write is sector-aligned even when
            // `source.read` returns a partial (non-aligned) chunk mid-stream.
            let alignedCount = (buffer.count / sectorSize) * sectorSize
            if alignedCount > 0 {
                try writer.write(Data(buffer.prefix(alignedCount)))
                buffer.removeFirst(alignedCount)
                imageBytesWritten += UInt64(alignedCount)
                progress(WriteProgress(bytesWritten: imageBytesWritten, totalBytes: total))
            }
        }

        // Final sub-sector remainder (the only place padding is allowed).
        if !buffer.isEmpty {
            try writer.write(padToSector(buffer))
            imageBytesWritten += UInt64(buffer.count)
            progress(WriteProgress(bytesWritten: imageBytesWritten, totalBytes: total))
        }

        try writer.finish()
    }

    /// Pad `data` up to the next sector boundary with zeros. No-op if aligned.
    private func padToSector(_ data: Data) -> Data {
        let target = Sector.roundUp(data.count)
        guard target != data.count else { return data }
        var out = data
        out.append(Data(count: target - data.count))
        return out
    }

    /// Read back exactly `imageSize` bytes from `reader`, hash them (SHA-256),
    /// and compare against `expectedHash`. Throws `.verificationMismatch` on mismatch.
    public func verify(
        reader: BlockReader,
        imageSize: UInt64,
        expectedHash: Data,
        isCancelled: () -> Bool,
        progress: (WriteProgress) -> Void
    ) throws {
        var hasher = SHA256()
        var remaining = imageSize

        while remaining > 0 {
            if isCancelled() { throw WriteError.cancelled }
            // Raw devices require sector-aligned reads. Round the final read up to a
            // whole sector, then trim the result back to the image boundary below.
            let want = remaining >= UInt64(chunkSize) ? chunkSize : Sector.roundUp(Int(remaining))
            let chunk = try reader.read(maxLength: want)
            if chunk.isEmpty { break }
            let useful = chunk.prefix(Int(min(UInt64(chunk.count), remaining)))
            hasher.update(data: useful)
            remaining -= UInt64(useful.count)
            progress(WriteProgress(bytesWritten: imageSize - remaining, totalBytes: imageSize))
        }

        if Data(hasher.finalize()) != expectedHash { throw WriteError.verificationMismatch }
    }

    /// SHA-256 of an entire ImageSource. Assumes `source` is positioned at offset 0; callers should pass a freshly opened instance.
    public static func sha256(of source: ImageSource, chunkSize: Int = Sector.chunkSize) throws -> Data {
        var hasher = SHA256()
        while true {
            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

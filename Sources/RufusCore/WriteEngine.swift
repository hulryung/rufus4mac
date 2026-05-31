import Foundation

/// Streams an image to a block destination in sector-aligned chunks,
/// padding the final partial sector with zeros (required by raw devices),
/// reporting progress, and honoring cancellation.
public final class WriteEngine {
    private let chunkSize: Int
    private let sectorSize: Int

    public init(chunkSize: Int = Sector.chunkSize, sectorSize: Int = Sector.size) {
        precondition(chunkSize % sectorSize == 0, "chunkSize must be a multiple of sectorSize")
        self.chunkSize = chunkSize
        self.sectorSize = sectorSize
    }

    /// Write the entire `source` to `writer`.
    /// - `isCancelled`: polled between chunks; if true, throws `.cancelled`.
    /// - `progress`: called after each chunk with cumulative bytes written
    ///   (counted against the *image* size, not the padded size).
    public func write(
        source: ImageSource,
        to writer: BlockWriter,
        isCancelled: () -> Bool,
        progress: (WriteProgress) -> Void
    ) throws {
        let total = source.size
        var imageBytesWritten: UInt64 = 0

        while true {
            if isCancelled() { throw WriteError.cancelled }

            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }

            let padded = padToSector(chunk)
            try writer.write(padded)

            imageBytesWritten += UInt64(chunk.count)
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
}

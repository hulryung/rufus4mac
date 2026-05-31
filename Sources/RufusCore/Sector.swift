import Foundation

/// Sector-size constants and alignment helpers for raw device writes.
/// Raw devices (`/dev/rdiskN`) require writes in whole-sector multiples.
public enum Sector {
    /// Logical sector size in bytes. 512 is the universal lowest common denominator.
    public static let size = 512

    /// Streaming chunk size: 4 MiB, a multiple of `size`.
    public static let chunkSize = 4 * 1024 * 1024

    /// Round `bytes` up to the next whole-sector boundary.
    public static func roundUp(_ bytes: Int) -> Int {
        let r = bytes % size
        return r == 0 ? bytes : bytes + (size - r)
    }
}

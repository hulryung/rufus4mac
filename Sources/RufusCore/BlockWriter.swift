import Foundation

/// A destination that accepts sequential writes of (caller-aligned) buffers.
public protocol BlockWriter: AnyObject {
    /// Write the entire buffer. Throws `WriteError.shortWrite` on a partial write.
    func write(_ data: Data) throws
    /// Flush and release the underlying resource.
    func finish() throws
}

/// A `BlockWriter` backed by a regular file (used in unit tests and for
/// developing the streaming logic without a device).
public final class FileBlockWriter: BlockWriter {
    private let handle: FileHandle

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    public func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}

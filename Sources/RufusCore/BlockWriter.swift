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

/// A `BlockWriter` backed by a POSIX file descriptor opened on a device
/// (`/dev/rdiskN`). Writes must be sector-aligned by the caller (WriteEngine).
public final class DeviceBlockWriter: BlockWriter {
    private let fd: Int32

    /// Open the device for writing. `O_SYNC` ensures data hits the medium.
    public init(devicePath: String) throws {
        let fd = open(devicePath, O_WRONLY | O_SYNC)
        guard fd >= 0 else { throw WriteError.deviceOpenFailed(errno: errno) }
        self.fd = fd
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while written < data.count {
                let n = Foundation.write(fd, base + written, data.count - written)
                if n < 0 { throw WriteError.writeFailed(errno: errno) }
                if n == 0 { throw WriteError.shortWrite(expected: data.count, actual: written) }
                written += n
            }
        }
    }

    public func finish() throws {
        fsync(fd)
        close(fd)
    }
}

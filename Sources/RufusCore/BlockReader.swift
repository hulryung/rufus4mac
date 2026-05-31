import Foundation

/// A readable block source (used for read-back verification).
public protocol BlockReader: AnyObject {
    /// Read up to `maxLength` bytes from the current position.
    /// Returns an empty `Data` at end of stream.
    func read(maxLength: Int) throws -> Data
    /// Flush and release the underlying resource.
    func close()
}

/// Single-task ownership; not safe for concurrent use.
public final class DeviceBlockReader: BlockReader, @unchecked Sendable {
    private let fd: Int32
    private var closed = false

    public init(devicePath: String) throws {
        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else { throw WriteError.deviceOpenFailed(errno: errno) }
        self.fd = fd
    }

    public func read(maxLength: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = buf.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, maxLength) }
        if n < 0 { throw WriteError.readFailed(errno: errno) }
        return Data(buf.prefix(n))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        Foundation.close(fd)
    }

    deinit { if !closed { Foundation.close(fd) } }
}

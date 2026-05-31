import Foundation

/// A readable block source (used for read-back verification).
public protocol BlockReader: AnyObject {
    func read(maxLength: Int) throws -> Data
    func close()
}

public final class DeviceBlockReader: BlockReader {
    private let fd: Int32

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

    public func close() { Foundation.close(fd) }
}

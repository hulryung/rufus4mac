/// Snapshot of write progress, suitable to send over XPC.
public struct WriteProgress: Sendable, Codable, Equatable {
    public let bytesWritten: UInt64
    public let totalBytes: UInt64

    public init(bytesWritten: UInt64, totalBytes: UInt64) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        min(1, totalBytes == 0 ? 0 : Double(bytesWritten) / Double(totalBytes))
    }
}

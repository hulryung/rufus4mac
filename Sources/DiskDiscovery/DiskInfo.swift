import Foundation

/// Identifying information for a candidate target disk.
public struct DiskInfo: Identifiable, Hashable, Sendable {
    public let bsdName: String          // e.g. "disk4"
    public let model: String            // e.g. "SanDisk Ultra"
    public let sizeBytes: UInt64
    public let isRemovable: Bool

    public var id: String { bsdName }
    public var devicePath: String { "/dev/\(bsdName)" }
    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    public init(bsdName: String, model: String, sizeBytes: UInt64, isRemovable: Bool) {
        self.bsdName = bsdName
        self.model = model
        self.sizeBytes = sizeBytes
        self.isRemovable = isRemovable
    }

    public var displaySize: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .decimal
        fmt.allowedUnits = [.useGB, .useMB]
        return fmt.string(fromByteCount: Int64(sizeBytes))
    }
}

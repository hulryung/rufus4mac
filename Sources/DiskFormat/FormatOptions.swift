import Foundation

/// User-chosen formatting parameters for a quick `diskutil` format.
public struct FormatOptions: Sendable, Equatable {
    public enum PartitionScheme: String, Sendable, CaseIterable {
        case mbr = "MBR"
        case gpt = "GPT"
    }
    public enum FileSystem: String, Sendable, CaseIterable {
        case exfat = "exFAT"
        case fat32 = "FAT32"
        /// `diskutil` personality name.
        public var personality: String { self == .exfat ? "ExFAT" : "MS-DOS FAT32" }
        /// Max volume-label length the filesystem allows.
        public var maxLabel: Int { self == .exfat ? 15 : 11 }
    }

    public var scheme: PartitionScheme
    public var fileSystem: FileSystem
    public var label: String

    public init(scheme: PartitionScheme, fileSystem: FileSystem, label: String) {
        self.scheme = scheme
        self.fileSystem = fileSystem
        self.label = label
    }

    /// Uppercased, `A–Z0–9`-only, length-capped label; falls back to `RUFUS4MAC` when empty.
    public var normalizedLabel: String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var s = String(label.uppercased().filter { allowed.contains($0) })
        if s.isEmpty { s = "RUFUS4MAC" }
        return String(s.prefix(fileSystem.maxLabel))
    }
}

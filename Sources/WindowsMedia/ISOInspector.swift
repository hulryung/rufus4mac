import Foundation

public struct ISOInfo: Sendable {
    public let isWindows: Bool
    public let installImageRelPath: String?   // e.g. "sources/install.wim"
    public let installImageSizeBytes: UInt64
    public let mountPoint: String
}

public enum ISOInspectorError: Error, CustomStringConvertible {
    case mountFailed(String)
    public var description: String {
        switch self { case .mountFailed(let s): return "Failed to mount ISO: \(s)" }
    }
}

public struct ISOInspector {
    let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public struct Detection: Sendable {
        public let isWindows: Bool
        public let installImageRelPath: String?
        public let installImageSizeBytes: UInt64
    }

    /// Pure detection over a mounted root. Windows = an install image under sources/ AND a
    /// UEFI boot file present.
    public static func detectWindows(atMountedRoot root: String) -> Detection {
        let fm = FileManager.default
        func size(_ rel: String) -> UInt64? {
            let p = (root as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: p) else { return nil }
            return ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value
        }
        let hasEfiBoot = fm.fileExists(atPath: (root as NSString).appendingPathComponent("efi/boot/bootx64.efi"))
            || fm.fileExists(atPath: (root as NSString).appendingPathComponent("efi/microsoft/boot/bootmgfw.efi"))
            || fm.fileExists(atPath: (root as NSString).appendingPathComponent("bootmgr.efi"))
        for rel in ["sources/install.wim", "sources/install.esd"] {
            if let s = size(rel), hasEfiBoot {
                return Detection(isWindows: true, installImageRelPath: rel, installImageSizeBytes: s)
            }
        }
        return Detection(isWindows: false, installImageRelPath: nil, installImageSizeBytes: 0)
    }
}

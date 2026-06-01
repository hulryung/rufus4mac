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

extension ISOInspector {
    /// Attach the ISO read-only and run detection at its mount point.
    public func mountAndInspect(isoPath: String) throws -> ISOInfo {
        let r = try runner.run("/usr/bin/hdiutil",
                               ["attach", "-nobrowse", "-readonly", "-plist", isoPath])
        guard r.status == 0 else { throw ISOInspectorError.mountFailed(r.stderr) }
        guard let mp = Self.firstMountPoint(fromPlist: r.stdout) else {
            // Attach succeeded but produced no mount-point (unknown/corrupt FS):
            // detach the attached device so we don't leak it, then fail.
            if let dev = Self.firstDevEntry(fromPlist: r.stdout) {
                _ = try? runner.run("/usr/bin/hdiutil", ["detach", dev, "-force"])
            }
            throw ISOInspectorError.mountFailed("no mount-point in hdiutil output")
        }
        let d = Self.detectWindows(atMountedRoot: mp)
        return ISOInfo(isWindows: d.isWindows, installImageRelPath: d.installImageRelPath,
                       installImageSizeBytes: d.installImageSizeBytes, mountPoint: mp)
    }

    public func detach(mountPoint: String) {
        _ = try? runner.run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
    }

    private static func systemEntities(fromPlist plist: String) -> [[String: Any]] {
        guard let data = plist.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let raw = dict["system-entities"] as? [Any] else { return [] }
        return raw.compactMap { $0 as? [String: Any] }
    }

    /// First non-empty `mount-point` in the hdiutil attach plist.
    static func firstMountPoint(fromPlist plist: String) -> String? {
        for e in systemEntities(fromPlist: plist) {
            if let mp = e["mount-point"] as? String, !mp.isEmpty { return mp }
        }
        return nil
    }

    /// First non-empty `dev-entry` (e.g. /dev/disk9) in the hdiutil attach plist.
    static func firstDevEntry(fromPlist plist: String) -> String? {
        for e in systemEntities(fromPlist: plist) {
            if let d = e["dev-entry"] as? String, !d.isEmpty { return d }
        }
        return nil
    }
}

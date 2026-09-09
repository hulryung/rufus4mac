import Foundation

/// A named set of driver files to carry on the USB — usually one laptop model, e.g. "NT950XEV".
///
/// A profile is just a directory, so the store is inspectable and editable in Finder without the
/// app: drop an installer into a folder and it is part of that model. Nothing parses the files,
/// because they are not injected into Windows Setup — they ride along so that a machine with no
/// working Wi-Fi driver has the installer at hand right after Windows comes up, which is exactly
/// the case Samsung's own support pages tell you to solve with a USB stick.
public struct DriverProfile: Sendable, Equatable, Identifiable, Comparable {
    public var name: String
    public var files: [String]          // file names, relative to the profile directory
    public var totalSize: UInt64

    public var id: String { name }
    public init(name: String, files: [String], totalSize: UInt64) {
        self.name = name; self.files = files; self.totalSize = totalSize
    }
    public static func < (a: DriverProfile, b: DriverProfile) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

public enum DriverStore {
    /// Folder created on the USB. Deliberately *not* `$WinPEDriver$`: that name makes Windows Setup
    /// load the drivers during installation, and these are meant to be run by hand afterwards.
    public static let usbFolderName = "Drivers"

    /// FAT32 cannot hold a file of 4 GiB or more. Driver installers are far smaller, but a stray
    /// file in the store would otherwise fail mid-copy with nothing explaining why.
    static let maxFileSize: UInt64 = 4 * 1024 * 1024 * 1024 - 1

    /// Every profile directory under `root`, sorted by name. Missing root means no profiles yet.
    public static func profiles(in root: String) -> [DriverProfile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries.compactMap { name -> DriverProfile? in
            var isDir: ObjCBool = false
            let dir = (root as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  !name.hasPrefix(".") else { return nil }
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let size = files.reduce(UInt64(0)) { sum, f in
                let p = (dir as NSString).appendingPathComponent(f)
                return sum + (((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value ?? 0)
            }
            return DriverProfile(name: name, files: files, totalSize: size)
        }.sorted()
    }

    /// Copy the named profiles onto the USB as `Drivers/<name>/…`, reporting bytes as they move.
    /// Profiles that no longer exist, or hold no files, are skipped rather than failing the write —
    /// a stale selection must not cost the user a finished USB.
    @discardableResult
    public static func copy(profileNames: [String], from root: String, to usbRoot: String,
                            progress: (Double) -> Void = { _ in }) throws -> [DriverProfile] {
        let all = profiles(in: root)
        let wanted = all.filter { profileNames.contains($0.name) && !$0.files.isEmpty }
        guard !wanted.isEmpty else { return [] }

        for p in wanted {
            for f in p.files {
                let path = (((root as NSString).appendingPathComponent(p.name)) as NSString)
                    .appendingPathComponent(f)
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?
                    .uint64Value ?? 0
                if size > maxFileSize {
                    throw WimToolError(message: "\(p.name)/\(f) is \(size) bytes, over FAT32's 4 GB file limit.")
                }
            }
        }

        let fm = FileManager.default
        let total = wanted.reduce(UInt64(0)) { $0 + $1.totalSize }
        var done: UInt64 = 0
        progress(0)
        let dest = (usbRoot as NSString).appendingPathComponent(usbFolderName)
        for p in wanted {
            let srcDir = (root as NSString).appendingPathComponent(p.name)
            let dstDir = (dest as NSString).appendingPathComponent(p.name)
            try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
            for f in p.files {
                let src = (srcDir as NSString).appendingPathComponent(f)
                let dst = (dstDir as NSString).appendingPathComponent(f)
                let size = ((try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber)?.uint64Value ?? 0
                do {
                    try WindowsUSBWriter.copyFile(from: src, to: dst, size: size) { moved in
                        done += moved
                        progress(total == 0 ? 1 : Double(done) / Double(total))
                    }
                } catch {
                    throw WimToolError(message: "Could not copy driver \(p.name)/\(f): \(error.localizedDescription)")
                }
            }
        }
        progress(1)
        return wanted
    }

    /// Check what landed, the same way the image copy is checked: a USB that stops accepting writes
    /// reports success just as readily for a 40 MB installer as for a 4 GB image.
    public static func verify(profiles copied: [DriverProfile], root: String, usbRoot: String) throws {
        let fm = FileManager.default
        let dest = (usbRoot as NSString).appendingPathComponent(usbFolderName)
        for p in copied {
            for f in p.files {
                let src = (((root as NSString).appendingPathComponent(p.name)) as NSString)
                    .appendingPathComponent(f)
                let dst = (((dest as NSString).appendingPathComponent(p.name)) as NSString)
                    .appendingPathComponent(f)
                let want = ((try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber)?.uint64Value
                let got = ((try? fm.attributesOfItem(atPath: dst))?[.size] as? NSNumber)?.uint64Value
                guard let got else {
                    throw WimToolError(message: "Driver \(p.name)/\(f) is missing from the USB after copying.")
                }
                if got != want {
                    throw WimToolError(message: """
                        Driver \(p.name)/\(f) copied incompletely (\(got) of \(want ?? 0) bytes). \
                        The USB may have disconnected during the write.
                        """)
                }
            }
        }
    }
}

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
    /// Paths relative to the profile directory, so an extracted driver folder keeps its shape.
    public var files: [String]
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
            let files = filesUnder(dir)
            let size = files.reduce(UInt64(0)) { sum, f in
                let p = (dir as NSString).appendingPathComponent(f)
                return sum + (((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value ?? 0)
            }
            return DriverProfile(name: name, files: files, totalSize: size)
        }.sorted()
    }

    /// Every file under `dir`, recursively, as paths relative to it.
    ///
    /// The store is meant to be edited in Finder, so a profile may well hold a whole extracted
    /// driver folder rather than a flat set of installers. Listing only the top level would report
    /// such a folder as a zero-byte "file" and then fail to copy it.
    static func filesUnder(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        for case let rel as String in en {
            if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let full = (dir as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            out.append(rel)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copy the named profiles onto the USB as `Drivers/<name>/…`, reporting bytes as they move.
    /// Profiles that no longer exist, or hold no files, are skipped rather than failing the write —
    /// a stale selection must not cost the user a finished USB.
    @discardableResult
    public static func copy(profileNames: [String], from root: String, to usbRoot: String,
                            maximumFileSize: UInt64? = 4 * 1024 * 1024 * 1024 - 1,
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
                if let maximumFileSize, size > maximumFileSize {
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
                try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
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

extension DriverStore {
    /// Add drivers to an existing volume without overwriting its files. Build and verify a
    /// staging copy on that volume first, then publish whole model folders with no replacement.
    @discardableResult
    public static func addToExistingVolume(profileNames: [String], from root: String, to usbRoot: String,
                                            maximumFileSize: UInt64? = 4 * 1024 * 1024 * 1024 - 1,
                                            progress: (Double) -> Void = { _ in }) throws -> [DriverProfile] {
        let fm = FileManager.default
        let wanted = profiles(in: root).filter { profileNames.contains($0.name) && !$0.files.isEmpty }
        guard !wanted.isEmpty, Set(wanted.map(\.name)) == Set(profileNames) else {
            throw WimToolError(message: "Some selected drivers are missing or empty. Refresh the library and select them again.")
        }
        let volume = URL(fileURLWithPath: usbRoot, isDirectory: true)
        let destination = volume.appendingPathComponent(usbFolderName, isDirectory: true)
        // An existing Drivers symlink must never redirect a USB operation elsewhere.
        if let attrs = try? fm.attributesOfItem(atPath: destination.path),
           attrs[.type] as? FileAttributeType != .typeDirectory {
            throw WimToolError(message: "Drivers on the USB is not a regular folder. Rename it in Finder and try again.")
        }
        for profile in wanted {
            let target = destination.appendingPathComponent(profile.name)
            if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                throw WimToolError(message: "Drivers/\(profile.name) already exists on this USB. Rename or move that folder in Finder before adding this model again. Existing files were kept.")
            }
        }
        let available = try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        let required = wanted.reduce(UInt64(0)) { $0 + $1.totalSize }
        guard let available, UInt64(max(0, available)) >= required else {
            throw WimToolError(message: "The USB does not have enough free space for the selected drivers.")
        }
        let stage = volume.appendingPathComponent(".rufus-drivers-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let copied = try copy(profileNames: profileNames, from: root, to: stage.path, maximumFileSize: maximumFileSize, progress: progress)
        guard Set(copied.map(\.name)) == Set(wanted.map(\.name)) else {
            throw WimToolError(message: "The driver library changed during copying. Refresh it and try again.")
        }
        try verify(profiles: copied, root: root, usbRoot: stage.path)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for profile in copied {
            let staged = stage.appendingPathComponent(usbFolderName).appendingPathComponent(profile.name)
            let target = destination.appendingPathComponent(profile.name)
            // moveItem fails if a destination appeared since preflight; it never replaces it.
            try fm.moveItem(at: staged, to: target)
        }
        try verify(profiles: copied, root: root, usbRoot: usbRoot)
        return copied
    }
}

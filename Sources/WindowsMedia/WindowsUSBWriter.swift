import Foundation

public final class WindowsUSBWriter {
    public enum Phase: String { case formatting, copying, splitting, bypassing }
    let runner: ProcessRunner
    let wim: WimTool
    /// install.wim larger than this (bytes) is split for FAT32. 4000 MB.
    let splitThreshold: UInt64 = 4000 * 1024 * 1024

    public init(runner: ProcessRunner, wim: WimTool) { self.runner = runner; self.wim = wim }

    /// Format the whole disk as GPT + a single FAT32 volume named `volumeName`.
    public func format(bsdName: String, volumeName: String) throws {
        let r = try runner.run("/usr/sbin/diskutil",
                               ["eraseDisk", "MS-DOS", volumeName, "GPT", "/dev/\(bsdName)"])
        if r.status != 0 {
            throw WimToolError(message: "diskutil eraseDisk failed (\(r.status)): \(r.stderr)")
        }
    }

    /// Copy ISO contents to the mounted USB, splitting install.wim when oversized.
    /// `progress(phase, fraction)`; phases: "copying" then (if split) "splitting".
    public func copyAndSplit(mountedISORoot: String, usbMountPoint: String,
                             installImageRelPath: String, installImageSizeBytes: UInt64,
                             progress: (String, Double) -> Void) throws {
        let fm = FileManager.default
        let willSplit = installImageSizeBytes > splitThreshold
            && installImageRelPath.hasSuffix("install.wim")

        let entries = try Self.fileList(root: mountedISORoot)
        var total: UInt64 = 0
        for e in entries where !(willSplit && e.rel == installImageRelPath) { total += e.size }
        var done: UInt64 = 0

        progress("copying", 0)
        for e in entries {
            if willSplit && e.rel == installImageRelPath { continue }
            let dst = (usbMountPoint as NSString).appendingPathComponent(e.rel)
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: (mountedISORoot as NSString).appendingPathComponent(e.rel), toPath: dst)
            done += e.size
            progress("copying", total == 0 ? 1 : Double(done) / Double(total))
        }

        if willSplit {
            progress("splitting", 0)
            let srcWim = (mountedISORoot as NSString).appendingPathComponent(installImageRelPath)
            let outDir = (usbMountPoint as NSString).appendingPathComponent("sources")
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let outSWM = (outDir as NSString).appendingPathComponent("install.swm")
            try wim.split(wim: srcWim, outFirstSWM: outSWM, chunkMB: 4000)
            progress("splitting", 1)
        }
    }

    struct Entry { let rel: String; let size: UInt64 }
    /// Recursively list files (relative paths) and sizes under `root`.
    static func fileList(root: String) throws -> [Entry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [Entry] = []
        for case let rel as String in en {
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.uint64Value ?? 0
            out.append(Entry(rel: rel, size: size))
        }
        return out
    }
}

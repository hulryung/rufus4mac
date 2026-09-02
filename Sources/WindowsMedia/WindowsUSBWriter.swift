import Foundation
import SystemTools

public final class WindowsUSBWriter {
    let runner: ProcessRunner
    let wim: WimTool
    /// install.wim larger than this (bytes) is split for FAT32. 4000 MB.
    let splitThreshold: UInt64 = 4000 * 1024 * 1024

    public init(runner: ProcessRunner, wim: WimTool) { self.runner = runner; self.wim = wim }

    /// Format the whole disk as MBR + a single FAT32 volume named `volumeName`.
    ///
    /// MBR, not GPT: on a disk of real USB size `diskutil eraseDisk ... GPT` prepends a 200 MB
    /// EFI System Partition, and Windows Setup can adopt *that* ESP — the one on the USB — as the
    /// boot volume instead of creating one on the target disk. Setup then finishes without error,
    /// but the installed machine boots only while the USB is attached and its internal disk never
    /// gets an ESP. UEFI firmware boots `\EFI\BOOT\BOOTX64.EFI` from an MBR FAT32 volume just as
    /// well, so nothing is lost by avoiding GPT here.
    ///
    /// The ESP is size-dependent — a GPT format of a small disk image produces none — so the
    /// hdiutil-backed integration tests cannot catch a regression here. `WindowsUSBWriterTests`
    /// asserts the argv instead.
    public func format(bsdName: String, volumeName: String) throws {
        let r = try runner.run("/usr/sbin/diskutil",
                               ["eraseDisk", "MS-DOS", volumeName, "MBR", "/dev/\(bsdName)"])
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
        // Only .wim can be split for FAT32. A >4GB non-.wim install image (e.g. a large
        // install.esd) cannot fit and is not supported — fail clearly rather than letting
        // the copy fail cryptically on the FAT32 4GB limit.
        if installImageSizeBytes > splitThreshold && !willSplit {
            throw WimToolError(message: "Install image \(installImageRelPath) exceeds FAT32's 4 GB limit and only install.wim can be split; this image is not supported.")
        }

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

        try verifyCopy(entries: entries, usbMountPoint: usbMountPoint, skipping: willSplit ? installImageRelPath : nil)

        if willSplit {
            progress("splitting", 0)
            let srcWim = (mountedISORoot as NSString).appendingPathComponent(installImageRelPath)
            let outDir = (usbMountPoint as NSString).appendingPathComponent("sources")
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let outSWM = (outDir as NSString).appendingPathComponent("install.swm")
            try wim.split(wim: srcWim, outFirstSWM: outSWM, chunkMB: 4000,
                          progress: { progress("splitting", $0) })
            try verifySplit(outDir: outDir, sourceSizeBytes: installImageSizeBytes)
            progress("splitting", 1)
        }
    }

    /// Check every copied file arrived at its full size. Same reasoning as `verifySplit`: a USB
    /// that stops accepting writes doesn't necessarily surface an error to `copyItem`.
    func verifyCopy(entries: [Entry], usbMountPoint: String, skipping: String?) throws {
        let fm = FileManager.default
        for e in entries where e.rel != skipping {
            let dst = (usbMountPoint as NSString).appendingPathComponent(e.rel)
            let size = ((try? fm.attributesOfItem(atPath: dst))?[.size] as? NSNumber)?.uint64Value
            guard let size else {
                throw WimToolError(message: "\(e.rel) is missing from the USB after copying.")
            }
            if size != e.size {
                throw WimToolError(message: """
                    \(e.rel) copied incompletely (\(size) of \(e.size) bytes). The USB may have \
                    disconnected during the write — try a port on the Mac itself rather than a hub \
                    or dock, then write again.
                    """)
            }
        }
    }

    /// FAT32's maximum file size, 4 GiB - 1.
    static let fat32MaxFileSize: UInt64 = 4 * 1024 * 1024 * 1024 - 1

    /// Check the split actually landed on the USB.
    ///
    /// `wimlib-imagex split` exits 0 even when the volume stopped accepting writes part-way: a USB
    /// that drops off the bus mid-split leaves a truncated `install.swm`, a "successful" write, and
    /// a stick that only fails hours later inside Windows Setup with 0x8007000D. Splitting rewrites
    /// each part's header and XML so the parts total slightly *under* the source (~0.5%); anything
    /// far below that means the write was cut short.
    func verifySplit(outDir: String, sourceSizeBytes: UInt64) throws {
        let fm = FileManager.default
        let parts = ((try? fm.contentsOfDirectory(atPath: outDir)) ?? [])
            .filter { $0.hasPrefix("install") && $0.hasSuffix(".swm") }
            .sorted()
        guard !parts.isEmpty else {
            throw WimToolError(message: "Splitting install.wim produced no .swm parts on the USB.")
        }
        var total: UInt64 = 0
        for name in parts {
            let full = (outDir as NSString).appendingPathComponent(name)
            let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.uint64Value ?? 0
            if size > Self.fat32MaxFileSize {
                throw WimToolError(message: "\(name) is \(size) bytes, over FAT32's 4 GB file limit.")
            }
            total += size
            try wim.info(wim: full)   // catches a part whose tail never made it to the device
        }
        let minimum = sourceSizeBytes / 100 * 97
        if total < minimum {
            throw WimToolError(message: """
                The Windows image was not fully written: \(parts.count) part(s) totalling \(total) \
                bytes, expected at least \(minimum). The USB may have disconnected during the write \
                — try a port on the Mac itself rather than a hub or dock, then write again.
                """)
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

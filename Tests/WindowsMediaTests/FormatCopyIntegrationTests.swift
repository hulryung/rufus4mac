import XCTest
import SystemTools
@testable import WindowsMedia

final class FormatCopyIntegrationTests: XCTestCase {
    func testFormatThenCopySmallTreeToMountedVolume() throws {
        let fm = FileManager.default
        // Fake "ISO" source tree (small install.wim → no split).
        let iso = fm.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: iso.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: iso.appendingPathComponent("sources/install.wim"))
        try Data(count: 64).write(to: iso.appendingPathComponent("efi/boot/bootx64.efi"))
        defer { try? fm.removeItem(at: iso) }

        // Attach a 256MB image as the "USB".
        let img = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString).img")
        fm.createFile(atPath: img.path, contents: nil)
        let fh = try FileHandle(forWritingTo: img)
        try fh.truncate(atOffset: 256 * 1024 * 1024)
        try fh.close()
        defer { try? fm.removeItem(at: img) }

        let runner = SystemProcessRunner()
        let att = try runner.run("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        guard let dev = att.stdout.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
        else { throw XCTSkip("attach failed") }
        let bsd = String(dev.dropFirst("/dev/".count))
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "/dev/\(bsd)", "-force"]) }

        let writer = WindowsUSBWriter(runner: runner, wim: WimTool(runner: runner, imagexPath: "/x"))
        try writer.format(bsdName: bsd, volumeName: "WIN")

        // diskutil info -plist outputs a flat dict with a top-level "MountPoint" key.
        // firstMountPoint(fromPlist:) parses the hdiutil attach "system-entities" shape and
        // returns nil here; read MountPoint directly instead.
        let info = try runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsd)s1"])
        guard let plistData = info.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = plist as? [String: Any],
              let mp = dict["MountPoint"] as? String, !mp.isEmpty
        else { throw XCTSkip("could not determine mount point from diskutil info -plist") }

        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: mp,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 4096, progress: { _, _ in })
        XCTAssertTrue(fm.fileExists(atPath: (mp as NSString).appendingPathComponent("sources/install.wim")))
        XCTAssertTrue(fm.fileExists(atPath: (mp as NSString).appendingPathComponent("efi/boot/bootx64.efi")))
    }
}

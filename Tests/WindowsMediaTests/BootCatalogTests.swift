import XCTest
import SystemTools
@testable import WindowsMedia

/// Regression for NSCocoaErrorDomain 513 on ISOs that list an El Torito boot catalog: macOS exposes
/// it mode 000, so copying every file in the tree failed on it. UUP-generated Windows ISOs list one;
/// Microsoft's retail ISOs generally do not, which is why this only showed up on some images.
final class BootCatalogTests: XCTestCase {
    func testRecognizesBootCatalogNamesCaseInsensitively() {
        XCTAssertTrue(WindowsUSBWriter.isBootCatalog("boot.catalog"))
        XCTAssertTrue(WindowsUSBWriter.isBootCatalog("BOOT.CATALOG"))
        XCTAssertTrue(WindowsUSBWriter.isBootCatalog("Boot.Cat"))
        XCTAssertTrue(WindowsUSBWriter.isBootCatalog("boot/boot.catalog"))
        XCTAssertFalse(WindowsUSBWriter.isBootCatalog("bootmgr"))
        XCTAssertFalse(WindowsUSBWriter.isBootCatalog("boot.wim"))
        XCTAssertFalse(WindowsUSBWriter.isBootCatalog("sources/boot.catalog.bak"))
    }

    func testFileListSkipsTheBootCatalog() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bc-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(count: 10).write(to: root.appendingPathComponent("setup.exe"))
        try Data(count: 2048).write(to: root.appendingPathComponent("boot.catalog"))

        let rels = try WindowsUSBWriter.fileList(root: root.path).map(\.rel).sorted()
        XCTAssertEqual(rels, ["setup.exe"])
    }

    /// The whole failure: an unreadable boot.catalog must not stop the copy.
    func testCopyingAnImageWithAnUnreadableBootCatalogSucceeds() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bc2-\(UUID().uuidString)")
        let iso = tmp.appendingPathComponent("iso"), usb = tmp.appendingPathComponent("usb")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644],
                                  ofItemAtPath: iso.appendingPathComponent("boot.catalog").path)
            try? fm.removeItem(at: tmp)
        }
        try Data(count: 32).write(to: iso.appendingPathComponent("setup.exe"))
        try Data(count: 64).write(to: iso.appendingPathComponent("sources/install.wim"))
        let catalog = iso.appendingPathComponent("boot.catalog")
        try Data(count: 2048).write(to: catalog)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: catalog.path)
        XCTAssertFalse(fm.isReadableFile(atPath: catalog.path), "fixture must be unreadable")

        let writer = WindowsUSBWriter(runner: SystemProcessRunner(), wim: NativeWimSplitter())
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 64, progress: { _, _ in })

        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("setup.exe").path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("boot.catalog").path),
                       "the boot catalog is meaningless on FAT32 and should not be copied")
    }

    /// A copy failure that is *not* the boot catalog must still fail, and must name the file —
    /// the raw Cocoa error the user saw ("Code=513") identified nothing.
    func testAnUnreadableFileFailsWithItsNameInTheMessage() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bc3-\(UUID().uuidString)")
        let iso = tmp.appendingPathComponent("iso"), usb = tmp.appendingPathComponent("usb")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        let secret = iso.appendingPathComponent("sources/locked.bin")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path)
            try? fm.removeItem(at: tmp)
        }
        try Data(count: 64).write(to: iso.appendingPathComponent("sources/install.wim"))
        try Data(count: 16).write(to: secret)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)

        let writer = WindowsUSBWriter(runner: SystemProcessRunner(), wim: NativeWimSplitter())
        XCTAssertThrowsError(try writer.copyAndSplit(
            mountedISORoot: iso.path, usbMountPoint: usb.path,
            installImageRelPath: "sources/install.wim",
            installImageSizeBytes: 64, progress: { _, _ in })) { error in
            XCTAssertTrue("\(error)".contains("locked.bin"), "error should name the file: \(error)")
        }
    }
}

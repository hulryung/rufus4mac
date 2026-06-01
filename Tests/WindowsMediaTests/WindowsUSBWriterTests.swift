import XCTest
@testable import WindowsMedia

final class WindowsUSBWriterTests: XCTestCase {
    func testFormatsThenInvokesSplitForLargeWim() throws {
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        // sparse 4.1 GB install.wim (no real bytes)
        let wim = iso.appendingPathComponent("sources/install.wim")
        fm.createFile(atPath: wim.path, contents: nil)
        let fh = try FileHandle(forWritingTo: wim); try fh.truncate(atOffset: 4_100 * 1024 * 1024); try fh.close()
        try Data(count: 10).write(to: iso.appendingPathComponent("setup.exe"))
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake,
                                      wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        var phases: [String] = []
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 4_100 * 1024 * 1024,
                                progress: { phase, _ in if phases.last != phase { phases.append(phase) } })

        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("setup.exe").path))
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertTrue(fake.calls.contains { $0.0 == "/x/wimlib-imagex" && $0.1.first == "split"
            && $0.1[2].hasSuffix("sources/install.swm") })
        XCTAssertEqual(phases, ["copying", "splitting"])
    }

    func testCopiesWimDirectlyWhenSmall() throws {
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(count: 2048).write(to: iso.appendingPathComponent("sources/install.wim"))
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake, wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 2048, progress: { _, _ in })
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertFalse(fake.calls.contains { $0.1.first == "split" })
    }
}

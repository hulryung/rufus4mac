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
        // Stand in for wimlib writing the two parts, so post-split verification has something real.
        fake.onRun = { _, args in
            guard args.first == "split" else { return }
            Self.makeSparse(usb.appendingPathComponent("sources/install.swm"), 3_900 * 1024 * 1024)
            Self.makeSparse(usb.appendingPathComponent("sources/install2.swm"), 300 * 1024 * 1024)
        }
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

    func testThrowsForOversizedNonWimInstallImage() throws {
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: iso.appendingPathComponent("sources/install.esd"))
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake, wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        XCTAssertThrowsError(try writer.copyAndSplit(
            mountedISORoot: iso.path, usbMountPoint: usb.path,
            installImageRelPath: "sources/install.esd",
            installImageSizeBytes: 5_000 * 1024 * 1024, progress: { _, _ in }))
    }

    /// A sparse file of `size` bytes at `url`, creating parent directories.
    static func makeSparse(_ url: URL, _ size: UInt64) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        try? fh.truncate(atOffset: size); try? fh.close()
    }

    /// Build an ISO/USB pair, run the faked split with `parts`, and return the thrown error, if any.
    private func splitProducing(_ parts: [(String, UInt64)], sourceMiB: UInt64 = 4_100) throws -> Error? {
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        Self.makeSparse(iso.appendingPathComponent("sources/install.wim"), sourceMiB * 1024 * 1024)
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        fake.onRun = { _, args in
            guard args.first == "split" else { return }
            for (name, size) in parts {
                Self.makeSparse(usb.appendingPathComponent("sources/\(name)"), size)
            }
        }
        let writer = WindowsUSBWriter(runner: fake, wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        do {
            try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                    installImageRelPath: "sources/install.wim",
                                    installImageSizeBytes: sourceMiB * 1024 * 1024, progress: { _, _ in })
            return nil
        } catch { return error }
    }

    /// The 0x8007000D regression: wimlib exits 0 when a USB drops off the bus mid-split, leaving a
    /// truncated install.swm that only fails much later inside Windows Setup.
    func testThrowsWhenSplitIsTruncated() throws {
        let err = try splitProducing([("install.swm", 700 * 1024 * 1024)])
        XCTAssertNotNil(err, "a 700 MB split of a 4100 MB image must not be accepted")
        XCTAssertTrue("\(err!)".contains("not fully written"), "\(err!)")
    }
    func testThrowsWhenSplitProducesNoParts() throws {
        let err = try splitProducing([])
        XCTAssertNotNil(err)
        XCTAssertTrue("\(err!)".contains("no .swm parts"), "\(err!)")
    }
    func testThrowsWhenAPartExceedsTheFAT32FileLimit() throws {
        let err = try splitProducing([("install.swm", 4 * 1024 * 1024 * 1024)])
        XCTAssertNotNil(err)
        XCTAssertTrue("\(err!)".contains("4 GB file limit"), "\(err!)")
    }
    func testAcceptsACompleteSplit() throws {
        XCTAssertNil(try splitProducing([("install.swm", 3_900 * 1024 * 1024),
                                         ("install2.swm", 300 * 1024 * 1024)]))
    }

    func testVerifyCopyRejectsATruncatedFile() throws {
        let fm = FileManager.default
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: usb) }
        try Data(count: 100).write(to: usb.appendingPathComponent("setup.exe"))

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake, wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        XCTAssertThrowsError(try writer.verifyCopy(entries: [.init(rel: "setup.exe", size: 4096)],
                                                   usbMountPoint: usb.path, skipping: nil))
        XCTAssertThrowsError(try writer.verifyCopy(entries: [.init(rel: "gone.exe", size: 1)],
                                                   usbMountPoint: usb.path, skipping: nil))
        XCTAssertNoThrow(try writer.verifyCopy(entries: [.init(rel: "setup.exe", size: 100)],
                                               usbMountPoint: usb.path, skipping: nil))
    }

    func testFormatUsesMBRSoTheUSBGetsNoEFISystemPartition() throws {
        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake,
                                      wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        try writer.format(bsdName: "disk9", volumeName: "WIN")

        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "/usr/sbin/diskutil")
        // Regression guard: "GPT" makes diskutil prepend a 200 MB EFI System Partition, which
        // Windows Setup can adopt as the boot volume instead of creating one on the target
        // disk — the installed machine then boots only while the USB is attached. Keep MBR.
        XCTAssertEqual(fake.calls[0].1, ["eraseDisk", "MS-DOS", "WIN", "MBR", "/dev/disk9"])
    }
}

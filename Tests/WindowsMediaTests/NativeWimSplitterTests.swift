import XCTest
import SystemTools
@testable import WindowsMedia

/// The write path with the MIT splitter swapped in for wimlib: proves the protocol wiring, and that
/// `copyAndSplit`'s post-write verification works without shelling out to wimlib at all.
final class NativeWimSplitterTests: XCTestCase {
    private func imagex() throws -> String {
        guard let p = WimTool.locateImagex(bundledDir: nil) else {
            throw XCTSkip("wimlib-imagex not installed")
        }
        return p
    }

    func testCopyAndSplitRunsEndToEndWithTheNativeSplitter() throws {
        let imagex = try imagex()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("nws-\(UUID().uuidString)")
        let iso = tmp.appendingPathComponent("iso"), usb = tmp.appendingPathComponent("usb")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // A capture dir big enough that a 2 MiB part size forces several parts.
        let cap = tmp.appendingPathComponent("cap")
        try fm.createDirectory(at: cap, withIntermediateDirectories: true)
        for i in 1...6 {
            try Data((0..<(1_200 * 1024)).map { UInt8(($0 &* (i + 1)) % 251) })
                .write(to: cap.appendingPathComponent("f\(i).bin"))
        }
        let runner = SystemProcessRunner()
        let wim = iso.appendingPathComponent("sources/install.wim")
        let cap1 = try runner.run(imagex, ["capture", cap.path, wim.path, "--compress=none"])
        XCTAssertEqual(cap1.status, 0, cap1.stderr)
        try Data(count: 32).write(to: iso.appendingPathComponent("setup.exe"))

        let size = (try fm.attributesOfItem(atPath: wim.path)[.size] as! NSNumber).uint64Value
        let writer = WindowsUSBWriter(runner: runner, wim: NativeWimSplitter(),
                                      splitThreshold: 2 * 1024 * 1024, splitChunkMB: 2)
        var phases: [String] = []
        var lastFraction: Double = -1
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: size,
                                progress: { ph, fr in
                                    if phases.last != ph { phases.append(ph) }
                                    if ph == "splitting" { lastFraction = fr }
                                })

        XCTAssertEqual(phases, ["copying", "splitting"])
        XCTAssertEqual(lastFraction, 1, "splitting should report completion")
        let parts = try fm.contentsOfDirectory(atPath: usb.appendingPathComponent("sources").path)
            .filter { $0.hasSuffix(".swm") }.sorted()
        XCTAssertGreaterThan(parts.count, 1, "expected several parts, got \(parts)")
        XCTAssertTrue(parts.contains("install.swm"))
        XCTAssertTrue(parts.contains("install2.swm"))
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("setup.exe").path))

        // wimlib reads back what the native splitter wrote through the app's own write path.
        let refs = usb.appendingPathComponent("sources/install*.swm").path
        let v = try runner.run(imagex, ["verify", usb.appendingPathComponent("sources/install.swm").path,
                                        "--ref=\(refs)"])
        XCTAssertEqual(v.status, 0, "wimlib rejected the native split:\n\(v.stdout)\(v.stderr)")
    }

    func testBothSplittersNameThemselves() {
        XCTAssertEqual(NativeWimSplitter().name, "WimSplit")
        XCTAssertEqual(WimTool(runner: SystemProcessRunner(), imagexPath: "/x").name, "wimlib-imagex")
    }
}

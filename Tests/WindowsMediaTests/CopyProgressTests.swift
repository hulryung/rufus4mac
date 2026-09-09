import XCTest
import SystemTools
@testable import WindowsMedia

/// Regression for a progress bar that sat at 13% and then jumped to 96%.
///
/// A Windows ISO is mostly one enormous file — install.wim is often ~90% of the bytes — and
/// `FileManager.copyItem` reports nothing until it returns, so progress only moved between files.
final class CopyProgressTests: XCTestCase {
    func testLargeFileReportsProgressWhileItIsCopied() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let size = WindowsUSBWriter.chunkedCopyThreshold + (8 << 20)
        let src = dir.appendingPathComponent("big.bin")
        try Data(count: Int(size)).write(to: src)

        var updates: [UInt64] = []
        try WindowsUSBWriter.copyFile(from: src.path, to: dir.appendingPathComponent("out.bin").path,
                                      size: size) { updates.append($0) }

        XCTAssertGreaterThan(updates.count, 1, "a large file must report progress as it moves")
        XCTAssertEqual(updates.reduce(0, +), size, "reported bytes must add up to the file size")
        let out = try Data(contentsOf: dir.appendingPathComponent("out.bin"))
        XCTAssertEqual(UInt64(out.count), size)
    }

    func testSmallFileIsReportedOnceAndCopiedIntact() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cp2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let src = dir.appendingPathComponent("small.bin")
        try payload.write(to: src)

        var updates: [UInt64] = []
        try WindowsUSBWriter.copyFile(from: src.path, to: dir.appendingPathComponent("o.bin").path,
                                      size: UInt64(payload.count)) { updates.append($0) }
        XCTAssertEqual(updates, [UInt64(payload.count)])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("o.bin")), payload)
    }

    /// The end-to-end shape of the bug: one file holding most of the bytes must not leave the bar
    /// parked and then leap.
    func testProgressAdvancesThroughAnISODominatedByOneFile() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cp3-\(UUID().uuidString)")
        let iso = tmp.appendingPathComponent("iso"), usb = tmp.appendingPathComponent("usb")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for i in 1...20 { try Data(count: 4096).write(to: iso.appendingPathComponent("f\(i).bin")) }
        let big = WindowsUSBWriter.chunkedCopyThreshold + (16 << 20)
        try Data(count: Int(big)).write(to: iso.appendingPathComponent("sources/install.wim"))

        var fractions: [Double] = []
        let writer = WindowsUSBWriter(runner: SystemProcessRunner(), wim: NativeWimSplitter())
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: big,
                                progress: { phase, f in if phase == "copying" { fractions.append(f) } })

        XCTAssertEqual(try XCTUnwrap(fractions.last), 1, accuracy: 0.0001)
        // Without chunked copying this lands in one leap; with it there are many intermediate steps.
        let midway = fractions.filter { $0 > 0.2 && $0 < 0.9 }
        XCTAssertGreaterThan(midway.count, 3,
                             "expected progress through the middle, saw \(fractions.map { Int($0 * 100) })")
        XCTAssertEqual(fractions, fractions.sorted(), "progress went backwards")
    }
}

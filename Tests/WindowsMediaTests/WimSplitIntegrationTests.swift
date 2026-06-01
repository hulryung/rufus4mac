import XCTest
@testable import WindowsMedia

final class WimSplitIntegrationTests: XCTestCase {
    func testRealSplitProducesMultipleParts() throws {
        guard let imagex = WimTool.locateImagex(bundledDir: nil) else {
            throw XCTSkip("wimlib-imagex not installed")
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wim-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Build a ~6 MB capture dir, then capture into a .wim.
        let cap = tmp.appendingPathComponent("cap")
        try fm.createDirectory(at: cap, withIntermediateDirectories: true)
        let big = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 251) })
        try big.write(to: cap.appendingPathComponent("payload.bin"))
        let wim = tmp.appendingPathComponent("test.wim")
        let runner = SystemProcessRunner()
        let cap1 = try runner.run(imagex, ["capture", cap.path, wim.path, "--compress=none"])
        XCTAssertEqual(cap1.status, 0, cap1.stderr)

        // Split into ~2 MB parts.
        let tool = WimTool(runner: runner, imagexPath: imagex)
        let outFirst = tmp.appendingPathComponent("test.swm")
        try tool.split(wim: wim.path, outFirstSWM: outFirst.path, chunkMB: 2)

        let parts = try fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".swm") }
        XCTAssertGreaterThanOrEqual(parts.count, 2, "expected multiple .swm parts, got \(parts)")
    }
}

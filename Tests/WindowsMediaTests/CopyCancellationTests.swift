import XCTest
@testable import WindowsMedia

final class CopyCancellationTests: XCTestCase {
    func testDriverCancellationRemovesStageAndPreservesExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("library/PC")
        let usb = root.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: 20 << 20).write(to: source.appendingPathComponent("wifi.bin"))
        try Data("keep".utf8).write(to: usb.appendingPathComponent("existing.txt"))
        let job = Task.detached {
            do {
                try DriverStore.addToExistingVolume(profileNames: ["PC"], from: root.appendingPathComponent("library").path, to: usb.path) { fraction in
                    if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await job.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try String(contentsOf: usb.appendingPathComponent("existing.txt"), encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("Drivers/PC").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: usb.path).contains { $0.hasPrefix(".rufus-drivers-") })
    }
}

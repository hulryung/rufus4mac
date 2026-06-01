import XCTest
@testable import WindowsMedia

final class ISOMountIntegrationTests: XCTestCase {
    func testMountAndDetectSynthesizedWindowsISO() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("winiso-\(UUID().uuidString)")
        let root = work.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("sources/install.wim"))
        try Data(count: 16).write(to: root.appendingPathComponent("efi/boot/bootx64.efi"))
        defer { try? fm.removeItem(at: work) }

        let iso = work.appendingPathComponent("win.iso")
        let runner = SystemProcessRunner()
        let mk = try runner.run("/usr/bin/hdiutil",
            ["makehybrid", "-iso", "-udf", "-o", iso.path, root.path])
        XCTAssertEqual(mk.status, 0, mk.stderr)
        let isoPath = fm.fileExists(atPath: iso.path) ? iso.path : iso.path + ".cdr"

        let inspector = ISOInspector(runner: runner)
        let info = try inspector.mountAndInspect(isoPath: isoPath)
        defer { inspector.detach(mountPoint: info.mountPoint) }
        XCTAssertTrue(info.isWindows)
        XCTAssertEqual(info.installImageRelPath, "sources/install.wim")
        XCTAssertEqual(info.installImageSizeBytes, 4096)
    }
}

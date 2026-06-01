import XCTest
@testable import WindowsMedia

final class ISOInspectorTests: XCTestCase {
    private func makeTree(_ files: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        for (rel, size) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    func testDetectsWindowsByInstallWimAndEfiBoot() throws {
        let root = try makeTree(["sources/install.wim": 1000, "efi/boot/bootx64.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.wim")
        XCTAssertEqual(d.installImageSizeBytes, 1000)
    }

    func testDetectsInstallEsd() throws {
        let root = try makeTree(["sources/install.esd": 500, "efi/boot/bootx64.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.esd")
    }

    func testNonWindowsTreeIsNotDetected() throws {
        let root = try makeTree(["casper/vmlinuz": 10, "boot/grub/grub.cfg": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertFalse(d.isWindows)
        XCTAssertNil(d.installImageRelPath)
    }

    func testInstallWimWithoutBootFileIsNotWindows() throws {
        // AND condition: install image present but NO UEFI boot file → not Windows.
        let root = try makeTree(["sources/install.wim": 1000])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertFalse(d.isWindows)
        XCTAssertNil(d.installImageRelPath)
    }

    func testInstallWimTakesPriorityOverEsd() throws {
        let root = try makeTree(["sources/install.wim": 1000, "sources/install.esd": 2000,
                                 "efi/boot/bootx64.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.wim")
        XCTAssertEqual(d.installImageSizeBytes, 1000)
    }

    func testDetectsViaBootmgfwEfiPath() throws {
        // Older media: only efi/microsoft/boot/bootmgfw.efi present (no efi/boot/bootx64.efi).
        let root = try makeTree(["sources/install.wim": 500,
                                 "efi/microsoft/boot/bootmgfw.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.wim")
    }
}

import XCTest
@testable import WindowsMedia

final class WindowsCustomizerTests: XCTestCase {
    private func tmpUSB() throws -> URL {
        let usb = FileManager.default.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: usb.appendingPathComponent("sources"),
                                                withIntermediateDirectories: true)
        return usb
    }
    func testBypassZeroesAppraiserAndWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try Data(count: 4096).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init(bypassWin11: true, skipPrivacy: true))
        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 0)
        let xml = try String(contentsOfFile: usb.appendingPathComponent("autounattend.xml").path, encoding: .utf8)
        XCTAssertTrue(xml.contains("LabConfig"))
        XCTAssertTrue(xml.contains("ProtectYourPC"))
    }
    func testNoBypassDoesNotZeroAppraiserButStillWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try Data(count: 4096).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init(localAccountUsername: "joe"))
        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 4096)
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
    func testEmptyOptionsWritesNothing() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init())
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
}

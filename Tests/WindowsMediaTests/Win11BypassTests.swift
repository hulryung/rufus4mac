import XCTest
@testable import WindowsMedia

final class Win11BypassTests: XCTestCase {
    func testZeroesAppraiserAndWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try fm.createDirectory(at: usb.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))
        defer { try? fm.removeItem(at: usb) }

        try Win11Bypass.apply(usbRoot: usb.path)

        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 0)
        let autoun = usb.appendingPathComponent("autounattend.xml").path
        let xml = try String(contentsOfFile: autoun, encoding: .utf8)
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains("BypassCPUCheck"))
        XCTAssertTrue(xml.hasPrefix("<?xml"), "autounattend must start with <?xml at column 0")
    }

    func testNoAppraiserStillWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: usb) }
        XCTAssertNoThrow(try Win11Bypass.apply(usbRoot: usb.path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
}

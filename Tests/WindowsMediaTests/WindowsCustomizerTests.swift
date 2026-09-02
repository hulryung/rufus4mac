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
    /// End-to-end 0x8007000D regression: a ko-KR-only image must not be told to use en-US UI.
    func testUILanguageComesFromTheMediumNotTheMac() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try "[Available UI Languages]\r\nko-kr = 3\r\n"
            .write(to: usb.appendingPathComponent("sources/lang.ini"), atomically: true, encoding: .utf8)
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init(regionLocale: "en-US"))
        let xml = try String(contentsOfFile: usb.appendingPathComponent("autounattend.xml").path, encoding: .utf8)
        XCTAssertTrue(xml.contains("<UILanguage>ko-KR</UILanguage>"))
        XCTAssertFalse(xml.contains("<UILanguage>en-US</UILanguage>"))
        XCTAssertTrue(xml.contains("<UserLocale>en-US</UserLocale>"))
    }
    func testEmptyOptionsWritesNothing() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init())
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
}

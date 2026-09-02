import XCTest
@testable import WindowsMedia

final class WindowsLocaleTests: XCTestCase {
    /// The 0x8007000D regression: a Mac set to English + Korea produced "en-KR", which no Windows
    /// build knows, and Setup rejected the answer file.
    func testEnglishLanguageInKoreaFallsBackToEnUS() {
        XCTAssertEqual(WindowsLocale.windowsName(language: "en", region: "KR"), "en-US")
    }
    func testKnownPairIsKept() {
        XCTAssertEqual(WindowsLocale.windowsName(language: "ko", region: "KR"), "ko-KR")
        XCTAssertEqual(WindowsLocale.windowsName(language: "en", region: "GB"), "en-GB")
        XCTAssertEqual(WindowsLocale.windowsName(language: "pt", region: "PT"), "pt-PT")
    }
    func testCasingIsNormalized() {
        XCTAssertEqual(WindowsLocale.windowsName(language: "KO", region: "kr"), "ko-KR")
    }
    func testMissingRegionUsesLanguageDefault() {
        XCTAssertEqual(WindowsLocale.windowsName(language: "ja", region: nil), "ja-JP")
        XCTAssertEqual(WindowsLocale.windowsName(language: "pt", region: nil), "pt-BR")
    }
    func testUnknownLanguageIsNil() {
        XCTAssertNil(WindowsLocale.windowsName(language: "xx", region: "YY"))
        XCTAssertNil(WindowsLocale.windowsName(language: nil, region: "KR"))
        XCTAssertNil(WindowsLocale.windowsName(language: "", region: "KR"))
    }
    func testCurrentIsEitherNilOrAKnownWindowsLocale() {
        if let l = WindowsLocale.current(Locale(identifier: "en_KR")) {
            XCTAssertTrue(WindowsLocale.known.contains(l), "\(l) is not a Windows locale")
        }
    }
    func testCanonical() {
        XCTAssertEqual(WindowsLocale.canonical("ko-kr"), "ko-KR")
        XCTAssertEqual(WindowsLocale.canonical("EN-us"), "en-US")
        XCTAssertEqual(WindowsLocale.canonical("neutral"), "neutral")
    }
}

final class WindowsImageLanguageTests: XCTestCase {
    /// Verbatim shape of sources/lang.ini on a retail ko-KR Windows 11 ISO.
    private let koIni = "\r\n[Available UI Languages]\r\nko-kr = 3\r\n\r\n[Fallback Languages]\r\nko-kr = en-us\r\n"

    func testParsesOnlyTheAvailableSection() {
        XCTAssertEqual(WindowsImageLanguage.availableUILanguages(iniContents: koIni), ["ko-KR"])
    }
    func testParsesMultipleLanguages() {
        let ini = "[Available UI Languages]\nen-us = 3\nfr-fr = 3\n[Fallback Languages]\nfr-fr = en-us\n"
        XCTAssertEqual(WindowsImageLanguage.availableUILanguages(iniContents: ini), ["en-US", "fr-FR"])
    }
    func testNoSectionYieldsNothing() {
        XCTAssertTrue(WindowsImageLanguage.availableUILanguages(iniContents: "[Fallback Languages]\nko-kr = en-us\n").isEmpty)
    }

    private func makeMedium(ini: String?) throws -> String {
        let root = NSTemporaryDirectory() + "langini-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/sources", withIntermediateDirectories: true)
        if let ini { try ini.write(toFile: root + "/sources/lang.ini", atomically: true, encoding: .utf8) }
        return root
    }

    func testDesiredLanguageUsedWhenImageShipsIt() throws {
        let root = try makeMedium(ini: koIni)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(WindowsImageLanguage.uiLanguage(root: root, desired: "ko-KR"), "ko-KR")
    }
    /// The second half of the 0x8007000D bug: en-US is a real locale but this image has no en-US UI.
    func testDesiredLanguageAbsentFallsBackToTheImageLanguage() throws {
        let root = try makeMedium(ini: koIni)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(WindowsImageLanguage.uiLanguage(root: root, desired: "en-US"), "ko-KR")
    }
    func testMissingLangIniYieldsNil() throws {
        let root = try makeMedium(ini: nil)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertNil(WindowsImageLanguage.uiLanguage(root: root, desired: "en-US"))
    }
}

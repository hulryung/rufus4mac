import XCTest
@testable import Localization

final class LocalizationTests: XCTestCase {
    private let catalog = LocalizationCatalog()

    func testSystemPreferenceOrderAndRegionalFallbacks() {
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: ["ja_JP"]), "ja")
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: ["es-MX"]), "es")
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: ["fr-FR", "ja-JP", "en"]), "ja")
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: ["zh-Hant"]), "en")
        XCTAssertEqual(catalog.resolve(selection: "system", preferredLanguages: []), "en")
    }

    func testExplicitSelectionOverridesSystemAndInvalidSelectionFallsBack() {
        XCTAssertEqual(catalog.resolve(selection: "es", preferredLanguages: ["ko-KR"]), "es")
        XCTAssertEqual(catalog.resolve(selection: "invalid", preferredLanguages: ["ko-KR"]), "ko")
    }

    func testEveryConfiguredLanguageHasCompleteTranslationsAndSameArguments() throws {
        let english = catalog.table(for: "en")
        XCTAssertGreaterThan(english.count, 150)
        XCTAssertTrue(Set(["en", "ko", "ja", "es"]).isSubset(of: Set(catalog.languages.map(\.id))))
        XCTAssertEqual(Set(catalog.languages.map(\.id)).count, catalog.languages.count)
        let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ string: String) -> [String] {
            let ns = string as NSString
            return regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        for language in catalog.languages {
            let table = catalog.table(for: language.id)
            XCTAssertEqual(Set(table.keys), Set(english.keys), language.id)
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                XCTAssertEqual(placeholders(key), placeholders(value), "\(language.id): \(key)")
            }
        }
    }

    func testInterpolationSupportsReordering() {
        XCTAssertEqual(catalog.text("\(2) of \(8) models", language: "ko"), "모델 8개 중 2개")
        XCTAssertEqual(catalog.text("\(2) of \(8) models", language: "ja"), "8モデル中2件")
    }

    func testFileNamesAreNeverInterpretedAsFormatStrings() {
        let filename = "100% {1} %@.iso"
        let message: Message = "All data on \(filename) (\("32 GB")) will be permanently erased.\n\nImage: \("installer.iso")"
        let rendered = catalog.text(message, language: "ko")
        XCTAssertTrue(rendered.contains(filename))
        XCTAssertTrue(rendered.contains("32 GB"))
        XCTAssertTrue(rendered.contains("installer.iso"))
    }

    func testMissingTranslationFallsBackToReadableEnglish() {
        XCTAssertEqual(catalog.text("Cancel", language: "not-installed"), "Cancel")
        XCTAssertEqual(catalog.text("Untranslated: \("filename.iso")", language: "ko"), "Untranslated: filename.iso")
    }

    func testLocalizedDestructiveConfirmationRetainsAllDetails() {
        let message: Message = "All data on \("/dev/disk4") (\("32 GB")) will be permanently erased.\n\nFormat: \("FAT32") · \("MBR")\nDrive name: \("MYUSB")"
        for language in catalog.languages {
            let result = catalog.text(message, language: language.id)
            for detail in ["/dev/disk4", "32 GB", "FAT32", "MBR", "MYUSB"] {
                XCTAssertTrue(result.contains(detail), "\(language.id): \(detail)")
            }
            XCTAssertFalse(result.contains("{0}"))
        }
    }
}

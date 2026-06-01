import XCTest
@testable import DiskFormat

final class FormatOptionsTests: XCTestCase {
    func testUppercasesAndFiltersLabel() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "my usb! drive")
        XCTAssertEqual(o.normalizedLabel, "MYUSBDRIVE")
    }

    func testFat32CapsLabelTo11() {
        let o = FormatOptions(scheme: .mbr, fileSystem: .fat32, label: "ABCDEFGHIJKLMNOP")
        XCTAssertEqual(o.normalizedLabel.count, 11)
        XCTAssertEqual(o.normalizedLabel, "ABCDEFGHIJK")
    }

    func testExfatCapsLabelTo15() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "ABCDEFGHIJKLMNOPQRST")
        XCTAssertEqual(o.normalizedLabel.count, 15)
        XCTAssertEqual(o.normalizedLabel, "ABCDEFGHIJKLMNO")
    }

    func testEmptyLabelFallsBackToDefault() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "  !! ")
        XCTAssertEqual(o.normalizedLabel, "RUFUS4MAC")
    }

    func testPersonalityAndSchemeStrings() {
        XCTAssertEqual(FormatOptions.FileSystem.exfat.personality, "ExFAT")
        XCTAssertEqual(FormatOptions.FileSystem.fat32.personality, "MS-DOS FAT32")
        XCTAssertEqual(FormatOptions.PartitionScheme.gpt.rawValue, "GPT")
        XCTAssertEqual(FormatOptions.PartitionScheme.mbr.rawValue, "MBR")
    }
}

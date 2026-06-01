import XCTest
import SystemTools
@testable import DiskFormat

private final class FakeRunner: ProcessRunner, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessResult(status: 0, stdout: "", stderr: "")
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments)); return result
    }
}

final class DiskFormatterTests: XCTestCase {
    func testExfatGptArgs() throws {
        let fake = FakeRunner()
        let f = DiskFormatter(runner: fake)
        try f.format(bsdName: "disk8", options: .init(scheme: .gpt, fileSystem: .exfat, label: "My USB"))
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "/usr/sbin/diskutil")
        XCTAssertEqual(fake.calls[0].1, ["eraseDisk", "ExFAT", "MYUSB", "GPT", "/dev/disk8"])
    }

    func testFat32MbrArgs() throws {
        let fake = FakeRunner()
        let f = DiskFormatter(runner: fake)
        try f.format(bsdName: "disk5", options: .init(scheme: .mbr, fileSystem: .fat32, label: ""))
        XCTAssertEqual(fake.calls[0].1, ["eraseDisk", "MS-DOS FAT32", "RUFUS4MAC", "MBR", "/dev/disk5"])
    }

    func testThrowsOnNonZeroStatus() {
        let fake = FakeRunner(); fake.result = ProcessResult(status: 1, stdout: "", stderr: "busy")
        let f = DiskFormatter(runner: fake)
        XCTAssertThrowsError(try f.format(bsdName: "disk8",
                                          options: .init(scheme: .gpt, fileSystem: .exfat, label: "X"))) {
            XCTAssertTrue($0 is DiskFormatError)
        }
    }
}

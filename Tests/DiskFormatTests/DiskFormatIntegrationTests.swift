import XCTest
import SystemTools
@testable import DiskFormat

final class DiskFormatIntegrationTests: XCTestCase {
    private func runFormat(_ options: FormatOptions, expectContains: [String]) throws {
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).img")
        fm.createFile(atPath: img.path, contents: nil)
        let fh = try FileHandle(forWritingTo: img); try fh.truncate(atOffset: 256 * 1024 * 1024); try fh.close()
        defer { try? fm.removeItem(at: img) }
        let runner = SystemProcessRunner()
        let att = try runner.run("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        guard let dev = att.stdout.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
        else { throw XCTSkip("attach failed") }
        let bsd = String(dev.dropFirst("/dev/".count))
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "/dev/\(bsd)", "-force"]) }

        try DiskFormatter(runner: runner).format(bsdName: bsd, options: options)

        let list = try runner.run("/usr/sbin/diskutil", ["list", "/dev/\(bsd)"]).stdout
        for needle in expectContains {
            XCTAssertTrue(list.contains(needle), "expected '\(needle)' in:\n\(list)")
        }
    }

    func testFormatExfatGpt() throws {
        try runFormat(.init(scheme: .gpt, fileSystem: .exfat, label: "EXFATVOL"),
                      expectContains: ["GUID_partition_scheme", "EXFATVOL"])
    }

    func testFormatFat32Mbr() throws {
        try runFormat(.init(scheme: .mbr, fileSystem: .fat32, label: "FATVOL"),
                      expectContains: ["FDisk_partition_scheme", "FATVOL"])
    }
}

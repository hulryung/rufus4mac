import XCTest
import SystemTools
@testable import WindowsMedia

final class DiskutilFormatSpikeTests: XCTestCase {
    func testFormatFat32OnAttachedImageWithoutSudo() throws {
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).img")
        fm.createFile(atPath: img.path, contents: nil)
        let fh = try FileHandle(forWritingTo: img); try fh.truncate(atOffset: 256 * 1024 * 1024); try fh.close()
        defer { try? fm.removeItem(at: img) }
        let runner = SystemProcessRunner()

        // Attach without mounting; parse /dev/diskN.
        let att = try runner.run("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        let dev = att.stdout.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
        let bsd = dev.map { String($0.dropFirst("/dev/".count)) }
        guard let bsd else { throw XCTSkip("could not attach image") }
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "/dev/\(bsd)", "-force"]) }

        let writer = WindowsUSBWriter(runner: runner, wim: WimTool(runner: runner, imagexPath: "/x"))
        // KEY QUESTION: does this succeed WITHOUT sudo?
        XCTAssertNoThrow(try writer.format(bsdName: bsd, volumeName: "WIN"))
        // Confirm a FAT volume now exists on the disk.
        let list = try runner.run("/usr/sbin/diskutil", ["list", "/dev/\(bsd)"])
        XCTAssertTrue(list.stdout.contains("Microsoft Basic Data") || list.stdout.uppercased().contains("FAT"),
                      list.stdout)
    }
}

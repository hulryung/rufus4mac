import Foundation

/// Attaches a blank raw disk image via `hdiutil` for integration tests.
/// The resulting `/dev/diskN` is owned by the current user, so the write
/// path can be exercised without root. `hdiutil` is a test-only dependency.
public final class HdiutilDevice {
    public let bsdDiskPath: String      // /dev/diskN
    public var bsdRawPath: String {     // /dev/rdiskN
        bsdDiskPath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
    }
    private let imageURL: URL

    public init(sizeMB: Int) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdi-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
        try fh.close()
        self.imageURL = url

        let out = try HdiutilDevice.run(
            "/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", url.path]
        )
        guard let dev = out.split(separator: "\n").first?
            .split(separator: " ").first.map(String.init) else {
            throw NSError(domain: "HdiutilDevice", code: 1)
        }
        self.bsdDiskPath = dev
    }

    public func detach() {
        _ = try? HdiutilDevice.run("/usr/bin/hdiutil", ["detach", bsdDiskPath])
        try? FileManager.default.removeItem(at: imageURL)
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

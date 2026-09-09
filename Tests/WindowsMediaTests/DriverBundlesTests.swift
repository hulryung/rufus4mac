import XCTest
@testable import WindowsMedia

final class DriverBundlesTests: XCTestCase {
    private var root: URL!
    private var usb: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drv-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("store")
        usb = tmp.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func addProfile(_ name: String, files: [String: Int]) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (f, size) in files {
            try Data(count: size).write(to: dir.appendingPathComponent(f))
        }
    }

    // MARK: - discovery

    func testNoStoreYieldsNoProfiles() {
        XCTAssertEqual(DriverStore.profiles(in: root.appendingPathComponent("nope").path), [])
    }

    func testEachDirectoryIsAProfileSortedByName() throws {
        try addProfile("NT960XEV", files: ["wifi.exe": 100])
        try addProfile("NT950XEV", files: ["wifi.exe": 200, "lan.exe": 50])
        let ps = DriverStore.profiles(in: root.path)
        XCTAssertEqual(ps.map(\.name), ["NT950XEV", "NT960XEV"])
        XCTAssertEqual(ps[0].files, ["lan.exe", "wifi.exe"])
        XCTAssertEqual(ps[0].totalSize, 250)
    }

    func testLooseFilesAndDotDirectoriesAreNotProfiles() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 10])
        try Data(count: 5).write(to: root.appendingPathComponent("stray.exe"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(DriverStore.profiles(in: root.path).map(\.name), ["NT950XEV"])
    }

    func testDotFilesInsideAProfileAreIgnored() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 10, ".DS_Store": 3])
        XCTAssertEqual(DriverStore.profiles(in: root.path)[0].files, ["wifi.exe"])
        XCTAssertEqual(DriverStore.profiles(in: root.path)[0].totalSize, 10)
    }

    // MARK: - copying

    func testCopiesOnlyTheSelectedProfiles() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 128])
        try addProfile("NT960XEV", files: ["wifi.exe": 64])
        let copied = try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path)

        XCTAssertEqual(copied.map(\.name), ["NT950XEV"])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("Drivers/NT950XEV/wifi.exe").path))
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("Drivers/NT960XEV").path))
    }

    /// The folder must not be $WinPEDriver$: that name makes Windows Setup install the drivers
    /// during installation, and these are meant to be run by hand afterwards.
    func testUsesAPlainDriversFolderSoSetupIgnoresIt() {
        XCTAssertEqual(DriverStore.usbFolderName, "Drivers")
        XCTAssertNotEqual(DriverStore.usbFolderName, "$WinPEDriver$")
    }

    func testFileContentsSurviveTheCopy() throws {
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let dir = root.appendingPathComponent("NT950XEV")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.write(to: dir.appendingPathComponent("wifi.exe"))
        try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path)
        XCTAssertEqual(try Data(contentsOf: usb.appendingPathComponent("Drivers/NT950XEV/wifi.exe")), payload)
    }

    /// A selection left over from a profile the user deleted must not cost them a finished USB.
    func testStaleAndEmptySelectionsAreSkippedNotFatal() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 10])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"),
                                                withIntermediateDirectories: true)
        let copied = try DriverStore.copy(profileNames: ["NT950XEV", "Deleted", "Empty"],
                                          from: root.path, to: usb.path)
        XCTAssertEqual(copied.map(\.name), ["NT950XEV"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("Drivers/Empty").path))
    }

    func testNothingSelectedWritesNoFolder() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 10])
        XCTAssertEqual(try DriverStore.copy(profileNames: [], from: root.path, to: usb.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("Drivers").path))
    }

    func testProgressRunsFromZeroToOne() throws {
        try addProfile("NT950XEV", files: ["a.exe": 1000, "b.exe": 1000])
        var seen: [Double] = []
        try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path,
                             progress: { seen.append($0) })
        XCTAssertEqual(seen.first, 0)
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(seen, seen.sorted(), "progress went backwards")
    }

    // MARK: - verification

    func testVerifyAcceptsAGoodCopy() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 256])
        let copied = try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path)
        XCTAssertNoThrow(try DriverStore.verify(profiles: copied, root: root.path, usbRoot: usb.path))
    }

    func testVerifyCatchesATruncatedFile() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 256])
        let copied = try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path)
        try Data(count: 100).write(to: usb.appendingPathComponent("Drivers/NT950XEV/wifi.exe"))
        XCTAssertThrowsError(try DriverStore.verify(profiles: copied, root: root.path, usbRoot: usb.path)) {
            XCTAssertTrue("\($0)".contains("incompletely"), "\($0)")
        }
    }

    func testVerifyCatchesAMissingFile() throws {
        try addProfile("NT950XEV", files: ["wifi.exe": 256])
        let copied = try DriverStore.copy(profileNames: ["NT950XEV"], from: root.path, to: usb.path)
        try FileManager.default.removeItem(at: usb.appendingPathComponent("Drivers/NT950XEV/wifi.exe"))
        XCTAssertThrowsError(try DriverStore.verify(profiles: copied, root: root.path, usbRoot: usb.path)) {
            XCTAssertTrue("\($0)".contains("missing"), "\($0)")
        }
    }
}

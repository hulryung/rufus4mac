import XCTest
@testable import DiskDiscovery

final class DiskInfoTests: XCTestCase {
    func testHumanReadableSize() {
        let d = DiskInfo(bsdName: "disk4", model: "SanDisk USB", sizeBytes: 16_000_000_000,
                         isRemovable: true)
        XCTAssertEqual(d.displaySize, "16 GB")
        XCTAssertEqual(d.devicePath, "/dev/disk4")
        XCTAssertEqual(d.rawDevicePath, "/dev/rdisk4")
    }
}

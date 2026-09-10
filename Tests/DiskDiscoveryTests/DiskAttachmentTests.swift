import XCTest
@testable import DiskDiscovery

final class DiskAttachmentTests: XCTestCase {
    func testReusedBSDNameDoesNotMatchPreviousAttachment() {
        let old = DiskInfo(bsdName: "disk4", model: "USB", sizeBytes: 1024, isRemovable: true, registryID: 10)
        let replacement = DiskInfo(bsdName: "disk4", model: "USB", sizeBytes: 1024, isRemovable: true, registryID: 11)
        XCTAssertEqual(old.id, replacement.id)
        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse([replacement].contains(old))
        XCTAssertTrue([old].contains(old))
    }
}

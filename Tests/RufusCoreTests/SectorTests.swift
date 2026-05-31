import XCTest
@testable import RufusCore

final class SectorTests: XCTestCase {
    func testRoundUpToSector() {
        XCTAssertEqual(Sector.roundUp(0), 0)
        XCTAssertEqual(Sector.roundUp(1), 512)
        XCTAssertEqual(Sector.roundUp(512), 512)
        XCTAssertEqual(Sector.roundUp(513), 1024)
    }

    func testDefaultSizes() {
        XCTAssertEqual(Sector.size, 512)
        XCTAssertEqual(Sector.chunkSize % Sector.size, 0)
    }
}

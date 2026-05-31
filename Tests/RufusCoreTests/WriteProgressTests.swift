import XCTest
@testable import RufusCore

final class WriteProgressTests: XCTestCase {
    func testFraction() {
        let p = WriteProgress(bytesWritten: 50, totalBytes: 200)
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.0001)
    }

    func testFractionZeroTotalIsZero() {
        let p = WriteProgress(bytesWritten: 0, totalBytes: 0)
        XCTAssertEqual(p.fraction, 0)
    }
}

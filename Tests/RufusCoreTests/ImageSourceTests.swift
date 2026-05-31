import XCTest
@testable import RufusCore

final class ImageSourceTests: XCTestCase {
    private func makeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    func testSizeReportsByteCount() throws {
        let url = try makeTempFile(Array(repeating: 0xAB, count: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileImageSource(url: url)
        defer { src.close() }
        XCTAssertEqual(src.size, 1000)
    }

    func testReadReturnsChunksThenEmptyAtEOF() throws {
        let url = try makeTempFile(Array(0..<10).map { UInt8($0) })
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileImageSource(url: url)
        defer { src.close() }

        let first = try src.read(maxLength: 4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try src.read(maxLength: 100)
        XCTAssertEqual(Array(second), [4, 5, 6, 7, 8, 9])
        let third = try src.read(maxLength: 100)
        XCTAssertTrue(third.isEmpty)
    }
}

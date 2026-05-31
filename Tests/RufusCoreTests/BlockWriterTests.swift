import XCTest
@testable import RufusCore

final class BlockWriterTests: XCTestCase {
    func testFileBlockWriterWritesAllBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try FileBlockWriter(url: url)
        try writer.write(Data([1, 2, 3]))
        try writer.write(Data([4, 5]))
        try writer.finish()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(Array(written), [1, 2, 3, 4, 5])
    }
}

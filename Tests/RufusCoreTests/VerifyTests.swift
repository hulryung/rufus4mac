import XCTest
import CryptoKit
@testable import RufusCore

final class VerifyTests: XCTestCase {
    func testVerifySucceedsWhenBytesMatch() throws {
        let bytes = Data((0..<2000).map { UInt8($0 % 256) })
        let reader = MemoryBlockReader(bytes)
        let expected = SHA256.hash(data: bytes)
        let engine = WriteEngine()
        XCTAssertNoThrow(
            try engine.verify(reader: reader, imageSize: UInt64(bytes.count),
                              expectedHash: Data(expected), isCancelled: { false },
                              progress: { _ in })
        )
    }

    func testVerifyFailsOnMismatch() throws {
        let bytes = Data(repeating: 0xAA, count: 1024)
        let corrupted = Data(repeating: 0xBB, count: 1024)
        let reader = MemoryBlockReader(corrupted)
        let expected = SHA256.hash(data: bytes)
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.verify(reader: reader, imageSize: 1024,
                              expectedHash: Data(expected), isCancelled: { false },
                              progress: { _ in })
        ) { XCTAssertEqual($0 as? WriteError, .verificationMismatch) }
    }
}

/// Reads from an in-memory buffer; ignores reads past the buffer (returns empty).
private final class MemoryBlockReader: BlockReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    func read(maxLength: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(offset + maxLength, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    func close() {}
}

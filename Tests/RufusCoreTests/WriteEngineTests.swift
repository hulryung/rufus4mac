import XCTest
@testable import RufusCore

/// In-memory ImageSource for deterministic tests.
private final class MemoryImageSource: ImageSource {
    private var data: Data
    private var offset = 0
    let size: UInt64
    init(_ data: Data) { self.data = data; self.size = UInt64(data.count) }
    func read(maxLength: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(offset + maxLength, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    func close() {}
}

/// In-memory BlockWriter that records everything written.
private final class MemoryBlockWriter: BlockWriter {
    private(set) var written = Data()
    var failOnWrite = false
    func write(_ data: Data) throws {
        if failOnWrite { throw WriteError.writeFailed(errno: 5) }
        written.append(data)
    }
    func finish() throws {}
}

final class WriteEngineTests: XCTestCase {
    func testWritesExactBytesWhenSectorAligned() throws {
        let src = MemoryImageSource(Data(repeating: 0x42, count: 1024)) // 2 sectors
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(dst.written.count, 1024)
        XCTAssertEqual(dst.written, Data(repeating: 0x42, count: 1024))
    }

    func testPadsFinalPartialSectorWithZeros() throws {
        // 600 bytes -> rounds up to 1024 (2 sectors); tail padded with zeros.
        let src = MemoryImageSource(Data(repeating: 0x55, count: 600))
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(dst.written.count, 1024)
        XCTAssertEqual(Array(dst.written[0..<600]), Array(repeating: 0x55, count: 600))
        XCTAssertEqual(Array(dst.written[600..<1024]), Array(repeating: 0x00, count: 424))
    }

    func testProgressReachesTotal() throws {
        let src = MemoryImageSource(Data(repeating: 1, count: 300))
        let dst = MemoryBlockWriter()
        var last: WriteProgress?
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { last = $0 })
        XCTAssertEqual(last?.bytesWritten, 300)
        XCTAssertEqual(last?.totalBytes, 300)
    }

    func testCancellationThrows() {
        let src = MemoryImageSource(Data(repeating: 1, count: 10_000_000))
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.write(source: src, to: dst, isCancelled: { true }, progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? WriteError, .cancelled)
        }
    }

    func testWriteFailurePropagates() {
        let src = MemoryImageSource(Data(repeating: 1, count: 1024))
        let dst = MemoryBlockWriter()
        dst.failOnWrite = true
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? WriteError, .writeFailed(errno: 5))
        }
    }
}

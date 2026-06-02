import XCTest
@testable import RufusCore

private final class MemSource: ImageSource {
    private var data: Data; private var off = 0; let size: UInt64
    init(_ d: Data) { data = d; size = UInt64(d.count) }
    func read(maxLength: Int) throws -> Data {
        guard off < data.count else { return Data() }
        let end = min(off + maxLength, data.count); defer { off = end }
        return data.subdata(in: off..<end)
    }
    func close() {}
}

final class ChecksumsTests: XCTestCase {
    func testKnownVectorABC() throws {
        let r = try Checksums.compute(of: MemSource(Data("abc".utf8)),
                                      isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(r.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(r.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testKnownVectorEmpty() throws {
        let r = try Checksums.compute(of: MemSource(Data()), isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(r.sha1, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(r.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    func testMultiChunkMatchesOneShot() throws {
        let bytes = Data((0..<(10 * 1024 * 1024 + 7)).map { UInt8($0 % 251) })  // > one 4MiB chunk
        let r = try Checksums.compute(of: MemSource(bytes), isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5.count, 32)
        XCTAssertEqual(r.sha1.count, 40)
        XCTAssertEqual(r.sha256.count, 64)
    }
    func testCancellationThrows() {
        let bytes = Data(repeating: 1, count: 8 * 1024 * 1024)
        XCTAssertThrowsError(try Checksums.compute(of: MemSource(bytes),
                                                   isCancelled: { true }, progress: { _ in })) {
            XCTAssertEqual($0 as? WriteError, .cancelled)
        }
    }
}

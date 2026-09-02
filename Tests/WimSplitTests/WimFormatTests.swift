import XCTest
@testable import WimSplit

final class ResourceHeaderTests: XCTestCase {
    /// Layout taken from a real WIM: the size is 7 bytes and the 8th byte is flags, so a naive
    /// 8-byte size read would swallow the flags.
    func testParsesSevenByteSizeThenFlagsByte() throws {
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 0xFA                              // size = 250
        b[7] = 0x02                              // flags = metadata
        b[8] = 0x2A; b[9] = 0x04; b[10] = 0x18   // offset = 0x18042A
        b[16] = 0xFA                             // uncompressedSize = 250
        let r = try ResourceHeader(parsing: b, at: 0)
        XCTAssertEqual(r.size, 250)
        XCTAssertEqual(r.flags, 0x02)
        XCTAssertEqual(r.offset, 0x18042A)
        XCTAssertEqual(r.uncompressedSize, 250)
        XCTAssertTrue(r.isMetadata)
    }
    func testRoundTrips() throws {
        let r = ResourceHeader(size: 0x00FF_EEDD_CCBB_AA, flags: 0x06,
                               offset: 0x1234_5678_9ABC, uncompressedSize: 500_000)
        XCTAssertEqual(try ResourceHeader(parsing: r.serialized(), at: 0), r)
    }
    /// The top byte of a 2^56-or-larger size must not leak into the flags byte.
    func testMaximumSizeDoesNotCorruptFlags() throws {
        let r = ResourceHeader(size: 0x00FF_FFFF_FFFF_FF, flags: 0x04, offset: 0, uncompressedSize: 0)
        let back = try ResourceHeader(parsing: r.serialized(), at: 0)
        XCTAssertEqual(back.size, 0x00FF_FFFF_FFFF_FF)
        XCTAssertEqual(back.flags, 0x04)
    }
    func testAbsentResource() {
        XCTAssertTrue(ResourceHeader(size: 0, flags: 0, offset: 0, uncompressedSize: 0).isAbsent)
        XCTAssertFalse(ResourceHeader(size: 1, flags: 0, offset: 0, uncompressedSize: 0).isAbsent)
    }
    func testShortBufferThrows() {
        XCTAssertThrowsError(try ResourceHeader(parsing: [UInt8](repeating: 0, count: 23), at: 0))
    }
}

final class BlobEntryTests: XCTestCase {
    func testRoundTripsEveryField() throws {
        let e = BlobEntry(resource: ResourceHeader(size: 524_288, flags: 0x04,
                                                   offset: 208, uncompressedSize: 500_000),
                          partNumber: 3, refCount: 2, sha1: (0..<20).map { UInt8($0) })
        XCTAssertEqual(e.serialized().count, BlobEntry.byteCount)
        XCTAssertEqual(try BlobEntry(parsing: e.serialized(), at: 0), e)
    }
    func testEntryIsFiftyBytesSoTablesDivideEvenly() {
        XCTAssertEqual(BlobEntry.byteCount, 50)
        XCTAssertEqual(ResourceHeader.byteCount, 24)
    }
    func testTableOfNonMultipleLengthThrows() {
        XCTAssertThrowsError(try WimSplitter.parseBlobTable([UInt8](repeating: 0, count: 51)))
    }
}

final class WimHeaderTests: XCTestCase {
    /// A synthetic header standing in for a real one; `serialized()` is the only writer, so a
    /// round trip pins every offset in the 208-byte layout.
    static func sample() -> WimHeader {
        var b = [UInt8](repeating: 0, count: WimHeader.byteCount)
        b.replaceSubrange(0..<8, with: WimHeader.magic)
        b.replaceSubrange(8..<12, with: UInt32(208).littleEndianBytes)
        b.replaceSubrange(12..<16, with: UInt32(0x0001_0D00).littleEndianBytes)
        b.replaceSubrange(16..<20, with: UInt32(0x0004_0082).littleEndianBytes)
        b.replaceSubrange(20..<24, with: UInt32(32768).littleEndianBytes)
        b.replaceSubrange(24..<40, with: (0..<16).map { UInt8(0xA0 + $0) })
        b.replaceSubrange(40..<42, with: UInt16(1).littleEndianBytes)
        b.replaceSubrange(42..<44, with: UInt16(1).littleEndianBytes)
        b.replaceSubrange(44..<48, with: UInt32(5).littleEndianBytes)
        return try! WimHeader(parsing: b)
    }

    func testParsesTheDocumentedFieldOffsets() throws {
        let h = Self.sample()
        XCTAssertEqual(h.version, 0x0001_0D00)
        XCTAssertEqual(h.flags, 0x0004_0082)
        XCTAssertEqual(h.chunkSize, 32768)
        XCTAssertEqual(h.partNumber, 1)
        XCTAssertEqual(h.totalParts, 1)
        XCTAssertEqual(h.imageCount, 5)
        XCTAssertEqual(h.guid.count, 16)
    }
    func testRoundTrips() throws {
        var h = Self.sample()
        h.blobTable = ResourceHeader(size: 250, flags: 2, offset: 1_573_930, uncompressedSize: 250)
        h.xmlData = ResourceHeader(size: 778, flags: 2, offset: 1_574_180, uncompressedSize: 778)
        h.bootIndex = 2
        XCTAssertEqual(try WimHeader(parsing: h.serialized()), h)
        XCTAssertEqual(h.serialized().count, 208)
    }
    func testRejectsBadMagic() {
        var b = Self.sample().serialized()
        b[0] = 0x00
        XCTAssertThrowsError(try WimHeader(parsing: b))
    }
    func testRejectsUnexpectedHeaderSize() {
        var b = Self.sample().serialized()
        b.replaceSubrange(8..<12, with: UInt32(240).littleEndianBytes)
        XCTAssertThrowsError(try WimHeader(parsing: b))
    }
    func testRejectsTruncatedFile() {
        XCTAssertThrowsError(try WimHeader(parsing: [UInt8](repeating: 0, count: 100)))
    }
}

final class PartPathTests: XCTestCase {
    /// Windows Setup looks for install.swm, install2.swm, install3.swm — not install1.swm.
    func testNamesPartsTheWayWindowsExpects() {
        XCTAssertEqual(WimSplitter.partPath("/u/sources/install.swm", part: 1), "/u/sources/install.swm")
        XCTAssertEqual(WimSplitter.partPath("/u/sources/install.swm", part: 2), "/u/sources/install2.swm")
        XCTAssertEqual(WimSplitter.partPath("/u/sources/install.swm", part: 10), "/u/sources/install10.swm")
    }
    func testHandlesAPathWithoutAnExtension() {
        XCTAssertEqual(WimSplitter.partPath("/u/install", part: 2), "/u/install2")
    }
}

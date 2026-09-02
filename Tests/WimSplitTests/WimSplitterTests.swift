import XCTest
@testable import WimSplit

final class SplitPlanTests: XCTestCase {
    private func blob(_ size: UInt64, metadata: Bool = false, id: UInt8 = 0) -> BlobEntry {
        BlobEntry(resource: ResourceHeader(size: size, flags: metadata ? 0x02 : 0x00,
                                           offset: 0, uncompressedSize: size),
                  partNumber: 1, refCount: 1, sha1: [UInt8](repeating: id, count: 20))
    }

    func testKeepsEverythingInOnePartWhenItFits() throws {
        let s = try WimSplitter(partSizeBytes: 10_000)
        let plan = try s.plan(blobs: [blob(1000), blob(1000)], xmlSize: 100)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].count, 2)
    }

    /// Budget arithmetic: a part costs 208 (header) + 100 (XML) + 650 per blob (600 + a 50-byte
    /// table entry). Two blobs is 1608 and fits 2000; a third would be 2258 and does not.
    func testStartsANewPartWhenTheBudgetIsExceeded() throws {
        let s = try WimSplitter(partSizeBytes: 2_000)
        let plan = try s.plan(blobs: [blob(600), blob(600), blob(600)], xmlSize: 100)
        XCTAssertEqual(plan.map(\.count), [2, 1])
    }

    /// Metadata must be in part 1 — Windows Setup reads the image metadata from the first part.
    func testMetadataAlwaysLandsInPartOne() throws {
        let s = try WimSplitter(partSizeBytes: 1_200)
        // Ordered so a naive in-order fill would push the metadata into a later part.
        let plan = try s.plan(blobs: [blob(500, id: 1), blob(500, id: 2), blob(100, metadata: true, id: 9)],
                              xmlSize: 50)
        XCTAssertTrue(plan[0].contains { $0.resource.isMetadata }, "metadata not in part 1")
        for (i, part) in plan.enumerated() where i > 0 {
            XCTAssertFalse(part.contains { $0.resource.isMetadata }, "metadata leaked into part \(i + 1)")
        }
    }

    func testEveryBlobIsPlacedExactlyOnce() throws {
        let s = try WimSplitter(partSizeBytes: 1_500)
        let blobs = (1...9).map { blob(400, id: UInt8($0)) }
        let plan = try s.plan(blobs: blobs, xmlSize: 50)
        let placed = plan.flatMap { $0 }
        XCTAssertEqual(placed.count, blobs.count)
        XCTAssertEqual(Set(placed.map { $0.sha1 }), Set(blobs.map { $0.sha1 }))
    }

    func testEachPlannedPartStaysWithinTheBudget() throws {
        let size: UInt64 = 3_000, xml: UInt64 = 200
        let s = try WimSplitter(partSizeBytes: size)
        let plan = try s.plan(blobs: (1...20).map { blob(UInt64(100 * $0), id: UInt8($0)) }, xmlSize: xml)
        for (i, part) in plan.enumerated() {
            let total = UInt64(WimHeader.byteCount) + xml
                + part.reduce(UInt64(0)) { $0 + $1.resource.size + UInt64(BlobEntry.byteCount) }
            XCTAssertLessThanOrEqual(total, size, "part \(i + 1) is \(total) bytes, over the \(size) budget")
        }
    }

    /// A blob is indivisible, so an oversized one can never be made to fit — fail loudly rather
    /// than emit a part that FAT32 will reject later.
    func testAnUnsplittableBlobThrows() throws {
        let s = try WimSplitter(partSizeBytes: 1_000)
        XCTAssertThrowsError(try s.plan(blobs: [blob(2_000)], xmlSize: 50)) { e in
            XCTAssertTrue("\(e)".contains("does not fit"), "\(e)")
        }
    }

    func testAbsurdlySmallPartSizeIsRejectedUpFront() {
        XCTAssertThrowsError(try WimSplitter(partSizeBytes: 100))
    }
}

final class SolidWimTests: XCTestCase {
    private func entry(flags: UInt8) -> BlobEntry {
        BlobEntry(resource: ResourceHeader(size: 100, flags: flags, offset: 208, uncompressedSize: 100),
                  partNumber: 1, refCount: 1, sha1: [UInt8](repeating: 0, count: 20))
    }
    private var plainHeader: WimHeader { WimHeaderTests.sample() }

    /// A solid WIM's resources address positions inside shared compression blocks, so copying them
    /// verbatim would produce parts that parse but contain nothing usable.
    func testSolidResourcesAreRefused() {
        let blobs = [entry(flags: 0x06)] + (0..<5).map { _ in entry(flags: ResourceHeader.flagSolid) }
        XCTAssertThrowsError(try WimSplitter.rejectSolid(header: plainHeader, blobs: blobs)) { e in
            XCTAssertTrue("\(e)".contains("solid"), "\(e)")
            XCTAssertTrue("\(e)".contains("5 of 6"), "error should say how many: \(e)")
        }
    }
    func testSolidVersionIsRefusedEvenWithNoSolidResources() {
        var h = plainHeader
        h.version = WimHeader.versionSolid
        XCTAssertThrowsError(try WimSplitter.rejectSolid(header: h, blobs: [entry(flags: 0x06)]))
    }
    func testOrdinaryWimIsAccepted() {
        let blobs = [entry(flags: 0x06), entry(flags: 0x04), entry(flags: 0x00)]
        XCTAssertNoThrow(try WimSplitter.rejectSolid(header: plainHeader, blobs: blobs))
    }
    func testSolidFlagIsBitFour() {
        XCTAssertEqual(ResourceHeader.flagSolid, 0x10)
        XCTAssertTrue(ResourceHeader(size: 0, flags: 0x10, offset: 0, uncompressedSize: 0).isSolid)
        XCTAssertFalse(ResourceHeader(size: 0, flags: 0x06, offset: 0, uncompressedSize: 0).isSolid)
    }
}

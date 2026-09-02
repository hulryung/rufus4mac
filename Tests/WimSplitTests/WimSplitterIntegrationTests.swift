import XCTest
@testable import WimSplit

/// End-to-end checks against wimlib. wimlib is used only as an *oracle* — to build source WIMs and
/// to read back what we produce. None of its source informed this implementation; the format was
/// derived from the specification and from parsing real WIMs.
final class WimSplitterIntegrationTests: XCTestCase {
    private var imagex: String {
        get throws {
            for p in ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
            throw XCTSkip("wimlib-imagex not installed")
        }
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
    }

    /// A capture directory with distinct files plus a duplicate, so the WIM has a shared blob whose
    /// refCount is 2 — a field we must carry through untouched.
    private func makeSource(in dir: URL, compression: String) throws -> URL {
        let fm = FileManager.default
        let src = dir.appendingPathComponent("src")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for i in 1...5 {
            // Deterministic but incompressible-ish, so LZX still leaves sizeable blobs.
            var g = SystemRandomNumberGenerator()
            let bytes = (0..<(300 * 1024)).map { _ in UInt8.random(in: 0...255, using: &g) }
            try Data(bytes).write(to: src.appendingPathComponent("f\(i).bin"))
        }
        try Data("hello wim".utf8).write(to: src.appendingPathComponent("sub/a.txt"))
        try fm.copyItem(at: src.appendingPathComponent("f1.bin"),
                        to: src.appendingPathComponent("sub/dup.bin"))
        let wim = dir.appendingPathComponent("src.wim")
        let (st, out) = try run(try imagex, ["capture", src.path, wim.path, "--compress=\(compression)"])
        XCTAssertEqual(st, 0, out)
        return wim
    }

    private func parse(_ url: URL) throws -> (WimHeader, [BlobEntry], [UInt8]) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let h = try WimHeader(parsing: try WimSplitter.read(fh, at: 0, count: WimHeader.byteCount))
        let table = try WimSplitter.parseBlobTable(
            try WimSplitter.read(fh, at: h.blobTable.offset, count: Int(h.blobTable.size)))
        let xml = try WimSplitter.read(fh, at: h.xmlData.offset, count: Int(h.xmlData.size))
        return (h, table, xml)
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wimsplit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - structure

    func testSplitPartsHaveTheStructureWimlibProduces() throws {
        let imagex = try imagex
        _ = imagex
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wim = try makeSource(in: dir, compression: "none")
        let (srcHeader, srcBlobs, srcXML) = try parse(wim)

        let parts = try WimSplitter(partSizeBytes: 600 * 1024)
            .split(wimPath: wim.path, firstPartPath: dir.appendingPathComponent("out.swm").path)
        XCTAssertGreaterThan(parts.count, 1, "expected a multi-part split")

        var guids = Set<[UInt8]>()
        var seen: [[UInt8]] = []
        for (i, path) in parts.enumerated() {
            let (h, blobs, xml) = try parse(URL(fileURLWithPath: path))
            XCTAssertNotEqual(h.flags & WimHeader.flagSpanned, 0, "part \(i + 1) is missing SPANNED")
            XCTAssertEqual(h.partNumber, UInt16(i + 1))
            XCTAssertEqual(h.totalParts, UInt16(parts.count))
            XCTAssertEqual(h.imageCount, srcHeader.imageCount)
            XCTAssertEqual(h.chunkSize, srcHeader.chunkSize)
            XCTAssertEqual(xml, srcXML, "part \(i + 1) XML differs from the source")
            XCTAssertTrue(h.integrityTable.isAbsent)
            guids.insert(h.guid)
            for b in blobs {
                XCTAssertEqual(b.partNumber, UInt16(i + 1), "blob tagged with the wrong part")
                seen.append(b.sha1)
            }
            if i > 0 {
                XCTAssertFalse(blobs.contains { $0.resource.isMetadata },
                               "metadata leaked into part \(i + 1)")
            }
        }
        XCTAssertEqual(guids.count, 1, "parts must share one GUID")
        XCTAssertNotEqual(guids.first, srcHeader.guid, "the set needs a GUID of its own")
        XCTAssertEqual(Set(seen), Set(srcBlobs.map(\.sha1)), "blob set changed")
        XCTAssertEqual(seen.count, srcBlobs.count, "a blob was duplicated or dropped")
    }

    func testRefCountsAndBlobBytesSurvive() throws {
        _ = try imagex
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wim = try makeSource(in: dir, compression: "none")
        let (_, srcBlobs, _) = try parse(wim)
        XCTAssertTrue(srcBlobs.contains { $0.refCount == 2 }, "test needs a shared blob")

        let parts = try WimSplitter(partSizeBytes: 600 * 1024)
            .split(wimPath: wim.path, firstPartPath: dir.appendingPathComponent("out.swm").path)

        let srcData = try Data(contentsOf: wim)
        var byHash: [[UInt8]: BlobEntry] = [:]
        for b in srcBlobs { byHash[b.sha1] = b }
        for path in parts {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let (_, blobs, _) = try parse(URL(fileURLWithPath: path))
            for b in blobs {
                guard let orig = byHash[b.sha1] else { return XCTFail("unknown blob in output") }
                XCTAssertEqual(b.refCount, orig.refCount, "refCount changed")
                XCTAssertEqual(b.resource.uncompressedSize, orig.resource.uncompressedSize)
                XCTAssertEqual(b.resource.flags, orig.resource.flags)
                let a = data[Int(b.resource.offset)..<Int(b.resource.offset + b.resource.size)]
                let e = srcData[Int(orig.resource.offset)..<Int(orig.resource.offset + orig.resource.size)]
                XCTAssertEqual(Array(a), Array(e), "blob bytes were altered in transit")
            }
        }
    }

    // MARK: - wimlib accepts what we write

    /// The strongest check short of booting Windows: wimlib restores the files from *our* split set
    /// and every one comes back byte-identical to what went in.
    func testWimlibCanVerifyAndRestoreOurSplit() throws {
        for compression in ["none", "LZX"] {
            let imagex = try imagex
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let wim = try makeSource(in: dir, compression: compression)
            let first = dir.appendingPathComponent("out.swm")
            let parts = try WimSplitter(partSizeBytes: 700 * 1024)
                .split(wimPath: wim.path, firstPartPath: first.path)
            XCTAssertGreaterThan(parts.count, 1, "\(compression): expected multiple parts")

            let refs = dir.appendingPathComponent("out*.swm").path
            let (vst, vout) = try run(imagex, ["verify", first.path, "--ref=\(refs)"])
            XCTAssertEqual(vst, 0, "\(compression): wimlib verify rejected our split:\n\(vout)")

            let restored = dir.appendingPathComponent("restored")
            let (ast, aout) = try run(imagex, ["apply", first.path, "1", restored.path, "--ref=\(refs)"])
            XCTAssertEqual(ast, 0, "\(compression): wimlib apply failed:\n\(aout)")

            let fm = FileManager.default
            let original = dir.appendingPathComponent("src")
            var compared = 0
            for case let rel as String in fm.enumerator(atPath: original.path)! {
                let a = original.appendingPathComponent(rel), b = restored.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: a.path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                XCTAssertTrue(fm.fileExists(atPath: b.path), "\(compression): \(rel) missing after restore")
                XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b),
                               "\(compression): \(rel) came back different")
                compared += 1
            }
            XCTAssertEqual(compared, 7, "\(compression): expected to compare 7 files")
        }
    }

    func testRefusesToSplitAnAlreadySplitWim() throws {
        _ = try imagex
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wim = try makeSource(in: dir, compression: "none")
        let first = dir.appendingPathComponent("out.swm")
        _ = try WimSplitter(partSizeBytes: 600 * 1024).split(wimPath: wim.path, firstPartPath: first.path)
        XCTAssertThrowsError(try WimSplitter(partSizeBytes: 600 * 1024)
            .split(wimPath: first.path, firstPartPath: dir.appendingPathComponent("again.swm").path)) { e in
            XCTAssertTrue("\(e)".contains("already split"), "\(e)")
        }
    }

    func testProgressRunsFromZeroToOne() throws {
        _ = try imagex
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wim = try makeSource(in: dir, compression: "none")
        var seen: [Double] = []
        _ = try WimSplitter(partSizeBytes: 600 * 1024)
            .split(wimPath: wim.path, firstPartPath: dir.appendingPathComponent("out.swm").path,
                   progress: { seen.append($0) })
        XCTAssertEqual(seen.first, 0)
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(seen, seen.sorted(), "progress went backwards")
    }
}

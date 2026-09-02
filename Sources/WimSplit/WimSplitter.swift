// WimSplit — MIT licensed. See LICENSE in this directory.

import Foundation

/// Splits a WIM into `.swm` parts small enough for FAT32.
///
/// Blob bytes are copied verbatim — already compressed in the source, and never decompressed here —
/// so only three small structures are rewritten per part: the header, the blob table and the XML.
/// All three are stored uncompressed even in an LZX/XPRESS WIM, which is what lets this work with
/// no compression codec at all.
public struct WimSplitter: Sendable {
    /// Target size for each part, in bytes.
    public let partSize: UInt64
    /// Bytes moved per read/write while copying blobs.
    let copyBufferSize: Int

    public init(partSizeBytes: UInt64, copyBufferSize: Int = 4 << 20) throws {
        let floor = UInt64(WimHeader.byteCount + BlobEntry.byteCount)
        guard partSizeBytes > floor else {
            throw WimError("part size \(partSizeBytes) is too small to hold even a WIM header")
        }
        self.partSize = partSizeBytes
        self.copyBufferSize = copyBufferSize
    }

    /// Split `wimPath`, writing part 1 to `firstPartPath` and parts 2…n alongside it
    /// (`install.swm` → `install2.swm`, `install3.swm`, …). Returns the paths written, in order.
    ///
    /// `progress` receives 0...1 by bytes copied.
    @discardableResult
    public func split(wimPath: String, firstPartPath: String,
                      progress: (Double) -> Void = { _ in }) throws -> [String] {
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: wimPath))
        defer { try? src.close() }

        let header = try WimHeader(parsing: try Self.read(src, at: 0, count: WimHeader.byteCount))
        guard header.totalParts == 1 else {
            throw WimError("\(wimPath) is already split (part \(header.partNumber) of \(header.totalParts))")
        }
        guard !header.blobTable.isAbsent else { throw WimError("\(wimPath) has no blob table") }

        let blobs = try Self.parseBlobTable(try Self.read(src, at: header.blobTable.offset,
                                                          count: Int(header.blobTable.size)))
        try Self.rejectSolid(header: header, blobs: blobs)
        let xml = try Self.read(src, at: header.xmlData.offset, count: Int(header.xmlData.size))
        let plan = try plan(blobs: blobs, xmlSize: UInt64(xml.count))

        // One GUID for the whole set — that is what marks the parts as belonging together, and it
        // must differ from the source's so a part is never mistaken for the original.
        let guid = Self.newGUID()
        let totalBytes = blobs.reduce(UInt64(0)) { $0 + $1.resource.size }
        var copied: UInt64 = 0
        progress(0)

        var written: [String] = []
        for (i, partBlobs) in plan.enumerated() {
            let path = Self.partPath(firstPartPath, part: i + 1)
            try writePart(source: src, sourceHeader: header, blobs: partBlobs, xml: xml,
                          guid: guid, partNumber: UInt16(i + 1), totalParts: UInt16(plan.count),
                          to: path,
                          onCopied: { n in
                              copied += n
                              progress(totalBytes == 0 ? 1 : min(Double(copied) / Double(totalBytes), 1))
                          })
            written.append(path)
        }
        progress(1)
        return written
    }

    // MARK: - planning

    /// Assign blobs to parts. Metadata goes in part 1; the rest fill parts greedily in table order.
    func plan(blobs: [BlobEntry], xmlSize: UInt64) throws -> [[BlobEntry]] {
        let fixedOverhead = UInt64(WimHeader.byteCount) + xmlSize
        var parts: [[BlobEntry]] = [[]]
        var used = fixedOverhead

        func cost(_ b: BlobEntry) -> UInt64 { b.resource.size + UInt64(BlobEntry.byteCount) }
        // A blob is indivisible: if one cannot fit a part on its own, no arrangement can help, and
        // silently emitting an oversized part would just fail later on FAT32.
        for b in blobs where fixedOverhead + cost(b) > partSize {
            throw WimError("""
                a single \(b.resource.size)-byte resource does not fit a \(partSize)-byte part \
                (needs \(fixedOverhead + cost(b)) with header and XML)
                """)
        }

        for b in blobs where b.resource.isMetadata {
            parts[0].append(b)
            used += cost(b)
        }
        for b in blobs where !b.resource.isMetadata {
            if used + cost(b) > partSize {
                parts.append([])
                used = fixedOverhead
            }
            parts[parts.count - 1].append(b)
            used += cost(b)
        }
        return parts
    }

    // MARK: - writing

    private func writePart(source: FileHandle, sourceHeader: WimHeader, blobs: [BlobEntry],
                           xml: [UInt8], guid: [UInt8], partNumber: UInt16, totalParts: UInt16,
                           to path: String, onCopied: (UInt64) -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw WimError("could not create \(path)")
        }
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? out.close() }

        // Layout is [header][blobs][blob table][XML] with no padding, so the header is written last,
        // once the table and XML offsets are known. Reserve its space first.
        try out.write(contentsOf: [UInt8](repeating: 0, count: WimHeader.byteCount))
        var offset = UInt64(WimHeader.byteCount)

        var placed: [BlobEntry] = []
        var relocated: [UInt64: ResourceHeader] = [:]   // original offset -> its new resource header
        for b in blobs {
            try copy(from: source, at: b.resource.offset, count: b.resource.size, to: out,
                     onCopied: onCopied)
            var moved = b
            moved.resource.offset = offset
            moved.partNumber = partNumber
            placed.append(moved)
            relocated[b.resource.offset] = moved.resource
            offset += b.resource.size
        }

        let tableOffset = offset
        var table: [UInt8] = []
        table.reserveCapacity(placed.count * BlobEntry.byteCount)
        for b in placed { table += b.serialized() }
        try out.write(contentsOf: table)
        offset += UInt64(table.count)

        let xmlOffset = offset
        try out.write(contentsOf: xml)

        var h = sourceHeader
        h.flags |= WimHeader.flagSpanned
        h.guid = guid
        h.partNumber = partNumber
        h.totalParts = totalParts
        h.blobTable = ResourceHeader(size: UInt64(table.count), flags: sourceHeader.blobTable.flags,
                                     offset: tableOffset, uncompressedSize: UInt64(table.count))
        h.xmlData = ResourceHeader(size: UInt64(xml.count), flags: sourceHeader.xmlData.flags,
                                   offset: xmlOffset, uncompressedSize: UInt64(xml.count))
        // Boot metadata is one of the metadata resources, so it lands in part 1; every other part
        // must not claim to have it. An integrity table is not carried over.
        h.bootMetadata = sourceHeader.bootMetadata.isAbsent
            ? sourceHeader.bootMetadata
            : (relocated[sourceHeader.bootMetadata.offset] ?? ResourceHeader(size: 0, flags: 0, offset: 0, uncompressedSize: 0))
        h.bootIndex = h.bootMetadata.isAbsent ? 0 : sourceHeader.bootIndex
        h.integrityTable = ResourceHeader(size: 0, flags: 0, offset: 0, uncompressedSize: 0)

        try out.seek(toOffset: 0)
        try out.write(contentsOf: h.serialized())
    }

    private func copy(from src: FileHandle, at offset: UInt64, count: UInt64, to dst: FileHandle,
                      onCopied: (UInt64) -> Void) throws {
        try src.seek(toOffset: offset)
        var remaining = count
        while remaining > 0 {
            let want = Int(min(remaining, UInt64(copyBufferSize)))
            guard let chunk = try src.read(upToCount: want), !chunk.isEmpty else {
                throw WimError("unexpected end of WIM while reading \(count) bytes at \(offset)")
            }
            try dst.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            onCopied(UInt64(chunk.count))
        }
    }

    // MARK: - helpers

    /// Refuse a solid (ESD-style) WIM.
    ///
    /// Copying blobs verbatim is what lets this work without a decompressor, and that holds only
    /// while each blob is its own byte range of the file. In a solid WIM — version 0x0E00, as
    /// produced by converting an ESD, e.g. by `esd2iso` — resources are packed together into shared
    /// LZMS blocks, and a resource's offset addresses a position *inside* a block. Splitting on
    /// those boundaries would need full decompression and repacking, so refuse plainly instead of
    /// emitting parts that look right and are not.
    static func rejectSolid(header: WimHeader, blobs: [BlobEntry]) throws {
        let solid = blobs.filter(\.resource.isSolid).count
        guard solid == 0 else {
            throw WimError("""
                this is a solid (ESD-style) WIM: \(solid) of \(blobs.count) resources are packed \
                into shared compression blocks, which cannot be split without decompressing them. \
                Solid WIMs are not supported.
                """)
        }
        guard header.version != WimHeader.versionSolid else {
            throw WimError("unsupported WIM version \(header.version) (solid/ESD format)")
        }
    }

    static func parseBlobTable(_ bytes: [UInt8]) throws -> [BlobEntry] {
        guard bytes.count % BlobEntry.byteCount == 0 else {
            throw WimError("blob table of \(bytes.count) bytes is not a whole number of \(BlobEntry.byteCount)-byte entries")
        }
        return try (0..<(bytes.count / BlobEntry.byteCount)).map {
            try BlobEntry(parsing: bytes, at: $0 * BlobEntry.byteCount)
        }
    }

    /// `install.swm` → part 2 is `install2.swm`, matching what Windows Setup expects to find.
    static func partPath(_ firstPartPath: String, part: Int) -> String {
        guard part > 1 else { return firstPartPath }
        let url = URL(fileURLWithPath: firstPartPath)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().path
        return ext.isEmpty ? "\(stem)\(part)" : "\(stem)\(part).\(ext)"
    }

    static func newGUID() -> [UInt8] {
        let u = UUID().uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    static func read(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try fh.seek(toOffset: offset)
        guard let d = try fh.read(upToCount: count), d.count == count else {
            throw WimError("could not read \(count) bytes at offset \(offset)")
        }
        return Array(d)
    }
}

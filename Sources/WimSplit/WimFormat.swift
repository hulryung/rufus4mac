// WimSplit — MIT licensed. See LICENSE in this directory.
//
// On-disk structures of the Windows Imaging (WIM) format, limited to what splitting needs.
// Every field here was verified by parsing real WIMs; see README.md in this directory.

import Foundation

public struct WimError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where a resource lives in the file and how big it is. 24 bytes:
/// `size` (7 bytes LE) · `flags` (1 byte) · `offset` (u64) · `uncompressedSize` (u64).
///
/// The 7-byte size is not an alignment quirk — the eighth byte is the flags field, so a resource is
/// capped at 2^56 - 1 bytes.
public struct ResourceHeader: Equatable, Sendable {
    public static let byteCount = 24
    /// Resource is metadata for an image. Metadata must land in part 1 of a split.
    public static let flagMetadata: UInt8 = 0x02
    public static let flagCompressed: UInt8 = 0x04
    /// Resource lives *inside* a solid block shared with other resources, so its offset and size
    /// address a position within that block rather than a byte range of the file.
    public static let flagSolid: UInt8 = 0x10

    public var size: UInt64
    public var flags: UInt8
    public var offset: UInt64
    public var uncompressedSize: UInt64

    public init(size: UInt64, flags: UInt8, offset: UInt64, uncompressedSize: UInt64) {
        self.size = size; self.flags = flags
        self.offset = offset; self.uncompressedSize = uncompressedSize
    }

    public var isMetadata: Bool { flags & Self.flagMetadata != 0 }
    public var isSolid: Bool { flags & Self.flagSolid != 0 }
    /// A resource header of all zeros means "absent" (e.g. a WIM with no boot metadata).
    public var isAbsent: Bool { size == 0 && offset == 0 && uncompressedSize == 0 }

    public init(parsing b: [UInt8], at i: Int) throws {
        guard b.count >= i + Self.byteCount else { throw WimError("resource header runs past end of data") }
        var size: UInt64 = 0
        for k in 0..<7 { size |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        self.size = size
        self.flags = b[i + 7]
        self.offset = UInt64(littleEndianBytes: b, at: i + 8)
        self.uncompressedSize = UInt64(littleEndianBytes: b, at: i + 16)
    }

    public func serialized() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.byteCount)
        for k in 0..<7 { out[k] = UInt8((size >> (8 * UInt64(k))) & 0xFF) }
        out[7] = flags
        out.replaceSubrange(8..<16, with: offset.littleEndianBytes)
        out.replaceSubrange(16..<24, with: uncompressedSize.littleEndianBytes)
        return out
    }
}

/// One entry of the blob table: a resource plus which part holds it, how many files reference it,
/// and the SHA-1 of its *uncompressed* contents. 50 bytes.
public struct BlobEntry: Equatable, Sendable {
    public static let byteCount = 50

    public var resource: ResourceHeader
    public var partNumber: UInt16
    public var refCount: UInt32
    public var sha1: [UInt8]        // 20 bytes, carried through untouched

    public init(resource: ResourceHeader, partNumber: UInt16, refCount: UInt32, sha1: [UInt8]) {
        self.resource = resource; self.partNumber = partNumber
        self.refCount = refCount; self.sha1 = sha1
    }

    public init(parsing b: [UInt8], at i: Int) throws {
        guard b.count >= i + Self.byteCount else { throw WimError("blob entry runs past end of table") }
        self.resource = try ResourceHeader(parsing: b, at: i)
        self.partNumber = UInt16(littleEndianBytes: b, at: i + 24)
        self.refCount = UInt32(littleEndianBytes: b, at: i + 26)
        self.sha1 = Array(b[(i + 30)..<(i + 50)])
    }

    public func serialized() -> [UInt8] {
        var out = resource.serialized()
        out += partNumber.littleEndianBytes
        out += refCount.littleEndianBytes
        out += sha1
        return out
    }
}

/// The 208-byte WIM header.
public struct WimHeader: Equatable, Sendable {
    public static let byteCount = 208
    public static let magic: [UInt8] = Array("MSWIM\0\0\0".utf8)
    /// The file is one part of a split (spanned) WIM.
    public static let flagSpanned: UInt32 = 0x0000_0008
    /// Version stamp of a solid (ESD-style) WIM. Retail install.wim files are 0x0001_0D00.
    public static let versionSolid: UInt32 = 0x0000_0E00

    public var version: UInt32
    public var flags: UInt32
    public var chunkSize: UInt32
    public var guid: [UInt8]             // 16 bytes; shared by every part of a split set
    public var partNumber: UInt16
    public var totalParts: UInt16
    public var imageCount: UInt32
    public var blobTable: ResourceHeader
    public var xmlData: ResourceHeader
    public var bootMetadata: ResourceHeader
    public var bootIndex: UInt32
    public var integrityTable: ResourceHeader

    public init(parsing b: [UInt8]) throws {
        guard b.count >= Self.byteCount else { throw WimError("file is too small to be a WIM") }
        guard Array(b[0..<8]) == Self.magic else { throw WimError("not a WIM file (bad magic)") }
        let cbSize = UInt32(littleEndianBytes: b, at: 8)
        guard cbSize == UInt32(Self.byteCount) else {
            throw WimError("unexpected WIM header size \(cbSize), expected \(Self.byteCount)")
        }
        self.version = UInt32(littleEndianBytes: b, at: 12)
        self.flags = UInt32(littleEndianBytes: b, at: 16)
        self.chunkSize = UInt32(littleEndianBytes: b, at: 20)
        self.guid = Array(b[24..<40])
        self.partNumber = UInt16(littleEndianBytes: b, at: 40)
        self.totalParts = UInt16(littleEndianBytes: b, at: 42)
        self.imageCount = UInt32(littleEndianBytes: b, at: 44)
        self.blobTable = try ResourceHeader(parsing: b, at: 48)
        self.xmlData = try ResourceHeader(parsing: b, at: 72)
        self.bootMetadata = try ResourceHeader(parsing: b, at: 96)
        self.bootIndex = UInt32(littleEndianBytes: b, at: 120)
        self.integrityTable = try ResourceHeader(parsing: b, at: 124)
    }

    public func serialized() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.byteCount)
        out.replaceSubrange(0..<8, with: Self.magic)
        out.replaceSubrange(8..<12, with: UInt32(Self.byteCount).littleEndianBytes)
        out.replaceSubrange(12..<16, with: version.littleEndianBytes)
        out.replaceSubrange(16..<20, with: flags.littleEndianBytes)
        out.replaceSubrange(20..<24, with: chunkSize.littleEndianBytes)
        out.replaceSubrange(24..<40, with: guid)
        out.replaceSubrange(40..<42, with: partNumber.littleEndianBytes)
        out.replaceSubrange(42..<44, with: totalParts.littleEndianBytes)
        out.replaceSubrange(44..<48, with: imageCount.littleEndianBytes)
        out.replaceSubrange(48..<72, with: blobTable.serialized())
        out.replaceSubrange(72..<96, with: xmlData.serialized())
        out.replaceSubrange(96..<120, with: bootMetadata.serialized())
        out.replaceSubrange(120..<124, with: bootIndex.littleEndianBytes)
        out.replaceSubrange(124..<148, with: integrityTable.serialized())
        // bytes 148..<208 are unused and stay zero
        return out
    }
}

// MARK: - little-endian helpers

extension FixedWidthInteger {
    init(littleEndianBytes b: [UInt8], at i: Int) {
        var v: Self = 0
        for k in 0..<(Self.bitWidth / 8) { v |= Self(b[i + k]) << (8 * k) }
        self = v
    }
    var littleEndianBytes: [UInt8] {
        (0..<(Self.bitWidth / 8)).map { UInt8(truncatingIfNeeded: self >> (8 * $0)) }
    }
}

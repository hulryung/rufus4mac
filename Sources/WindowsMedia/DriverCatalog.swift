import Foundation
import CryptoKit

/// A driver package that can be fetched straight from the vendor, pinned to a version and a hash.
public struct DriverPackage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let vendor: String
    public let version: String
    public let url: URL
    /// Lowercase hex SHA-256 as published by the vendor. Downloads that do not match are discarded.
    public let sha256: String
    public let sizeBytes: UInt64
    /// Human-readable list of the adapters this package drives.
    public let covers: String
    public let sourcePage: URL?

    public var displayName: String { "\(vendor) \(name) \(version)" }
}

public struct CatalogModel: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    /// The numbers printed on the machine, so a user can match their sticker.
    public let modelNumbers: String
    public let packageIDs: [String]
    public var id: String { name }
}

/// The models rufus4mac can fetch drivers for without being told a URL.
///
/// The catalogue is deliberately chipset-shaped rather than model-shaped. Samsung builds its
/// download links dynamically and has no stable per-model URL, but the silicon vendors do: one
/// Intel package covers every Intel Wi-Fi adapter from Wireless-AC 9560 through Wi-Fi 7, which is
/// every Intel-based Galaxy Book. So the model list is a convenience for finding your machine, not
/// a mapping that decides the file — an incomplete list cannot produce the wrong driver.
///
/// Galaxy Book Go and other Snapdragon models are **not** covered: their Wi-Fi is Qualcomm.
public struct DriverCatalog: Codable, Sendable {
    /// Bumped when the file format changes incompatibly. A catalogue from the future is refused
    /// rather than half-read.
    public static let currentFormatVersion = 1

    public var formatVersion: Int?
    /// What this catalogue is, shown so a user can tell one source from another.
    public var name: String?
    public var maintainer: String?
    public var updatedAt: String?
    /// Where to re-fetch this catalogue from. Present only in catalogues meant to be kept current.
    public var updateURL: URL?
    public let models: [CatalogModel]
    public let packages: [DriverPackage]

    public var displayName: String { name ?? "Untitled catalog" }

    public static func bundled() throws -> DriverCatalog {
        guard let url = Bundle.module.url(forResource: "driver-catalog", withExtension: "json") else {
            throw WimToolError(message: "driver catalogue is missing from the app bundle")
        }
        return try decode(Data(contentsOf: url), source: "bundled catalog")
    }

    /// Decode *and* validate. Everything that reaches the app goes through here, including
    /// catalogues written by other people, so validation is not optional.
    public static func decode(_ data: Data, source: String) throws -> DriverCatalog {
        let catalog: DriverCatalog
        do {
            catalog = try JSONDecoder().decode(DriverCatalog.self, from: data)
        } catch {
            throw WimToolError(message: "\(source) is not a valid driver catalog: \(error.localizedDescription)")
        }
        try catalog.validate(source: source)
        return catalog
    }

    /// Refuse anything that could not be checked before it is run.
    ///
    /// A catalogue entry points at an executable that will be run on a freshly installed machine.
    /// Shared catalogues make that someone else's file, so every entry must carry what makes it
    /// verifiable — an https URL and the publisher's SHA-256 — or it does not load at all. A
    /// catalogue that cannot be checked is worse than no catalogue.
    public func validate(source: String) throws {
        func fail(_ why: String) throws -> Never {
            throw WimToolError(message: "\(source): \(why)")
        }
        let version = formatVersion ?? 1
        guard version <= Self.currentFormatVersion else {
            try fail("needs catalog format \(version), this version of rufus4mac understands \(Self.currentFormatVersion)")
        }
        guard !packages.isEmpty else { try fail("contains no packages") }

        var seen = Set<String>()
        for p in packages {
            guard !p.id.isEmpty else { try fail("a package has no id") }
            guard seen.insert(p.id).inserted else { try fail("duplicate package id \(p.id)") }
            guard p.url.scheme?.lowercased() == "https" else {
                try fail("package \(p.id) must be fetched over https, not \(p.url.scheme ?? "nothing")")
            }
            let hash = p.sha256.lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                try fail("package \(p.id) has no usable SHA-256 — it could not be verified before being run")
            }
            guard p.sizeBytes > 0 else { try fail("package \(p.id) has no size") }
            guard !p.name.isEmpty, !p.version.isEmpty else { try fail("package \(p.id) is unnamed") }
        }

        guard !models.isEmpty else { try fail("lists no devices") }
        var modelNames = Set<String>()
        for m in models {
            guard modelNames.insert(m.name).inserted else { try fail("duplicate device name \(m.name)") }
            guard !m.name.isEmpty else { try fail("a device has no name") }
            guard !m.packageIDs.isEmpty else { try fail("device \(m.name) lists no packages") }
            for id in m.packageIDs where !seen.contains(id) {
                try fail("device \(m.name) refers to unknown package \(id)")
            }
        }
    }

    public func packages(for model: CatalogModel) -> [DriverPackage] {
        model.packageIDs.compactMap { id in packages.first { $0.id == id } }
    }
}

public enum DriverDownload {
    /// Streaming SHA-256, so a 50 MB installer is never held in memory twice.
    public static func sha256(ofFileAt path: String) throws -> String {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reject a download whose hash does not match what the vendor published. A driver installer is
    /// an executable that will be run on a fresh Windows machine, so a silent mismatch is the one
    /// outcome worth failing loudly over.
    public static func verify(fileAt path: String, matches expected: String) throws {
        let got = try sha256(ofFileAt: path)
        guard got.caseInsensitiveCompare(expected) == .orderedSame else {
            throw WimToolError(message: """
                Checksum mismatch — the download does not match the vendor's published SHA-256 and \
                was discarded. Expected \(expected.lowercased()), got \(got).
                """)
        }
    }
}

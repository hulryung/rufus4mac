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
    public let models: [CatalogModel]
    public let packages: [DriverPackage]

    public static func bundled() throws -> DriverCatalog {
        guard let url = Bundle.module.url(forResource: "driver-catalog", withExtension: "json") else {
            throw WimToolError(message: "driver catalogue is missing from the app bundle")
        }
        return try JSONDecoder().decode(DriverCatalog.self, from: Data(contentsOf: url))
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

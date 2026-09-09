import XCTest
import CryptoKit
@testable import WindowsMedia

final class DriverCatalogTests: XCTestCase {
    private func catalog() throws -> DriverCatalog { try DriverCatalog.bundled() }

    func testBundledCatalogLoads() throws {
        let c = try catalog()
        XCTAssertFalse(c.models.isEmpty)
        XCTAssertFalse(c.packages.isEmpty)
    }

    /// A model entry pointing at a package id that does not exist would silently offer nothing.
    func testEveryModelResolvesToAtLeastOnePackage() throws {
        let c = try catalog()
        for m in c.models {
            XCTAssertFalse(c.packages(for: m).isEmpty, "\(m.name) resolves to no package")
        }
    }

    func testPackageIDsAreUnique() throws {
        let ids = try catalog().packages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Every pinned entry must carry what makes it verifiable: an https URL, a 64-hex SHA-256 and a
    /// size. Without the hash the download cannot be checked, and it is an executable.
    func testEveryPackageIsPinnedAndVerifiable() throws {
        for p in try catalog().packages {
            XCTAssertEqual(p.url.scheme, "https", "\(p.id) must be fetched over https")
            XCTAssertEqual(p.sha256.count, 64, "\(p.id) sha256 is not 64 hex characters")
            XCTAssertTrue(p.sha256.allSatisfy { $0.isHexDigit }, "\(p.id) sha256 is not hex")
            XCTAssertEqual(p.sha256, p.sha256.lowercased(), "\(p.id) sha256 should be lowercase")
            XCTAssertGreaterThan(p.sizeBytes, 0, "\(p.id) has no size")
            XCTAssertFalse(p.version.isEmpty)
            XCTAssertFalse(p.covers.isEmpty, "\(p.id) should say which adapters it drives")
        }
    }

    /// The catalogue's whole premise: the model does not decide the file, the chipset does. If two
    /// Galaxy Book entries ever resolved to different packages this note would be wrong.
    func testEveryGalaxyBookModelUsesTheSameIntelPackage() throws {
        let c = try catalog()
        let resolved = Set(c.models.flatMap { c.packages(for: $0).map(\.id) })
        XCTAssertEqual(resolved, ["intel-wifi"])
    }

    func testCatalogDoesNotClaimSnapdragonModels() throws {
        // Galaxy Book Go and friends use Qualcomm Wi-Fi, which the Intel package does not drive.
        for m in try catalog().models {
            XCTAssertFalse(m.name.localizedCaseInsensitiveContains("Go"),
                           "\(m.name) is Snapdragon and must not map to the Intel package")
        }
    }
}

final class DriverDownloadVerificationTests: XCTestCase {
    private func tempFile(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try data.write(to: url)
        return url.path
    }

    func testSha256MatchesCryptoKit() throws {
        let payload = Data((0..<(9 << 20)).map { UInt8($0 % 251) })   // spans several read chunks
        let path = try tempFile(payload)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try DriverDownload.sha256(ofFileAt: path), expected)
    }

    func testVerifyAcceptsAMatchAndIsCaseInsensitive() throws {
        let path = try tempFile(Data("hello".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hash = try DriverDownload.sha256(ofFileAt: path)
        XCTAssertNoThrow(try DriverDownload.verify(fileAt: path, matches: hash))
        XCTAssertNoThrow(try DriverDownload.verify(fileAt: path, matches: hash.uppercased()))
    }

    func testVerifyRejectsAMismatch() throws {
        let path = try tempFile(Data("hello".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try DriverDownload.verify(fileAt: path,
                                                       matches: String(repeating: "0", count: 64))) {
            XCTAssertTrue("\($0)".contains("Checksum mismatch"), "\($0)")
        }
    }
}

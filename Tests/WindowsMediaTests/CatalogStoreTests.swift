import XCTest
@testable import WindowsMedia

/// A shared catalog is someone else's file pointing at an executable that will be run on a freshly
/// installed machine. These tests pin the rule that makes that safe: an entry that cannot be
/// verified before it runs does not load at all.
final class CatalogValidationTests: XCTestCase {
    private func json(packages: String, models: String, extra: String = "") -> Data {
        Data("""
        { "formatVersion": 1, "name": "Test" \(extra),
          "packages": [\(packages)], "models": [\(models)] }
        """.utf8)
    }
    private let goodPackage = """
        { "id": "p1", "name": "Wi-Fi", "vendor": "Intel", "version": "1.0",
          "url": "https://example.com/a.exe",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "sizeBytes": 100, "covers": "everything" }
        """
    private let goodModel = """
        { "name": "Some Laptop", "modelNumbers": "X1", "packageIDs": ["p1"] }
        """

    func testAValidCatalogLoads() throws {
        let c = try DriverCatalog.decode(json(packages: goodPackage, models: goodModel), source: "t")
        XCTAssertEqual(c.name, "Test")
        XCTAssertEqual(c.models.count, 1)
    }

    func testHttpIsRefused() {
        let p = goodPackage.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertThrowsError(try DriverCatalog.decode(json(packages: p, models: goodModel), source: "t")) {
            XCTAssertTrue("\($0)".contains("https"), "\($0)")
        }
    }

    func testAPackageWithoutAUsableHashIsRefused() {
        for bad in ["\"\"", "\"abc\"", "\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\""] {
            let p = goodPackage.replacingOccurrences(
                of: "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"", with: bad)
            XCTAssertThrowsError(try DriverCatalog.decode(json(packages: p, models: goodModel), source: "t"),
                                 "hash \(bad) should not be accepted") {
                XCTAssertTrue("\($0)".contains("SHA-256"), "\($0)")
            }
        }
    }

    func testZeroSizeIsRefused() {
        let p = goodPackage.replacingOccurrences(of: "\"sizeBytes\": 100", with: "\"sizeBytes\": 0")
        XCTAssertThrowsError(try DriverCatalog.decode(json(packages: p, models: goodModel), source: "t"))
    }

    func testDuplicatePackageIDsAreRefused() {
        XCTAssertThrowsError(try DriverCatalog.decode(
            json(packages: "\(goodPackage), \(goodPackage)", models: goodModel), source: "t")) {
            XCTAssertTrue("\($0)".contains("duplicate"), "\($0)")
        }
    }

    func testAModelPointingAtAMissingPackageIsRefused() {
        let m = goodModel.replacingOccurrences(of: "[\"p1\"]", with: "[\"nope\"]")
        XCTAssertThrowsError(try DriverCatalog.decode(json(packages: goodPackage, models: m), source: "t")) {
            XCTAssertTrue("\($0)".contains("unknown package"), "\($0)")
        }
    }

    func testEmptyCatalogsAreRefused() {
        XCTAssertThrowsError(try DriverCatalog.decode(json(packages: "", models: goodModel), source: "t"))
        XCTAssertThrowsError(try DriverCatalog.decode(json(packages: goodPackage, models: ""), source: "t"))
    }

    /// A catalogue written for a newer rufus4mac must be refused, not half-understood.
    func testAFutureFormatVersionIsRefused() {
        let data = Data("""
        { "formatVersion": 99, "packages": [\(goodPackage)], "models": [\(goodModel)] }
        """.utf8)
        XCTAssertThrowsError(try DriverCatalog.decode(data, source: "t")) {
            XCTAssertTrue("\($0)".contains("format"), "\($0)")
        }
    }

    func testAMissingFormatVersionIsTreatedAsOne() throws {
        let data = Data("""
        { "packages": [\(goodPackage)], "models": [\(goodModel)] }
        """.utf8)
        XCTAssertNoThrow(try DriverCatalog.decode(data, source: "t"))
    }

    func testMalformedJSONIsReportedWithItsSource() {
        XCTAssertThrowsError(try DriverCatalog.decode(Data("{ nonsense".utf8), source: "theirs.json")) {
            XCTAssertTrue("\($0)".contains("theirs.json"), "\($0)")
        }
    }

    func testTheBundledCatalogPassesItsOwnValidation() throws {
        XCTAssertNoThrow(try DriverCatalog.bundled().validate(source: "bundled"))
    }
}

final class CatalogStoreTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cat-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private func write(_ name: String, _ body: String) throws {
        try Data(body.utf8).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name)))
    }
    private func catalogJSON(name: String, model: String, packageID: String = "p1") -> String {
        """
        { "formatVersion": 1, "name": "\(name)",
          "packages": [{ "id": "\(packageID)", "name": "Wi-Fi", "vendor": "V", "version": "1",
            "url": "https://example.com/a.exe",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sizeBytes": 1, "covers": "x" }],
          "models": [{ "name": "\(model)", "modelNumbers": "N1", "packageIDs": ["\(packageID)"] }] }
        """
    }

    func testLoadsTheBundledCatalogWhenTheFolderIsEmpty() {
        let r = CatalogStore.loadAll(userDirectory: dir)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(r.catalogs.count, 1)
        XCTAssertEqual(r.catalogs.first?.origin, .bundled)
        XCTAssertFalse(r.catalogs.first!.origin.isRemovable, "the bundled catalog cannot be removed")
    }

    func testUserCatalogsJoinTheBundledOne() throws {
        try write("theirs.json", catalogJSON(name: "Someone's list", model: "Their Laptop"))
        let r = CatalogStore.loadAll(userDirectory: dir)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(r.catalogs.count, 2)
        let names = CatalogStore.entries(in: r.catalogs).map(\.name)
        XCTAssertTrue(names.contains("Their Laptop"))
        XCTAssertTrue(names.contains("Galaxy Book5 Pro"), "the bundled devices are still offered")
    }

    /// One publisher's broken file must not cost the user every other device.
    func testABrokenCatalogIsReportedAndSkippedWithoutLosingTheRest() throws {
        try write("broken.json", "{ not json")
        try write("good.json", catalogJSON(name: "Good", model: "Fine Laptop"))
        let r = CatalogStore.loadAll(userDirectory: dir)
        XCTAssertEqual(r.problems.count, 1)
        XCTAssertTrue(r.problems[0].contains("broken.json"))
        XCTAssertEqual(r.catalogs.count, 2, "bundled + good")
        XCTAssertTrue(CatalogStore.entries(in: r.catalogs).map(\.name).contains("Fine Laptop"))
    }

    /// Two publishers can name a device the same thing; entries stay distinct and traceable.
    func testDevicesFromDifferentCatalogsDoNotCollide() throws {
        try write("a.json", catalogJSON(name: "A", model: "Same Name"))
        try write("b.json", catalogJSON(name: "B", model: "Same Name"))
        let r = CatalogStore.loadAll(userDirectory: dir, includeBundled: false)
        let entries = CatalogStore.entries(in: r.catalogs)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "entries must be distinguishable")
        XCTAssertEqual(Set(entries.map(\.catalogName)), ["A", "B"])
    }

    func testEntriesResolveBackToTheirOwnCatalog() throws {
        try write("a.json", catalogJSON(name: "A", model: "Laptop A", packageID: "shared-id"))
        try write("b.json", catalogJSON(name: "B", model: "Laptop B", packageID: "shared-id"))
        let r = CatalogStore.loadAll(userDirectory: dir, includeBundled: false)
        for e in CatalogStore.entries(in: r.catalogs) {
            let c = CatalogStore.catalog(for: e, in: r.catalogs)
            XCTAssertNotNil(c)
            XCTAssertEqual(c?.name, e.catalogName, "an entry must resolve to the catalog it came from")
            XCTAssertFalse(c!.packages(for: e.model).isEmpty)
        }
    }

    /// Validation happens before the file lands, so a bad download cannot poison every later launch.
    func testInstallRefusesAnInvalidCatalogAndWritesNothing() {
        XCTAssertThrowsError(try CatalogStore.install(data: Data("{ bad".utf8),
                                                      named: "x.json", into: dir))
        XCTAssertEqual(try! FileManager.default.contentsOfDirectory(atPath: dir), [])
    }

    func testInstallNamesTheFileAfterTheCatalog() throws {
        let path = try CatalogStore.install(
            data: Data(catalogJSON(name: "Dell Latitude", model: "Latitude 7440").utf8),
            named: "download.json", into: dir)
        XCTAssertEqual((path as NSString).lastPathComponent, "Dell Latitude.json")
        XCTAssertTrue(CatalogStore.loadAll(userDirectory: dir).catalogs
            .contains { $0.name == "Dell Latitude" })
    }

    func testInstallSanitisesNamesThatWouldEscapeTheFolder() throws {
        let path = try CatalogStore.install(
            data: Data(catalogJSON(name: "../../evil", model: "M").utf8),
            named: "x.json", into: dir)
        XCTAssertEqual((path as NSString).deletingLastPathComponent, dir,
                       "the file must stay inside the catalog folder")
    }
}

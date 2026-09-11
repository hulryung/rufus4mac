import XCTest
@testable import RufusCore

final class WorkflowRecordsTests: XCTestCase {
    func testPresetRoundTripKeepsOptionsAndModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("presets.json")
        let preset = SetupPreset(name: "한국어 PC", settings: ["label": "USB", "verify": "true"], driverNames: ["Wi-Fi", "Storage"])
        try RecordFile.write([preset], to: file)
        XCTAssertEqual(try RecordFile.read([SetupPreset].self, from: file), [preset])
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("imagePath"))
    }
    func testCorruptFileIsNotSilentlyReplacedOnRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("{broken".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try RecordFile.read([SetupPreset].self, from: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testHistoryPersistsUnfinishedAndFailure() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var report = OperationReport(appVersion: "0.6.0", task: "Format USB", sourceName: nil, target: "disk4", options: ["GPT"])
        try RecordFile.write([report], to: file)
        XCTAssertNil(try RecordFile.read([OperationReport].self, from: file).first?.succeeded)
        report.finish(phase: "formatting", error: "read only")
        try RecordFile.write([report], to: file)
        let restored = try XCTUnwrap(RecordFile.read([OperationReport].self, from: file).first)
        XCTAssertEqual(restored.succeeded, false)
        XCTAssertEqual(restored.error, "read only")
        XCTAssertEqual(restored.options, ["GPT"])
    }
    func testVersionOrderingAndRejection() throws {
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("v0.9.9")), try XCTUnwrap(ReleaseVersion("0.10.0")))
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("v1.0.0"))
        for invalid in ["latest", "v0.6.0-beta", "1.-1.2", "1..0", "999999999999999999999.0", "1.0.0.1"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
    }
}

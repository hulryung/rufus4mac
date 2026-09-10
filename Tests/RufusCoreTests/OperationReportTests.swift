import XCTest
@testable import RufusCore

final class OperationReportTests: XCTestCase {
    func testFinishedReportRetainsOriginalOutcome() throws {
        var report = OperationReport(appVersion: "0.5.0", task: "format", sourceName: nil,
                                     target: "disk4", options: ["exFAT", "GPT"])
        report.finish(phase: "formatting", error: "Disk disconnected")
        report.finish(phase: "done", error: nil)
        XCTAssertEqual(report.succeeded, false)
        XCTAssertEqual(report.error, "Disk disconnected")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(json["target"] as? String, "disk4")
        XCTAssertEqual(json["options"] as? [String], ["exFAT", "GPT"])
    }

    func testSuccessfulReportAndUnfinishedReportAreDistinct() throws {
        var report = OperationReport(appVersion: "0.5.0", task: "write", sourceName: "한국어.iso",
                                     target: "disk7", options: ["verify"])
        XCTAssertNil(report.succeeded)
        XCTAssertNil(report.finishedAt)
        report.finish(phase: "verifying", error: nil)
        XCTAssertEqual(report.succeeded, true)
        XCTAssertNotNil(report.finishedAt)
        XCTAssertTrue(String(decoding: try report.encoded(), as: UTF8.self).contains("한국어.iso"))
    }
}

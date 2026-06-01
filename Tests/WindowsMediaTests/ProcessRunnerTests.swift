import XCTest
@testable import WindowsMedia

final class ProcessRunnerTests: XCTestCase {
    func testRunsAndCapturesStdoutAndStatus() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/echo", ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroStatusCaptured() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stderr.contains("oops"))
    }
}

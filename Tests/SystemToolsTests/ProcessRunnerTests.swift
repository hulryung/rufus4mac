import XCTest
import SystemTools

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

    func testLargeStderrDoesNotDeadlock() throws {
        // ~512 KB to stderr before any stdout — would hang a sequential reader.
        let r = SystemProcessRunner()
        let script = "yes X | head -c 524288 1>&2; echo done"
        let result = try r.run("/bin/sh", ["-c", script])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertEqual(result.stderr.utf8.count, 524288)
    }
}

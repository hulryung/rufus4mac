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

    /// Progress must reach the caller *while* the child runs — reading stdout to EOF first would
    /// leave a multi-minute wimlib split showing 0% the whole way.
    func testStdoutIsStreamedBeforeTheChildExits() throws {
        let r = SystemProcessRunner()
        let sentinel = expectation(description: "first chunk arrives before exit")
        var chunks: [String] = []
        // Emits, waits, then emits again: the first chunk can only be seen early.
        let result = try r.run("/bin/sh", ["-c", "echo first; sleep 1; echo second"]) { chunk in
            chunks.append(chunk)
            if chunks.count == 1 { sentinel.fulfill() }
        }
        wait(for: [sentinel], timeout: 0)   // already fulfilled if streaming worked
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "expected separate chunks, got \(chunks)")
        XCTAssertEqual(chunks.joined(), result.stdout)
        XCTAssertEqual(result.stdout, "first\nsecond\n")
    }

    func testStreamingStillCapturesLargeStderrWithoutDeadlock() throws {
        let r = SystemProcessRunner()
        var streamed = ""
        let result = try r.run("/bin/sh", ["-c", "yes X | head -c 524288 1>&2; echo done"]) {
            streamed += $0
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr.utf8.count, 524288)
        XCTAssertEqual(streamed.trimmingCharacters(in: .whitespacesAndNewlines), "done")
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

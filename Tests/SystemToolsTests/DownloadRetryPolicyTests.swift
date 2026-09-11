import XCTest
@testable import SystemTools

final class DownloadRetryPolicyTests: XCTestCase {
    func testTransientErrorsOnly() {
        for status in [408, 429, 500, 502, 503] { XCTAssertTrue(DownloadRetryPolicy.shouldRetry(status: status)) }
        for status in [200, 301, 400, 401, 403, 404] { XCTAssertFalse(DownloadRetryPolicy.shouldRetry(status: status)) }
        XCTAssertTrue(DownloadRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertFalse(DownloadRetryPolicy.shouldRetry(URLError(.cancelled)))
        XCTAssertFalse(DownloadRetryPolicy.shouldRetry(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(DownloadRetryPolicy.shouldRetry(CancellationError()))
    }
    func testCancelledDownloadNeverStarts() async {
        let job = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await DownloadClient.download(URL(string: "http://127.0.0.1:1/test")!, progress: { _, _ in })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await job.value
        XCTAssertTrue(cancelled)
    }
}

import Foundation

public struct DownloadHTTPError: LocalizedError, Sendable {
    public let status: Int
    public var errorDescription: String? { "Download server returned HTTP \(status)." }
}

public enum DownloadRetryPolicy {
    public static func shouldRetry(status: Int) -> Bool { status == 408 || status == 429 || (500...599).contains(status) }
    public static func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
    }
}

/// Own a session delegate: the async task-delegate overload does not forward download progress
/// consistently across supported macOS versions. The continuation and cancellation share a lock.
private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var result: Result<(URL, URLResponse), Error>?
    init(_ progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDownloadTask? = lock.withLock {
                    guard !cancelled else { return nil }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    let task = session.downloadTask(with: request)
                    self.task = task
                    return task
                }
                if let task { task.resume() } else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.task }
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The URLSession temporary file disappears when this callback returns.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("rufus-download-" + UUID().uuidString)
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success((destination, response))
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock {
            let value = (continuation, cancelled)
            continuation = nil; self.task = nil; self.session = nil
            return value
        }
        session.finishTasksAndInvalidate()
        if let error = state.1 ? CancellationError() : error {
            if case .success(let value) = result { try? FileManager.default.removeItem(at: value.0) }
            state.0?.resume(throwing: error)
        } else { state.0?.resume(with: result ?? .failure(URLError(.badServerResponse))) }
    }
}

public enum DownloadClient {
    /// Automatic retry is restricted to transient transport/server failures, never integrity failures.
    public static func download(_ url: URL, session: URLSession = .shared,
                                progress: @escaping @Sendable (Int64, Int64) -> Void,
                                retrying: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> (URL, URLResponse) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 60
                let (file, response) = try await DownloadTransfer(progress).run(request, configuration: session.configuration)
                if Task.isCancelled { try? FileManager.default.removeItem(at: file); throw CancellationError() }
                guard let http = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: file); throw URLError(.badServerResponse)
                }
                if !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: file)
                    throw DownloadHTTPError(status: http.statusCode)
                }
                return (file, response)
            } catch {
                let transient = (error as? DownloadHTTPError).map { DownloadRetryPolicy.shouldRetry(status: $0.status) }
                    ?? DownloadRetryPolicy.shouldRetry(error)
                guard attempt < 2, transient, !Task.isCancelled else { throw error }
                retrying(attempt + 1)
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw URLError(.unknown)
    }
}

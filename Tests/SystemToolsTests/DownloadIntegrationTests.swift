import XCTest
import Network
@testable import SystemTools

/// A loopback-only HTTP server exercises URLSession's actual progress and cancellation behavior.
private final class DownloadServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "download-test-server")
    private let lock = NSLock()
    private var attempts = 0
    var requestCount: Int { lock.withLock { attempts } }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port {
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let attempt = self.lock.withLock { self.attempts += 1; return self.attempts }
                    let status = request.contains("/missing") ? 404 : request.contains("/retry") && attempt < 3 ? 503 : 200
                    if status != 200 {
                        connection.send(content: Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { error in
                            if error == nil { self.sendChunk(connection, remaining: 16) }
                        })
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    private func sendChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        connection.send(content: Data(repeating: 0x42, count: 65536), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.03) { self.sendChunk(connection, remaining: remaining - 1) }
        })
    }
    func stop() { listener.cancel() }
}

final class DownloadIntegrationTests: XCTestCase, @unchecked Sendable {
    func testRetriesTransientHTTPAndDeliversProgress() async throws {
        let server = try DownloadServer(); defer { server.stop() }
        let port = try await server.start()
        let progress = expectation(description: "Received bytes"); progress.assertForOverFulfill = false
        let (file, _) = try await DownloadClient.download(URL(string: "http://127.0.0.1:\(port)/retry")!, progress: { bytes, total in
            if bytes > 0 && total == 1048576 { progress.fulfill() }
        })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 0x42, count: 1048576))
        XCTAssertEqual(server.requestCount, 3)
        await fulfillment(of: [progress], timeout: 2)
    }
    func test404IsNotRetried() async throws {
        let server = try DownloadServer(); defer { server.stop() }
        let port = try await server.start()
        do {
            _ = try await DownloadClient.download(URL(string: "http://127.0.0.1:\(port)/missing")!, progress: { _, _ in })
            XCTFail("404 succeeded")
        } catch let error as DownloadHTTPError { XCTAssertEqual(error.status, 404) }
        XCTAssertEqual(server.requestCount, 1)
    }
    func testCancelAnActiveDownload() async throws {
        let server = try DownloadServer(); defer { server.stop() }
        let port = try await server.start()
        let progress = expectation(description: "Transfer began"); progress.assertForOverFulfill = false
        let job = Task {
            try await DownloadClient.download(URL(string: "http://127.0.0.1:\(port)/slow")!, progress: { bytes, _ in
                if bytes > 0 { progress.fulfill() }
            })
        }
        await fulfillment(of: [progress], timeout: 5)
        job.cancel()
        do {
            let (file, _) = try await job.value
            try? FileManager.default.removeItem(at: file)
            XCTFail("Cancelled transfer succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(server.requestCount, 1)
    }
}

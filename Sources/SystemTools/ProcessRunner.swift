import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Runs an external process to completion. Injectable so orchestration can be unit-tested.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult

    /// Run, handing each chunk of the child's progress output to `onOutput` as it arrives, so a
    /// long-running command can drive a progress bar instead of looking frozen. `onOutput` is
    /// called synchronously on the calling thread and must not be stored.
    func run(_ executable: String, _ arguments: [String],
             onOutput: (String) -> Void) throws -> ProcessResult
}

extension ProcessRunner {
    /// Runners that have nothing to stream (test fakes) just run the command.
    public func run(_ executable: String, _ arguments: [String],
                    onOutput: (String) -> Void) throws -> ProcessResult {
        try run(executable, arguments)
    }
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        try run(executable, arguments, onOutput: { _ in })
    }

    public func run(_ executable: String, _ arguments: [String],
                    onOutput: (String) -> Void) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        // Drain stderr on a background queue while stdout is read on this thread,
        // so a child that fills one pipe before closing the other can't deadlock us.
        let errFH = err.fileHandleForReading
        let sink = DataSink()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sink.set(errFH.readDataToEndOfFile())
            done.signal()
        }
        // Read stdout chunk by chunk rather than to EOF, so progress reaches the caller while the
        // child is still running. `availableData` returns empty only at EOF.
        let outFH = out.fileHandleForReading
        var oData = Data()
        while true {
            let chunk = outFH.availableData
            if chunk.isEmpty { break }
            oData.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) { onOutput(text) }
        }
        done.wait()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(data: oData, encoding: .utf8) ?? "",
                             stderr: String(data: sink.take(), encoding: .utf8) ?? "")
    }
}

/// Hands the stderr bytes back from the draining queue; the semaphore orders the write before
/// the read, so a plain lock is enough to satisfy the compiler's concurrency checking.
private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

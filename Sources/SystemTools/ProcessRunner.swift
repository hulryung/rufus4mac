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
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        // Drain stderr on a background queue while stdout is read on this thread,
        // so a child that fills one pipe before closing the other can't deadlock us.
        let errFH = err.fileHandleForReading
        var eData = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            eData = errFH.readDataToEndOfFile()
            done.signal()
        }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(data: oData, encoding: .utf8) ?? "",
                             stderr: String(data: eData, encoding: .utf8) ?? "")
    }
}

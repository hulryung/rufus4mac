import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
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
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(data: oData, encoding: .utf8) ?? "",
                             stderr: String(data: eData, encoding: .utf8) ?? "")
    }
}

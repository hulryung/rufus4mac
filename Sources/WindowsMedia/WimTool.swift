import Foundation
import SystemTools

public struct WimToolError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public struct WimTool: Sendable {
    let runner: ProcessRunner
    let imagexPath: String

    public init(runner: ProcessRunner, imagexPath: String) {
        self.runner = runner; self.imagexPath = imagexPath
    }

    /// Locate `wimlib-imagex`: bundled in the app first, then a dev Homebrew path.
    /// Returns nil if not found.
    public static func locateImagex(bundledDir: String?) -> String? {
        var candidates: [String] = []
        if let d = bundledDir { candidates.append("\(d)/wimlib-imagex") }
        candidates += ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `wimlib-imagex split <wim> <out.swm> <chunkMB>`. Throws on non-zero exit.
    public func split(wim: String, outFirstSWM: String, chunkMB: Int) throws {
        let r = try runner.run(imagexPath, ["split", wim, outFirstSWM, String(chunkMB)])
        if r.status != 0 {
            throw WimToolError(message: "wimlib-imagex split failed (\(r.status)): \(r.stderr)")
        }
    }

    /// `wimlib-imagex info <wim>`. A WIM keeps its XML data and integrity table at the end of the
    /// file, so this reads back the tail of each part and fails on a truncated one — the cheap way
    /// to tell a complete part from one whose write was cut short.
    public func info(wim: String) throws {
        let r = try runner.run(imagexPath, ["info", wim])
        if r.status != 0 {
            throw WimToolError(message: "\((wim as NSString).lastPathComponent) is unreadable (\(r.status)): \(r.stderr)")
        }
    }
}

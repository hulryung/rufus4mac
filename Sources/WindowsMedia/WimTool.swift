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
}

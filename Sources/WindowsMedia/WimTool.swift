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
    ///
    /// Splitting a Windows install.wim moves ~7 GB and takes minutes, so the tool's own progress
    /// output is parsed and forwarded to `progress` (0...1) as it arrives — without it the UI sits
    /// at 0% for the whole split and looks hung.
    public func split(wim: String, outFirstSWM: String, chunkMB: Int,
                      progress: (Double) -> Void = { _ in }) throws {
        let r = try runner.run(imagexPath, ["split", wim, outFirstSWM, String(chunkMB)]) { chunk in
            if let f = Self.splitFraction(chunk) { progress(f) }
        }
        if r.status != 0 {
            throw WimToolError(message: "wimlib-imagex split failed (\(r.status)): \(r.stderr)")
        }
    }

    /// Pull the fraction out of wimlib's meter, e.g.
    /// `Splitting WIM: 3126 MiB of 6894 MiB (45%) written, part 1 of 2`.
    /// A chunk can hold several \r-separated updates; the last one is the current state.
    static func splitFraction(_ chunk: String) -> Double? {
        let pattern = try? NSRegularExpression(pattern: "([0-9]+) MiB of ([0-9]+) MiB")
        guard let pattern else { return nil }
        let ns = chunk as NSString
        let matches = pattern.matches(in: chunk, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.last,
              let done = Double(ns.substring(with: m.range(at: 1))),
              let total = Double(ns.substring(with: m.range(at: 2))), total > 0
        else { return nil }
        return min(done / total, 1)
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

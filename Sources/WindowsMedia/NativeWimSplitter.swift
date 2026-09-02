import Foundation
import WimSplit

/// `WimSplitting` backed by the MIT-licensed `WimSplit` module — no external process, no wimlib.
public struct NativeWimSplitter: WimSplitting {
    public init() {}
    public var name: String { "WimSplit" }

    public func split(wim: String, outFirstSWM: String, chunkMB: Int,
                      progress: (Double) -> Void) throws {
        let splitter = try WimSplitter(partSizeBytes: UInt64(chunkMB) * 1024 * 1024)
        _ = try splitter.split(wimPath: wim, firstPartPath: outFirstSWM, progress: progress)
    }

    public func validatePart(at path: String) throws {
        try WimSplitter.validatePart(at: path)
    }
}

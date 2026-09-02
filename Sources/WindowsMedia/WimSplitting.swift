import Foundation

/// Splits a Windows install.wim into FAT32-sized `.swm` parts.
///
/// Two implementations exist while the MIT-licensed `WimSplit` is being proven against real
/// hardware: `WimTool` shells out to the bundled GPL `wimlib-imagex` and is still the default, and
/// `NativeWimSplitter` uses `WimSplit` directly. Once the native one is confirmed by a real Windows
/// install, wimlib can be dropped from the bundle entirely.
public protocol WimSplitting: Sendable {
    /// Split `wim` into parts of at most `chunkMB` MiB, the first written to `outFirstSWM`.
    /// `progress` receives 0...1.
    func split(wim: String, outFirstSWM: String, chunkMB: Int, progress: (Double) -> Void) throws

    /// Read a written part back far enough to catch one whose tail never reached the device.
    func validatePart(at path: String) throws

    /// Shown in errors so a failure names the splitter that produced it.
    var name: String { get }
}

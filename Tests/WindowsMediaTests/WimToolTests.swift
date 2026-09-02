import XCTest
import SystemTools
@testable import WindowsMedia

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessResult(status: 0, stdout: "", stderr: "")
    /// Lets a test stand in for the command's side effects (e.g. `split` writing .swm parts).
    var onRun: ((String, [String]) -> Void)?
    /// Chunks handed to the streaming `run`, standing in for the child's progress output.
    var streamed: [String] = []
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments)); onRun?(executable, arguments); return result
    }
    func run(_ executable: String, _ arguments: [String],
             onOutput: (String) -> Void) throws -> ProcessResult {
        for chunk in streamed { onOutput(chunk) }
        return try run(executable, arguments)
    }
}

final class WimToolTests: XCTestCase {
    func testSplitInvokesImagexWithChunkSize() throws {
        let fake = FakeRunner()
        let tool = WimTool(runner: fake, imagexPath: "/usr/local/bin/wimlib-imagex")
        try tool.split(wim: "/m/sources/install.wim", outFirstSWM: "/u/sources/install.swm", chunkMB: 4000)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "/usr/local/bin/wimlib-imagex")
        XCTAssertEqual(fake.calls[0].1, ["split", "/m/sources/install.wim", "/u/sources/install.swm", "4000"])
    }

    /// wimlib's meter is the only progress signal during a multi-minute split; without parsing it
    /// the UI sits at 0% and looks hung.
    func testSplitFractionParsesWimlibMeter() {
        XCTAssertEqual(WimTool.splitFraction(
            "Splitting WIM: 3126 MiB of 6894 MiB (45%) written, part 1 of 2"), 3126.0 / 6894.0)
    }
    func testSplitFractionTakesTheLastUpdateInAChunk() {
        let chunk = "Splitting WIM: 100 MiB of 1000 MiB (10%) written, part 1 of 2\r"
                  + "Splitting WIM: 900 MiB of 1000 MiB (90%) written, part 2 of 2\r"
        XCTAssertEqual(WimTool.splitFraction(chunk), 0.9)
    }
    func testSplitFractionIgnoresUnrelatedOutput() {
        XCTAssertNil(WimTool.splitFraction("Finished splitting \"install.wim\""))
        XCTAssertNil(WimTool.splitFraction(""))
    }
    func testSplitFractionIsClampedToOne() {
        XCTAssertEqual(WimTool.splitFraction("2000 MiB of 1000 MiB"), 1)
    }
    func testSplitForwardsProgress() throws {
        let fake = FakeRunner()
        fake.streamed = ["Splitting WIM: 250 MiB of 1000 MiB (25%) written, part 1 of 2"]
        var seen: [Double] = []
        try WimTool(runner: fake, imagexPath: "/x/wimlib-imagex")
            .split(wim: "/m/install.wim", outFirstSWM: "/u/install.swm", chunkMB: 4000,
                   progress: { seen.append($0) })
        XCTAssertEqual(seen, [0.25])
    }

    func testSplitThrowsOnNonZeroStatus() {
        let fake = FakeRunner(); fake.result = ProcessResult(status: 1, stdout: "", stderr: "boom")
        let tool = WimTool(runner: fake, imagexPath: "/x/wimlib-imagex")
        XCTAssertThrowsError(try tool.split(wim: "a", outFirstSWM: "b", chunkMB: 4000))
    }
}

import XCTest
import SystemTools
@testable import WindowsMedia

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessResult(status: 0, stdout: "", stderr: "")
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments)); return result
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

    func testSplitThrowsOnNonZeroStatus() {
        let fake = FakeRunner(); fake.result = ProcessResult(status: 1, stdout: "", stderr: "boom")
        let tool = WimTool(runner: fake, imagexPath: "/x/wimlib-imagex")
        XCTAssertThrowsError(try tool.split(wim: "a", outFirstSWM: "b", chunkMB: 4000))
    }
}

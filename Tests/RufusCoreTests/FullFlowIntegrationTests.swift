import XCTest
import CryptoKit
import TestSupport
import DiskDiscovery
@testable import RufusCore

final class FullFlowIntegrationTests: XCTestCase {
    func testUnmountWriteVerify() throws {
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 211) })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p-\(UUID().uuidString).img")
        try payload.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let device = try HdiutilDevice(sizeMB: 16)
        defer { device.detach() }
        let bsd = String(device.bsdDiskPath.dropFirst("/dev/".count))

        // -nomount image has nothing mounted; unmount should be a safe no-op.
        XCTAssertNoThrow(try DiskDiscovery.unmountDisk(bsdName: bsd))

        let engine = WriteEngine()
        let hs = try FileImageSource(url: imageURL)
        let expected = try WriteEngine.sha256(of: hs); hs.close()
        let src = try FileImageSource(url: imageURL); defer { src.close() }
        let writer = try DeviceBlockWriter(devicePath: device.bsdRawPath)
        defer { try? writer.finish() }
        try engine.write(source: src, to: writer, isCancelled: { false }, progress: { _ in })
        let reader = try DeviceBlockReader(devicePath: device.bsdRawPath); defer { reader.close() }
        XCTAssertNoThrow(try engine.verify(reader: reader, imageSize: UInt64(payload.count),
                                           expectedHash: expected, isCancelled: { false },
                                           progress: { _ in }))
    }
}

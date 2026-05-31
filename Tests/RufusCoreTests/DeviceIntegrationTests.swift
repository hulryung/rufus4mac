import XCTest
import TestSupport
@testable import RufusCore

final class DeviceIntegrationTests: XCTestCase {
    func testWriteVerifyNonSectorAlignedImage() throws {
        // Size deliberately NOT a multiple of 512 — exercises verify()'s final
        // partial-sector read path against a real raw device.
        let size = 3_000_003
        let payload = Data((0..<size).map { UInt8($0 % 251) })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("odd-\(UUID().uuidString).img")
        try payload.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let device = try HdiutilDevice(sizeMB: 16)
        defer { device.detach() }

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

    func testWriteThenVerifyAgainstHdiutilDevice() throws {
        // 8 MiB image written into a 16 MB device.
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID().uuidString).img")
        try payload.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let device = try HdiutilDevice(sizeMB: 16)
        defer { device.detach() }

        let engine = WriteEngine()

        // Compute source hash, then write.
        let hashSource = try FileImageSource(url: imageURL)
        let expectedHash = try WriteEngine.sha256(of: hashSource)
        hashSource.close()

        let source = try FileImageSource(url: imageURL)
        defer { source.close() }
        let writer = try DeviceBlockWriter(devicePath: device.bsdRawPath)
        defer { try? writer.finish() }
        try engine.write(source: source, to: writer, isCancelled: { false }, progress: { _ in })

        // Verify by reading back from the raw device.
        let reader = try DeviceBlockReader(devicePath: device.bsdRawPath)
        defer { reader.close() }
        XCTAssertNoThrow(
            try engine.verify(reader: reader, imageSize: UInt64(payload.count),
                              expectedHash: expectedHash, isCancelled: { false },
                              progress: { _ in })
        )
    }
}

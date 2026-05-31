import Foundation
import RufusCore
import DiskDiscovery
import XPCProtocol

final class WriteService: NSObject, WriteServiceProtocol {
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection) { self.connection = connection }

    func ping(reply: @escaping (String) -> Void) { reply("pong") }

    func write(imagePath: String, bsdName: String, expectedSHA256 base64: String,
               reply: @escaping (String?) -> Void) {
        let observer = connection.remoteObjectProxy as? WriteProgressObserver
        do {
            // FileImageSource.init reads size via FileManager attributes (not by consuming
            // the file handle), so the handle is at offset 0 when engine.write starts.
            let source = try FileImageSource(url: URL(fileURLWithPath: imagePath))
            defer { source.close() }

            // Validate inputs BEFORE any destructive action (fail fast).
            guard let expected = Data(base64Encoded: base64) else {
                throw WriteError.invalidExpectedHash
            }
            // Fail CLOSED (I-1): only write to a disk currently enumerated as removable
            // & non-internal. A target not in this list (e.g. the boot disk, which
            // removableDisks() deliberately excludes) is refused — this is the structural
            // "never write to the boot disk" guarantee enforced in the privileged process.
            guard let target = DiskDiscovery.removableDisks().first(where: { $0.bsdName == bsdName }) else {
                throw WriteError.targetNotRemovable(bsdName: bsdName)
            }
            // Capacity check (I-2): refuse if the image is larger than the target.
            guard source.size <= target.sizeBytes else {
                throw WriteError.imageLargerThanTarget(imageSize: source.size,
                                                       targetSize: target.sizeBytes)
            }

            // Only now perform destructive operations.
            try DiskDiscovery.unmountDisk(bsdName: bsdName)

            let engine = WriteEngine()
            let rawPath = "/dev/r\(bsdName)"

            let writer = try DeviceBlockWriter(devicePath: rawPath)
            try engine.write(source: source, to: writer, isCancelled: { false }) { p in
                observer?.progress(phase: "writing", bytesDone: p.bytesWritten, total: p.totalBytes)
            }

            let reader = try DeviceBlockReader(devicePath: rawPath)
            defer { reader.close() }
            try engine.verify(reader: reader, imageSize: source.size, expectedHash: expected,
                              isCancelled: { false }) { p in
                observer?.progress(phase: "verifying", bytesDone: p.bytesWritten, total: p.totalBytes)
            }
            reply(nil)
        } catch {
            reply("\(error)")
        }
    }
}

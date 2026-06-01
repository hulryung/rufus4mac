import Foundation
import RufusCore
import DiskDiscovery

/// One-shot privileged writer invoked as: `RufusHelper writepriv <imagePath> <bsdName> <sha256base64>`
/// Runs unmount -> write -> verify, emitting progress to stdout, and exits.
/// Output protocol (one per line, stdout is unbuffered):
///   PROGRESS\t<phase>\t<bytesDone>\t<total>
///   OK
///   ERR\t<message>
///
/// NOTE: the shipping app no longer drives the write through this helper; it uses
/// `authopen` directly (see `ElevatedWriter`). This CLI is retained as an alternate
/// privileged-writer entry point.
func runWritePriv(imagePath: String, bsdName: String, sha256Base64: String) -> Never {
    setvbuf(stdout, nil, _IONBF, 0) // unbuffered so the caller can read progress live
    func emit(_ s: String) { print(s) }
    do {
        let source = try FileImageSource(url: URL(fileURLWithPath: imagePath))
        defer { source.close() }
        guard let expected = Data(base64Encoded: sha256Base64) else { throw WriteError.invalidExpectedHash }
        guard let target = DiskDiscovery.removableDisks().first(where: { $0.bsdName == bsdName }) else {
            throw WriteError.targetNotRemovable(bsdName: bsdName)
        }
        guard source.size <= target.sizeBytes else {
            throw WriteError.imageLargerThanTarget(imageSize: source.size, targetSize: target.sizeBytes)
        }
        // `diskutil unmountDisk` (we run as root) unmounts every volume AND releases the
        // whole disk for raw access, which a plain DADiskUnmount does not.
        try diskutilUnmountDisk(bsdName)
        let engine = WriteEngine()
        let raw = "/dev/r\(bsdName)"
        let writer = try DeviceBlockWriter(devicePath: raw)
        try engine.write(source: source, to: writer, isCancelled: { false }) { p in
            emit("PROGRESS\twriting\t\(p.bytesWritten)\t\(p.totalBytes)")
        }
        let reader = try DeviceBlockReader(devicePath: raw)
        defer { reader.close() }
        try engine.verify(reader: reader, imageSize: source.size, expectedHash: expected,
                          isCancelled: { false }) { p in
            emit("PROGRESS\tverifying\t\(p.bytesWritten)\t\(p.totalBytes)")
        }
        emit("OK")
        exit(0)
    } catch {
        emit("ERR\t\(error)")
        exit(1)
    }
}

/// Unmount all volumes on a whole disk and release it for raw access, via
/// `/usr/sbin/diskutil unmountDisk`. Runs as root (no sudo). Throws on failure.
private func diskutilUnmountDisk(_ bsdName: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["unmountDisk", "/dev/\(bsdName)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "rufus4mac.helper", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey:
                        "diskutil unmountDisk failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"])
    }
}

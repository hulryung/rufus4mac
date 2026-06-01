import Foundation
import RufusCore
import DiskDiscovery

/// One-shot privileged writer invoked as: `RufusHelper writepriv <imagePath> <bsdName> <sha256base64>`
/// Runs unmount -> write -> verify, emitting progress to stdout, and exits.
/// Output protocol (one per line, stdout is unbuffered):
///   PROGRESS\t<phase>\t<bytesDone>\t<total>
///   OK
///   ERR\t<message>
private let kDebugLog = "/tmp/rufus-helper-debug.log"

private func dbg(_ s: String) {
    let line = s + "\n"
    if let fh = FileHandle(forWritingAtPath: kDebugLog) {
        fh.seekToEndOfFile(); try? fh.write(contentsOf: line.data(using: .utf8)!); try? fh.close()
    } else {
        FileManager.default.createFile(atPath: kDebugLog, contents: line.data(using: .utf8))
    }
}

private func shellCapture(_ launch: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run(); p.waitUntilExit() } catch { return "spawn-error: \(error)" }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Probe-open the device with various flags and log the result (errno) for each.
private func probeOpen(_ path: String, _ flags: Int32, _ name: String) {
    let fd = open(path, flags)
    if fd >= 0 { dbg("  open(\(path), \(name)) -> OK fd=\(fd)"); close(fd) }
    else { let e = errno; dbg("  open(\(path), \(name)) -> errno=\(e) (\(String(cString: strerror(e))))") }
}

private func runDeviceDiagnostics(bsdName: String) {
    let raw = "/dev/r\(bsdName)"; let blk = "/dev/\(bsdName)"
    dbg("=== device diagnostics for \(bsdName) ===")
    dbg("uid=\(getuid()) euid=\(geteuid())")
    dbg("id: " + shellCapture("/usr/bin/id", []).trimmingCharacters(in: .newlines))
    dbg("csrutil: " + shellCapture("/usr/bin/csrutil", ["status"]).trimmingCharacters(in: .newlines))
    dbg("mount(grep \(bsdName)): " + shellCapture("/bin/sh", ["-c", "/sbin/mount | grep \(bsdName) || echo '(none mounted)'"]).trimmingCharacters(in: .newlines))
    dbg("ls -le \(raw): " + shellCapture("/bin/ls", ["-le", raw]).trimmingCharacters(in: .newlines))
    dbg("open probes (raw char device):")
    probeOpen(raw, O_RDONLY, "O_RDONLY")
    probeOpen(raw, O_WRONLY, "O_WRONLY")
    probeOpen(raw, O_WRONLY | O_SYNC, "O_WRONLY|O_SYNC")
    probeOpen(raw, O_RDWR, "O_RDWR")
    dbg("open probes (block device):")
    probeOpen(blk, O_WRONLY, "O_WRONLY")
    dbg("=== end diagnostics ===")
}

func runWritePriv(imagePath: String, bsdName: String, sha256Base64: String) -> Never {
    setvbuf(stdout, nil, _IONBF, 0) // unbuffered so the app can poll progress live
    func emit(_ s: String) { print(s) }
    // Fresh debug log for this run.
    FileManager.default.createFile(atPath: kDebugLog, contents: "rufus helper debug\n".data(using: .utf8))
    dbg("args: image=\(imagePath) bsd=\(bsdName)")
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
        // Use `diskutil unmountDisk` (we run as root) rather than DiskArbitration's
        // DADiskUnmount: it both unmounts every volume AND releases the whole disk so
        // the raw device can be opened for writing. A plain DADiskUnmount leaves the
        // device claimed and open(/dev/rdiskN, O_WRONLY) fails with EPERM.
        try diskutilUnmountDisk(bsdName)
        dbg("diskutil unmountDisk succeeded")
        runDeviceDiagnostics(bsdName: bsdName)
        let engine = WriteEngine()
        let raw = "/dev/r\(bsdName)"
        dbg("attempting real DeviceBlockWriter open of \(raw) ...")
        let writer = try DeviceBlockWriter(devicePath: raw)
        dbg("DeviceBlockWriter open SUCCEEDED")
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

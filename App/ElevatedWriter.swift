import Foundation
import Combine
import CryptoKit

/// Writes an image to a removable disk using Apple's `authopen` (setuid-root, entitled
/// to open removable volumes on behalf of the responsible app). This avoids a persistent
/// privileged helper and Full Disk Access: the app is the responsible process, so the user
/// gets an inline authorization prompt rather than a manual settings step.
@MainActor
final class ElevatedWriter: NSObject, ObservableObject {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var isRunning: Bool = false
    @Published var errorText: String?

    private let chunkSize = 4 * 1024 * 1024
    private let authopen = "/usr/libexec/authopen"

    func startWrite(imagePath: String, bsdName: String, sha256Base64: String, verify: Bool) {
        phase = "preparing"; fraction = 0; finished = false; isRunning = true; errorText = nil
        let total = ((try? FileManager.default.attributesOfItem(atPath: imagePath))?[.size]
                     as? NSNumber)?.uint64Value ?? 0
        Task.detached { [weak self] in
            await self?.run(imagePath: imagePath, bsdName: bsdName,
                            expectedBase64: sha256Base64, total: total, verify: verify)
        }
    }

    private nonisolated func set(phase: String? = nil, fraction: Double? = nil) async {
        await MainActor.run {
            if let phase { self.phase = phase }
            if let fraction { self.fraction = fraction }
        }
    }
    private nonisolated func fail(_ msg: String) async {
        await MainActor.run { self.errorText = msg; self.finished = true; self.isRunning = false }
    }
    private nonisolated func done() async {
        await MainActor.run { self.fraction = 1; self.finished = true; self.isRunning = false }
    }

    private nonisolated func run(imagePath: String, bsdName: String,
                                 expectedBase64: String, total: UInt64, verify: Bool) async {
        let raw = "/dev/r\(bsdName)"

        // 1) Unmount the whole disk (removable media unmounts without root).
        if let err = Self.runProcess("/usr/sbin/diskutil", ["unmountDisk", "/dev/\(bsdName)"]) {
            await fail("Could not unmount disk: \(err)"); return
        }

        // 2) Write: stream the (sector-padded) image into `authopen -w <raw>`.
        await set(phase: "writing", fraction: 0)
        let auth = Process()
        auth.executableURL = URL(fileURLWithPath: authopen)
        auth.arguments = ["-w", raw]
        let stdinPipe = Pipe(); auth.standardInput = stdinPipe
        let errPipe = Pipe(); auth.standardError = errPipe
        do { try auth.run() } catch { await fail("authopen launch failed: \(error)"); return }

        guard let src = FileHandle(forReadingAtPath: imagePath) else {
            try? stdinPipe.fileHandleForWriting.close(); auth.terminate()
            await fail("Cannot read image file."); return
        }
        let w = stdinPipe.fileHandleForWriting
        var written: UInt64 = 0
        do {
            while true {
                let chunk = try src.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try w.write(contentsOf: chunk)
                written += UInt64(chunk.count)
                await set(fraction: total == 0 ? 0 : Double(written) / Double(total))
            }
            // Raw devices require whole-sector writes; pad the final partial sector.
            let rem = Int(written % 512)
            if rem != 0 { try w.write(contentsOf: Data(count: 512 - rem)) }
            try w.close()
        } catch {
            try? w.close(); try? src.close(); auth.waitUntilExit()
            await fail("Write failed: \(error)"); return
        }
        try? src.close()
        auth.waitUntilExit()
        if auth.terminationStatus != 0 {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            await fail("authopen write failed (exit \(auth.terminationStatus)): "
                       + e.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        // 3) Verify (optional): read back `total` bytes via `authopen <raw>` and compare SHA-256.
        guard verify, let expected = Data(base64Encoded: expectedBase64) else { await done(); return }
        await set(phase: "verifying", fraction: 0)
        let vr = Process()
        vr.executableURL = URL(fileURLWithPath: authopen)
        vr.arguments = [raw]   // read mode: device contents -> stdout
        let outPipe = Pipe(); vr.standardOutput = outPipe
        vr.standardError = Pipe()
        do { try vr.run() } catch { await fail("verify launch failed: \(error)"); return }
        let rfh = outPipe.fileHandleForReading
        var hasher = SHA256(); var readBytes: UInt64 = 0
        while readBytes < total {
            let want = Int(min(UInt64(chunkSize), total - readBytes))
            let data = (try? rfh.read(upToCount: want)) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            readBytes += UInt64(data.count)
            await set(fraction: Double(readBytes) / Double(total))
        }
        vr.terminate(); vr.waitUntilExit()
        if readBytes < total || Data(hasher.finalize()) != expected {
            await fail("Verification failed (data mismatch)."); return
        }
        await done()
    }

    /// Run a process to completion; returns nil on success or an error string on failure.
    private nonisolated static func runProcess(_ launch: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "\(error)" }
        if p.terminationStatus != 0 {
            return String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(p.terminationStatus)"
        }
        return nil
    }
}

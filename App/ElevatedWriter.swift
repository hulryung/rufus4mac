import Foundation
import Combine

@MainActor
final class ElevatedWriter: NSObject, ObservableObject {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var errorText: String?

    private var pollTimer: Timer?
    private var logPath: String = ""

    func startWrite(imagePath: String, bsdName: String, sha256Base64: String) {
        phase = "preparing"; fraction = 0; finished = false; errorText = nil

        let helper = Bundle.main.bundlePath + "/Contents/MacOS/RufusHelper"
        logPath = NSTemporaryDirectory() + "rufus-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let captured = logPath
        // The app holds (powerbox) access to the user-picked file; a separately
        // elevated helper does NOT, and cannot read TCC-protected folders like
        // ~/Downloads. So stage the image into /tmp (world-readable; the root helper
        // can read it), point the helper there, and delete it afterward.
        let stagedPath = "/tmp/rufus-stage-\(UUID().uuidString).img"

        // Poll the log file for progress while the elevated command runs.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }

        Task.detached {
            // Stage (copy) the selected image where the root helper can read it.
            do {
                try? FileManager.default.removeItem(atPath: stagedPath)
                try FileManager.default.copyItem(atPath: imagePath, toPath: stagedPath)
            } catch {
                await MainActor.run {
                    self.pollTimer?.invalidate(); self.pollTimer = nil
                    self.errorText = "Could not prepare image: \(error)"
                    self.finished = true
                }
                return
            }

            let shell = "'\(helper)' writepriv '\(stagedPath)' \(bsdName) '\(sha256Base64)' > '\(captured)' 2>&1"
            let escaped = shell
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let errPipe = Pipe()
            p.standardError = errPipe
            var runErr: String?
            do { try p.run(); p.waitUntilExit() } catch { runErr = "\(error)" }
            let status = p.terminationStatus
            let osaErr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(atPath: stagedPath)
            await MainActor.run {
                self.finish(status: status, runError: runErr, osaErr: osaErr, log: captured)
            }
        }
    }

    private func poll() {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        // Last PROGRESS line wins.
        for line in text.split(separator: "\n").reversed() {
            let f = line.split(separator: "\t")
            if f.count == 4, f[0] == "PROGRESS",
               let done = Double(f[2]), let total = Double(f[3]) {
                phase = String(f[1])
                fraction = total == 0 ? 0 : done / total
                return
            }
        }
    }

    private func finish(status: Int32, runError: String?, osaErr: String, log: String) {
        pollTimer?.invalidate(); pollTimer = nil
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let lastLines = text.split(separator: "\n")
        if lastLines.last == "OK" && status == 0 {
            fraction = 1; finished = true; return
        }
        // Find an ERR line, else fall back to osascript error / generic.
        if let err = lastLines.first(where: { $0.hasPrefix("ERR\t") }) {
            errorText = String(err.dropFirst(4))
        } else if let runError {
            errorText = runError
        } else if osaErr.contains("-128") || osaErr.lowercased().contains("cancel") {
            errorText = "Authorization cancelled."
        } else if !osaErr.isEmpty {
            errorText = osaErr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            errorText = "Write failed (exit \(status))."
        }
        finished = true
    }
}

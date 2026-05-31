import Foundation
import Combine
import XPCProtocol

@MainActor
final class WriteClient: NSObject, ObservableObject, WriteProgressObserver {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var errorText: String?

    private var connection: NSXPCConnection?

    private func connect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: XPCConstants.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: WriteServiceProtocol.self)
        c.exportedInterface = NSXPCInterface(with: WriteProgressObserver.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                if self?.errorText == nil { self?.errorText = "helper connection lost" }
                self?.finished = true
            }
        }
        c.resume()
        connection = c
        return c
    }

    func startWrite(imagePath: String, bsdName: String, expectedSHA256Base64: String) {
        let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] err in
            // Pre-stringify err (non-Sendable) before crossing to @MainActor Task.
            let msg = "\(err)"
            Task { @MainActor in
                self?.errorText = msg
                self?.finished = true
            }
        } as? WriteServiceProtocol
        proxy?.write(imagePath: imagePath, bsdName: bsdName,
                     expectedSHA256: expectedSHA256Base64) { [weak self] errorDescription in
            Task { @MainActor in
                self?.errorText = errorDescription
                self?.finished = true
            }
        }
    }

    // WriteProgressObserver — called by the helper (non-main thread).
    nonisolated func progress(phase: String, bytesDone: UInt64, total: UInt64) {
        Task { @MainActor in
            self.phase = phase
            self.fraction = total == 0 ? 0 : Double(bytesDone) / Double(total)
        }
    }
}

import Foundation
import Combine
import RufusCore

@MainActor
final class ChecksumRunner: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var fraction: Double = 0
    @Published var result: ChecksumResult?
    @Published var errorText: String?

    func clear() { isRunning = false; fraction = 0; result = nil; errorText = nil }

    func compute(imagePath: String) {
        isRunning = true; fraction = 0; result = nil; errorText = nil
        Task.detached { [weak self] in await self?.run(imagePath: imagePath) }
    }

    private nonisolated func run(imagePath: String) async {
        do {
            let src = try FileImageSource(url: URL(fileURLWithPath: imagePath))
            defer { src.close() }
            let total = src.size
            let r = try Checksums.compute(of: src, isCancelled: { false }) { p in
                let f = total == 0 ? 1.0 : Double(p.bytesWritten) / Double(total)
                Task { @MainActor in self.fraction = f }
            }
            await MainActor.run { self.result = r; self.isRunning = false; self.fraction = 1 }
        } catch {
            await MainActor.run { self.errorText = "\(error)"; self.isRunning = false }
        }
    }
}

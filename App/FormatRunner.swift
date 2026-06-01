import Foundation
import Combine
import SystemTools
import DiskFormat

@MainActor
final class FormatRunner: NSObject, ObservableObject {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var isRunning: Bool = false
    @Published var errorText: String?

    func start(bsdName: String, options: FormatOptions) {
        phase = "formatting"; fraction = 0; finished = false; isRunning = true; errorText = nil
        Task.detached { [weak self] in await self?.run(bsdName: bsdName, options: options) }
    }

    private nonisolated func run(bsdName: String, options: FormatOptions) async {
        do {
            try DiskFormatter(runner: SystemProcessRunner()).format(bsdName: bsdName, options: options)
            await MainActor.run { self.fraction = 1; self.finished = true; self.isRunning = false }
        } catch {
            await MainActor.run { self.errorText = "\(error)"; self.finished = true; self.isRunning = false }
        }
    }
}

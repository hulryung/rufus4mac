import Foundation
import Combine
import RufusCore
import DiskDiscovery
import WindowsMedia

@MainActor
final class ImageSelection: ObservableObject {
    @Published var imageURL: URL?
    @Published var imageSize: UInt64 = 0
    @Published var sha256Base64: String?
    @Published var hashing = false
    @Published var isWindows = false

    func fits(disk: DiskInfo) -> Bool { imageSize > 0 && imageSize <= disk.sizeBytes }

    func select(url: URL) {
        imageURL = url
        sha256Base64 = nil
        isWindows = false
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        imageSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Compute the source hash off the main actor (used for verification).
    func computeHash() async {
        guard let url = imageURL else { return }
        hashing = true
        defer { hashing = false }
        let base64: String? = await Task.detached {
            guard let src = try? FileImageSource(url: url) else { return nil }
            defer { src.close() }
            let data = try? WriteEngine.sha256(of: src)
            return data?.base64EncodedString()
        }.value
        sha256Base64 = base64

        // Detect Windows ISO after hash is computed (url is already captured above)
        let detected: Bool = await Task.detached {
            let inspector = ISOInspector(runner: SystemProcessRunner())
            guard let info = try? inspector.mountAndInspect(isoPath: url.path) else { return false }
            defer { inspector.detach(mountPoint: info.mountPoint) }
            return info.isWindows
        }.value
        isWindows = detected
    }
}

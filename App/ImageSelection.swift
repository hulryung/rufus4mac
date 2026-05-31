import Foundation
import Combine
import RufusCore

@MainActor
final class ImageSelection: ObservableObject {
    @Published var imageURL: URL?
    @Published var imageSize: UInt64 = 0
    @Published var sha256Base64: String?
    @Published var hashing = false

    func select(url: URL) {
        imageURL = url
        sha256Base64 = nil
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
    }
}

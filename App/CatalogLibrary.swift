import Foundation
import WindowsMedia

/// The catalogs rufus4mac offers devices from: the bundled one, plus any the user installed.
///
/// Catalogs are plain JSON files in one folder, so sharing a device list is sending a file and
/// updating one is re-fetching it. Everything that lands here is validated first — a catalog names
/// executables that will be run on a freshly installed machine, and once catalogs come from other
/// people that is the whole of the trust story.
@MainActor
final class CatalogLibrary: ObservableObject {
    @Published private(set) var catalogs: [LoadedCatalog] = []
    /// Files that failed to load, reported rather than silently dropped.
    @Published private(set) var problems: [String] = []

    /// ~/Library/Application Support/rufus4mac/Catalogs
    static let rootURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("rufus4mac/Catalogs", isDirectory: true)
    }()

    init() { refresh() }

    var entries: [CatalogEntry] { CatalogStore.entries(in: catalogs) }

    func catalog(for entry: CatalogEntry) -> DriverCatalog? {
        CatalogStore.catalog(for: entry, in: catalogs)
    }

    func refresh() {
        try? FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        let result = CatalogStore.loadAll(userDirectory: Self.rootURL.path)
        catalogs = result.catalogs
        problems = result.problems
    }

    func addFromFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try CatalogStore.install(data: data, named: url.lastPathComponent, into: Self.rootURL.path)
        refresh()
    }

    /// Fetch a catalog and remember where it came from, so it can be updated later.
    func addFromURL(_ url: URL) async throws {
        let data = try await fetch(url)
        // Record the source when the publisher did not, so Update works on any fetched catalog.
        let stamped = try stampUpdateURL(url, into: data)
        try CatalogStore.install(data: stamped, named: url.lastPathComponent, into: Self.rootURL.path)
        refresh()
    }

    func update(_ loaded: LoadedCatalog) async throws {
        guard let source = loaded.catalog.updateURL, let path = loaded.origin.path else {
            throw CatalogLibraryError.notUpdatable
        }
        let data = try await fetch(source)
        let stamped = try stampUpdateURL(source, into: data)
        // Validate before overwriting: a bad update must not replace a working catalog.
        _ = try DriverCatalog.decode(stamped, source: loaded.name)
        try stamped.write(to: URL(fileURLWithPath: path), options: .atomic)
        refresh()
    }

    func remove(_ loaded: LoadedCatalog) {
        guard let path = loaded.origin.path else { return }
        try? FileManager.default.removeItem(atPath: path)
        refresh()
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw CatalogLibraryError.notHTTPS }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogLibraryError.httpStatus(http.statusCode)
        }
        return data
    }

    private func stampUpdateURL(_ url: URL, into data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogLibraryError.notACatalog
        }
        if object["updateURL"] == nil { object["updateURL"] = url.absoluteString }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

enum CatalogLibraryError: LocalizedError {
    case notHTTPS, notUpdatable, notACatalog
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .notHTTPS: return "Catalogs are fetched over https only."
        case .notUpdatable: return "This catalog does not say where to update from."
        case .notACatalog: return "That file is not a driver catalog."
        case .httpStatus(let c): return "The server answered \(c). Check the link."
        }
    }
}

import Foundation
import WindowsMedia

/// The on-disk library of driver profiles, and the selection carried into the next write.
///
/// A profile is a folder, so the library is just a directory the user can also manage in Finder.
/// That keeps the app out of the business of cataloguing OEM downloads: Samsung ships drivers
/// through its own updater rather than stable per-model URLs, so the file the user already
/// downloaded is the only reliable source.
@MainActor
final class DriverLibrary: ObservableObject {
    @Published private(set) var profiles: [DriverProfile] = []
    @Published var selected: Set<String> = []

    /// ~/Library/Application Support/rufus4mac/Drivers
    static let rootURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("rufus4mac/Drivers", isDirectory: true)
    }()

    private static let selectionKey = "selectedDriverProfiles"

    init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? [])
        refresh()
    }

    func refresh() {
        try? FileManager.default.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        profiles = DriverStore.profiles(in: Self.rootURL.path)
        // Drop selections whose profile is gone, so the UI never shows a phantom tick.
        let names = Set(profiles.map(\.name))
        if !selected.isSubset(of: names) { selected.formIntersection(names); persist() }
    }

    func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(selected).sorted(), forKey: Self.selectionKey)
    }

    /// Copy `files` into a profile named `model`, creating it if needed.
    func add(files: [URL], toProfileNamed model: String) throws {
        let name = Self.sanitize(model)
        guard !name.isEmpty else { throw DriverLibraryError.emptyName }
        let dir = Self.rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let dst = dir.appendingPathComponent(f.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: f, to: dst)
        }
        selected.insert(name)
        persist()
        refresh()
    }

    /// Fetch a driver package straight into a profile.
    ///
    /// There is no per-model catalogue to ship: Samsung's download centre builds its links
    /// dynamically and is still in open beta, so any table of URLs would be guesswork that rots.
    /// The host does serve files without a login once you have the link, though, so pasting one
    /// from the download centre works.
    func download(from url: URL, toProfileNamed model: String,
                  progress: @escaping (Double) -> Void) async throws {
        let name = Self.sanitize(model)
        guard !name.isEmpty else { throw DriverLibraryError.emptyName }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DriverLibraryError.badURL
        }
        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url),
                                                                    delegate: nil)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw DriverLibraryError.httpStatus(http.statusCode)
        }
        // Content-Disposition when the server offers one, else the URL's own last component.
        var filename = response.suggestedFilename ?? url.lastPathComponent
        if filename.isEmpty || filename == "/" { filename = "driver.bin" }

        let dir = Self.rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.moveItem(at: temp, to: dst)
        progress(1)
        selected.insert(name)
        persist()
        refresh()
    }

    func delete(profileNamed name: String) {
        try? FileManager.default.removeItem(at: Self.rootURL.appendingPathComponent(name))
        selected.remove(name)
        persist()
        refresh()
    }

    /// A profile name is a directory name, so keep it to something a filesystem is happy with.
    static func sanitize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func sizeLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum DriverLibraryError: LocalizedError {
    case emptyName
    case badURL
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the model."
        case .badURL: return "Enter an http or https link to the driver file."
        case .httpStatus(let code): return "The server answered \(code). Check the link."
        }
    }
}

import Foundation
import DiskDiscovery
import WindowsMedia
import SystemTools

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

    func setSelection(_ names: Set<String>) { selected = names; persist() }

    private func persist() {
        UserDefaults.standard.set(Array(selected).sorted(), forKey: Self.selectionKey)
    }

    /// Copy `files` into a profile named `model`, creating it if needed.
    func add(files: [URL], toProfileNamed model: String) throws {
        let name = Self.sanitize(model)
        guard !name.isEmpty else { throw DriverLibraryError.emptyName }
        try Task.checkCancellation()
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

    /// Fetch a catalogued package and verify it against the vendor's published SHA-256 before it
    /// joins the library. This is an executable that will be run on a fresh Windows machine, so a
    /// download that does not match is discarded rather than kept.
    func install(package: DriverPackage, forModel model: String,
                 progress: @escaping @Sendable (Int64, Int64) -> Void,
                 retrying: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let name = Self.sanitize(model)
        guard !name.isEmpty else { throw DriverLibraryError.emptyName }
        let existing = Self.rootURL.appendingPathComponent(name).appendingPathComponent(package.url.lastPathComponent)
        if (try? await verifyDownload(existing, sha256: package.sha256)) != nil {
            try Task.checkCancellation()
            selected.insert(name); persist(); refresh(); progress(1, 1); return
        }
        let (temp, response) = try await DownloadClient.download(package.url, progress: progress, retrying: retrying)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw DriverLibraryError.httpStatus(http.statusCode)
        }
        do {
            try await verifyDownload(temp, sha256: package.sha256)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try Task.checkCancellation()
        let dir = Self.rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(package.url.lastPathComponent)
        try commitDownload(temp, to: dst)
        progress(1, 1)
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
                  progress: @escaping @Sendable (Int64, Int64) -> Void,
                 retrying: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let name = Self.sanitize(model)
        guard !name.isEmpty else { throw DriverLibraryError.emptyName }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DriverLibraryError.badURL
        }
        let (temp, response) = try await DownloadClient.download(url, progress: progress, retrying: retrying)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw DriverLibraryError.httpStatus(http.statusCode)
        }
        // Content-Disposition when the server offers one, else the URL's own last component.
        var filename = response.suggestedFilename ?? url.lastPathComponent
        filename = (filename as NSString).lastPathComponent
        if filename.isEmpty || filename == "/" || filename == "." || filename == ".." { filename = "driver.bin" }

        try Task.checkCancellation()
        let dir = Self.rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(filename)
        try commitDownload(temp, to: dst)
        progress(1, 1)
        selected.insert(name)
        persist()
        refresh()
    }

    private func verifyDownload(_ file: URL, sha256: String) async throws {
        let job = Task.detached { try DriverDownload.verify(fileAt: file.path, matches: sha256) }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: { job.cancel() }
    }

    private func commitDownload(_ temp: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: temp, to: staging)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
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
    case volumeUnavailable
    case badURL
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .volumeUnavailable: return "The selected USB is no longer mounted or writable. Reconnect it and refresh the list."
        case .emptyName: return "Enter a name for the model."
        case .badURL: return "Enter an http or https link to the driver file."
        case .httpStatus(let code): return "The server answered \(code). Check the link."
        }
    }
}

/// Runs the add-only task against a mounted volume, never a whole-disk erase target.
@MainActor
final class DriverCopyRunner: ObservableObject {
    @Published var volumes: [USBVolume] = []
    @Published var selected: USBVolume?
    @Published var isRunning = false
    @Published var finished = false
    @Published var fraction = 0.0
    @Published var phase = ""
    @Published var errorText: String?

    private var work: Task<[DriverProfile], Error>?
    @Published var cancellationRequested = false
    func cancel() { guard isRunning else { return }; cancellationRequested = true; work?.cancel() }

    func refresh() {
        volumes = DiskDiscovery.writableUSBVolumes()
        if let selected {
            self.selected = volumes.first { $0.id == selected.id && $0.mountPath == selected.mountPath }
        }
    }

    func start(profileNames: [String], root: String) {
        guard !isRunning, let volume = selected else { return }
        isRunning = true; finished = false; errorText = nil; fraction = 0; phase = "copying drivers"
        cancellationRequested = false
        let job = Task.detached {
                    try Task.checkCancellation()
                    // Revalidate immediately before copying: never recreate a disappeared mount
                    // as a folder on the Mac, or silently use a different volume at the same path.
                    guard DiskDiscovery.writableUSBVolumes().contains(where: {
                        $0.id == volume.id && $0.diskName == volume.diskName && $0.mountPath == volume.mountPath
                    }) else {
                        throw DriverLibraryError.volumeUnavailable
                    }
                    return try DriverStore.addToExistingVolume(profileNames: profileNames, from: root,
                                                         to: volume.mountPath,
                                                         maximumFileSize: volume.fileSystem == "exfat" || volume.fileSystem == "apfs" || volume.fileSystem == "hfs" || volume.fileSystem == "ntfs" ? nil : 4 * 1024 * 1024 * 1024 - 1) { fraction in
                        Task { @MainActor in
                            if self.isRunning { self.fraction = max(self.fraction, fraction) }
                        }
                    }
        }
        work = job
        Task {
            do {
                _ = try await job.value
                fraction = 1
            } catch {
                errorText = cancellationRequested ? "Task cancelled. The USB may be incomplete. Eject it in Finder before unplugging, and recreate the media before using it." : error.localizedDescription
            }
            finished = true; isRunning = false
        }
    }
}

import Foundation

/// A catalogue that has been loaded, and where it came from.
public struct LoadedCatalog: Sendable, Identifiable {
    public enum Origin: Sendable, Equatable {
        /// Ships with the app; cannot be removed.
        case bundled
        /// A file in the user's catalog folder.
        case file(path: String)

        public var isRemovable: Bool { if case .file = self { return true }; return false }
        public var path: String? { if case .file(let p) = self { return p }; return nil }
    }

    public let catalog: DriverCatalog
    public let origin: Origin
    public var id: String { origin.path ?? "bundled" }
    public var name: String { catalog.displayName }
    public var canUpdate: Bool { origin.isRemovable && catalog.updateURL != nil }
}

/// One device offered to the user, tagged with the catalogue it came from — names can collide
/// across catalogues written by different people.
public struct CatalogEntry: Sendable, Identifiable, Hashable {
    public let catalogID: String
    public let catalogName: String
    public let model: CatalogModel
    public var id: String { "\(catalogID)|\(model.name)" }
    public var name: String { model.name }
}

/// Loads the catalogues rufus4mac offers: the one it ships with, plus any the user has installed.
///
/// Catalogues are ordinary JSON files in one folder, so sharing a device list is sending a file.
/// Each is validated on load and a bad one is reported and skipped rather than taking the rest
/// down with it — one broken file from one publisher must not cost the user every other device.
public enum CatalogStore {
    public static let fileExtension = "json"

    public struct LoadResult: Sendable {
        public var catalogs: [LoadedCatalog]
        public var problems: [String]
    }

    public static func loadAll(userDirectory: String, includeBundled: Bool = true) -> LoadResult {
        var catalogs: [LoadedCatalog] = []
        var problems: [String] = []

        if includeBundled {
            do { catalogs.append(LoadedCatalog(catalog: try DriverCatalog.bundled(), origin: .bundled)) }
            catch { problems.append("\(error)") }
        }

        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: userDirectory)) ?? [])
            .filter { $0.hasSuffix(".\(fileExtension)") && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            let path = (userDirectory as NSString).appendingPathComponent(name)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let catalog = try DriverCatalog.decode(data, source: name)
                catalogs.append(LoadedCatalog(catalog: catalog, origin: .file(path: path)))
            } catch {
                problems.append("\(error)")
            }
        }
        return LoadResult(catalogs: catalogs, problems: problems)
    }

    /// Every device across every catalogue, in load order.
    public static func entries(in catalogs: [LoadedCatalog]) -> [CatalogEntry] {
        catalogs.flatMap { loaded in
            loaded.catalog.models.map {
                CatalogEntry(catalogID: loaded.id, catalogName: loaded.name, model: $0)
            }
        }
    }

    public static func catalog(for entry: CatalogEntry, in catalogs: [LoadedCatalog]) -> DriverCatalog? {
        catalogs.first { $0.id == entry.catalogID }?.catalog
    }

    /// Save a catalogue file, validating before it is written so a bad download never lands in the
    /// folder to fail on every later launch.
    @discardableResult
    public static func install(data: Data, named suggestedName: String,
                               into userDirectory: String) throws -> String {
        let catalog = try DriverCatalog.decode(data, source: suggestedName)
        let base = safeFileName(catalog.name ?? (suggestedName as NSString).deletingPathExtension)
        try FileManager.default.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        let path = (userDirectory as NSString).appendingPathComponent("\(base).\(fileExtension)")
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    static func safeFileName(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "catalog" : cleaned
    }
}

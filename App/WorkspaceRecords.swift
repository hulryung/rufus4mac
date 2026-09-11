import Foundation
import SwiftUI
import RufusCore

@MainActor
final class WorkspaceRecords: ObservableObject {
    @Published private(set) var presets: [SetupPreset] = []
    @Published private(set) var history: [OperationReport] = []
    @Published var error: String?
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rufus4mac")
    private var readablePresets = true
    private var readableHistory = true

    init() {
        let p = root.appendingPathComponent("presets.json")
        let h = root.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: p.path) {
            do { presets = try RecordFile.read([SetupPreset].self, from: p) }
            catch { readablePresets = false; self.error = error.localizedDescription }
        }
        if FileManager.default.fileExists(atPath: h.path) {
            do { history = try RecordFile.read([OperationReport].self, from: h) }
            catch { readableHistory = false; self.error = error.localizedDescription }
        }
    }
    func savePreset(_ preset: SetupPreset) {
        guard readablePresets else { return }
        var updated = presets.filter { $0.id != preset.id }; updated.append(preset)
        do { try RecordFile.write(updated, to: root.appendingPathComponent("presets.json")); presets = updated; clearResolvedError() }
        catch { self.error = error.localizedDescription }
    }
    func deletePreset(_ id: UUID) {
        guard readablePresets else { return }
        let updated = presets.filter { $0.id != id }
        do { try RecordFile.write(updated, to: root.appendingPathComponent("presets.json")); presets = updated; clearResolvedError() }
        catch { self.error = error.localizedDescription }
    }
    func record(_ report: OperationReport) {
        guard readableHistory else { return }
        var updated = history.filter { $0.startedAt != report.startedAt }; updated.insert(report, at: 0)
        updated = Array(updated.prefix(100))
        do { try RecordFile.write(updated, to: root.appendingPathComponent("history.json")); history = updated; clearResolvedError() }
        catch { self.error = error.localizedDescription }
    }
    private func clearResolvedError() {
        if readablePresets && readableHistory { error = nil }
    }
    func clearHistory() {
        do { try RecordFile.write([OperationReport](), to: root.appendingPathComponent("history.json")); history = []; readableHistory = true; clearResolvedError() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var checking = false
    @Published var availableVersion: String?
    @Published var checked = false
    @Published var error: String?
    let releaseURL = URL(string: "https://github.com/hulryung/rufus4mac/releases/latest")!
    func check(current: String) {
        guard !checking else { return }
        checking = true; error = nil; checked = false; availableVersion = nil
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/hulryung/rufus4mac/releases/latest")!)
                request.timeoutInterval = 20
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
                struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard !release.draft, !release.prerelease, let latest = ReleaseVersion(release.tag_name), let installed = ReleaseVersion(current) else { throw URLError(.cannotParseResponse) }
                if latest > installed { availableVersion = release.tag_name }
                checked = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

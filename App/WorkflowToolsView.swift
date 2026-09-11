import Localization
import SwiftUI
import RufusCore
import UniformTypeIdentifiers

struct WorkflowToolsView: View {
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var records: WorkspaceRecords
    @ObservedObject var updates: UpdateChecker
    let locked: Bool
    let version: String
    let makePreset: (String) -> SetupPreset
    let applyPreset: (SetupPreset) -> Void
    @State private var presetName = ""
    @State private var clearConfirmation = false
    @State private var exportError: String?
    private func tr(_ message: Localization.Message) -> String { language.text(message) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Tools")).font(.title2.bold())
            TabView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Save Windows options, format settings and driver selections. USB targets and image paths are never saved in presets."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField(tr("Preset name"), text: $presetName).textFieldStyle(.roundedBorder)
                        Button(tr("Save preset")) {
                            records.savePreset(makePreset(presetName.trimmingCharacters(in: .whitespacesAndNewlines)))
                            if records.error == nil { presetName = "" }
                        }.disabled(locked || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    List(records.presets) { preset in
                        HStack {
                            Text(preset.name).lineLimit(2)
                            Spacer()
                            Button(tr("Apply")) { applyPreset(preset); dismiss() }.disabled(locked)
                            Button { records.deletePreset(preset.id) } label: { Image(systemName: "trash") }
                                .help(tr("Delete preset")).disabled(locked)
                        }
                    }
                }.padding().tabItem { Text(tr("Presets")) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("The latest 100 tasks stay on this Mac. An unfinished record means the app stopped before completion."))
                        .font(.caption).foregroundStyle(.secondary)
                    List(Array(records.history.enumerated()), id: \.offset) { _, report in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(language.raw(report.task)).fontWeight(.medium)
                                Spacer()
                                Text(report.startedAt, style: .date)
                                Text(report.startedAt, style: .time)
                            }
                            Text(report.succeeded == true ? tr("Completed") : report.succeeded == false ? tr("Failed or cancelled") : tr("Unfinished"))
                            Text(([report.target, report.sourceName].compactMap { $0 } + report.options).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let error = report.error { Text(language.raw(error)).font(.caption).textSelection(.enabled) }
                            Button(tr("Export report…")) { export(report) }
                        }.padding(.vertical, 4)
                    }
                    Button(tr("Clear history…")) { clearConfirmation = true }.disabled(locked || records.history.isEmpty)
                }.padding().tabItem { Text(tr("History")) }
                VStack(alignment: .leading, spacing: 16) {
                    Text(tr("Installed version: \(version)"))
                    Text(tr("Check GitHub for a newer stable release. Updates are downloaded and installed only when you choose to do so."))
                        .foregroundStyle(.secondary)
                    Button(tr("Check for updates")) { updates.check(current: version) }.disabled(updates.checking)
                    if updates.checking { ProgressView() }
                    if let latest = updates.availableVersion {
                        Text(tr("New version available: \(latest)")).font(.headline)
                        Link(tr("View release and download"), destination: updates.releaseURL)
                    } else if updates.checked { Text(tr("You are up to date.")) }
                    if let error = updates.error {
                        Text(tr("Could not check for updates. Try again later.")).foregroundStyle(.orange)
                        Text(error).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                }.padding().tabItem { Text(tr("Updates")) }
            }.frame(height: 370)
            if let error = records.error {
                Text(tr("Could not load or save local records. Your existing files have been kept."))
                    .foregroundStyle(.orange)
                Text(error).font(.caption).textSelection(.enabled)
            }
            HStack { Spacer(); Button(tr("Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580)
        .alert(tr("Clear all task history?"), isPresented: $clearConfirmation) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Clear history"), role: .destructive) { records.clearHistory() }
        } message: { Text(tr("This removes saved task records only. USB files and exported reports are kept.")) }
        .alert(tr("Could not save report"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(tr("Done")) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private func export(_ report: OperationReport) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "rufus4mac-report.json"
        panel.message = tr("The report includes the image filename, selected options and diagnostic details. Review it before sharing.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.encoded().write(to: url, options: .atomic) }
        catch { exportError = error.localizedDescription }
    }
}

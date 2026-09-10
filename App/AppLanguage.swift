import SwiftUI
import Localization

@MainActor
final class AppLanguage: ObservableObject {
    let catalog = LocalizationCatalog()
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "appLanguage") }
    }
    init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        selection = saved == "system" || catalog.languages.contains(where: { $0.id == saved }) ? saved : "system"
    }
    var resolvedID: String { catalog.resolve(selection: selection, preferredLanguages: Locale.preferredLanguages) }
    var locale: Locale { Locale(identifier: resolvedID) }
    func text(_ message: Message) -> String { catalog.text(message, language: resolvedID) }
    func raw(_ key: String) -> String { text(Message(key: key)) }
}

struct LanguageSettingsView: View {
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(language.text("Language settings"), systemImage: "globe")
                .font(.title2.bold())
            ScrollView {
            Picker(language.text("App language"), selection: $language.selection) {
                Text(language.text("System default")).tag("system")
                ForEach(language.catalog.languages) { definition in
                    Text(definition.nativeName).tag(definition.id)
                }
            }
            .pickerStyle(.radioGroup)
            .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 160)
            Text(language.text("Use the system language or choose one for this app. Changes apply immediately and are remembered for the next launch."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(language.text("This changes the app interface only. Windows installer language and regional settings are configured separately."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(language.text("Current language: \(language.catalog.languages.first { $0.id == language.resolvedID }?.nativeName ?? "English")"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(language.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
    }
}

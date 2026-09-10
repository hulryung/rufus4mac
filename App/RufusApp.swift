import SwiftUI

@main
struct RufusApp: App {
    @StateObject private var language = AppLanguage()
    @State private var showingLanguageSettings = false

    var body: some Scene {
        Window("rufus4mac", id: "main") {
            ContentView(showingLanguageSettings: $showingLanguageSettings)
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }
        .defaultSize(width: 660, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(language.text("Language settings…")) { showingLanguageSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

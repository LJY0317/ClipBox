import SwiftUI

@main
struct ClipBoxApp: App {
    @StateObject private var language = AppLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(language)
                .environment(\.locale, Locale(identifier: language.language.localeIdentifier))
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 1020, height: 760)

        Settings {
            SettingsView()
                .environmentObject(language)
                .environment(\.locale, Locale(identifier: language.language.localeIdentifier))
        }
    }
}

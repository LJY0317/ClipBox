import SwiftUI

@main
struct ClipBoxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
        }
    }
}

import ClipBoxCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Default downloads") {
                Text(ClipBoxPaths.defaultDownloadDirectory.path)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Private app data") {
                Text(ClipBoxPaths.applicationSupportDirectory.path)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

import AppKit
import ClipBoxCore
import SwiftUI

struct SettingsView: View {
    @State private var outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
    @State private var saveError: String?

    var body: some View {
        Form {
            LabeledContent("Default downloads") {
                HStack {
                    Text(outputDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        chooseOutputDirectory()
                    }
                }
            }

            LabeledContent("Archive database") {
                Text(ClipBoxPaths.archiveDatabaseURL.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            LabeledContent("Private adapters") {
                Text(ClipBoxPaths.adaptersDirectory.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Default Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        outputDirectory = selectedURL
        do {
            try ClipBoxPreferencesStore.save(
                ClipBoxPreferences(outputDirectoryPath: selectedURL.path)
            )
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

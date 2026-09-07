import AppKit
import ClipBoxCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
    @State private var saveError: String?
    @State private var backupStatus: String?
    @State private var isBackupWorking = false
    @State private var restorePreferences = false

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

            Section("History portability") {
                Text("Create a portable backup of ClipBox's archive history. Restore merges records instead of replacing the current database, so already-downloaded media stays remembered across Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Restore the saved download-folder preference too", isOn: $restorePreferences)

                HStack {
                    Button("Create Backup…") {
                        createBackup()
                    }
                    Button("Restore Backup…") {
                        restoreBackup()
                    }
                    if isBackupWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if let backupStatus {
                    Text(backupStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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

    private func createBackup() {
        let panel = NSSavePanel()
        panel.title = "Create ClipBox History Backup"
        panel.nameFieldStringValue = "ClipBox Backup \(backupFilenameTimestamp()).clipboxbackup"
        panel.allowedContentTypes = [clipBoxBackupType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = "Creating backup…"
        Task {
            do {
                let service = try BackupService()
                let result = try await service.createBackup(at: destination)
                backupStatus = "Backup created with \(result.recordCount) records: \(result.path)"
            } catch {
                backupStatus = "Backup failed: \(error.localizedDescription)"
            }
            isBackupWorking = false
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = "Restore ClipBox History Backup"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [clipBoxBackupType]

        guard panel.runModal() == .OK, let source = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = "Restoring and merging backup…"
        Task {
            do {
                let service = try BackupService()
                let result = try await service.restoreBackup(
                    from: source,
                    restorePreferences: restorePreferences
                )
                backupStatus = "Restore complete. Processed \(result.recordsProcessed) records, added \(result.recordsAdded), total \(result.finalRecordCount)."
                if result.preferencesRestored {
                    outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
                }
            } catch {
                backupStatus = "Restore failed: \(error.localizedDescription)"
            }
            isBackupWorking = false
        }
    }

    private var clipBoxBackupType: UTType {
        UTType(filenameExtension: "clipboxbackup") ?? .data
    }

    private func backupFilenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }
}

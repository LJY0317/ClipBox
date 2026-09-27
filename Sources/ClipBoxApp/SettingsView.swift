import AppKit
import ClipBoxCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var language: AppLanguageStore
    @State private var outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
    @State private var saveError: String?
    @State private var backupStatus: String?
    @State private var isBackupWorking = false
    @State private var restorePreferences = false

    var body: some View {
        Form {
            Section(language.text("일반", "General")) {
                Picker(language.text("언어", "Language"), selection: $language.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.nativeName).tag(option)
                    }
                }
                Text(language.text(
                    "언어를 바꾸면 ClipBox 화면에 바로 적용됩니다. 일부 macOS 시스템 메뉴는 Mac의 시스템 언어를 따릅니다.",
                    "Language changes apply to ClipBox immediately. Some macOS system menus continue to follow your Mac's system language."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(language.text("다운로드", "Downloads")) {
            LabeledContent(language.text("기본 저장 위치", "Default download folder")) {
                HStack {
                    Text(outputDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(language.text("변경…", "Choose…")) {
                        chooseOutputDirectory()
                    }
                }
            }
            }

            Section(language.text("백업", "Backup")) {
                Text(language.text(
                    "다운로드 기록을 백업해 두면 다른 Mac에서도 이미 받은 항목을 다시 받지 않을 수 있습니다. 복원해도 현재 기록은 지워지지 않습니다.",
                    "Back up your download history so another Mac can remember what you've already saved. Restoring keeps your current history and adds the backup to it."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(language.text("저장 위치 설정도 함께 복원", "Restore the saved download folder too"), isOn: $restorePreferences)

                HStack {
                    Button(language.text("백업 만들기…", "Create Backup…")) {
                        createBackup()
                    }
                    Button(language.text("백업 복원…", "Restore Backup…")) {
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

            Section(language.text("고급", "Advanced")) {
                DisclosureGroup(language.text("다운로드 기록을 파일로 내보내기", "Export Download History")) {
                    Text(language.text(
                        "다운로드 기록을 Excel, CSV 또는 JSONL 파일로 저장할 수 있습니다. 다른 Mac으로 옮길 때는 위의 ClipBox 백업이 더 간단합니다.",
                        "Save your download history as Excel, CSV, or JSONL. For moving to another Mac, the ClipBox backup above is the simpler option."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(language.text("Excel 내보내기…", "Export Excel…")) { exportHistory(format: .xlsx) }
                        Button(language.text("CSV 내보내기…", "Export CSV…")) { exportHistory(format: .csv) }
                        Button(language.text("JSONL 내보내기…", "Export JSONL…")) { exportHistory(format: .jsonl) }
                        Button(language.text("CSV/JSONL 가져오기…", "Import CSV/JSONL…")) { importHistory() }
                        Spacer()
                    }
                }

                LabeledContent(language.text("다운로드 기록 파일", "Download history file")) {
                    Text(ClipBoxPaths.archiveDatabaseURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent(language.text("개인 사이트 연결 파일", "Private site connection files")) {
                    Text(ClipBoxPaths.adaptersDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 680)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = language.text("기본 다운로드 폴더 선택", "Choose Default Download Folder")
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
        panel.title = language.text("ClipBox 백업 만들기", "Create ClipBox Backup")
        panel.nameFieldStringValue = "ClipBox Backup \(backupFilenameTimestamp()).clipboxbackup"
        panel.allowedContentTypes = [clipBoxBackupType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = language.text("백업을 만드는 중…", "Creating backup…")
        Task {
            do {
                let service = try BackupService()
                let result = try await service.createBackup(at: destination)
                backupStatus = language.text(
                    "기록 \(result.recordCount)개를 백업했습니다: \(result.path)",
                    "Backup created with \(result.recordCount) records: \(result.path)"
                )
            } catch {
                backupStatus = language.text(
                    "백업에 실패했습니다: \(error.localizedDescription)",
                    "Backup failed: \(error.localizedDescription)"
                )
            }
            isBackupWorking = false
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = language.text("ClipBox 백업 복원", "Restore ClipBox Backup")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [clipBoxBackupType]

        guard panel.runModal() == .OK, let source = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = language.text("백업을 복원하고 기존 기록과 합치는 중…", "Restoring and merging backup…")
        Task {
            do {
                let service = try BackupService()
                let result = try await service.restoreBackup(
                    from: source,
                    restorePreferences: restorePreferences
                )
                backupStatus = language.text(
                    "복원을 마쳤습니다. \(result.recordsProcessed)개를 확인해 \(result.recordsAdded)개를 추가했고, 현재 기록은 \(result.finalRecordCount)개입니다.",
                    "Restore complete. Processed \(result.recordsProcessed) records, added \(result.recordsAdded), total \(result.finalRecordCount)."
                )
                if result.preferencesRestored {
                    outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
                }
            } catch {
                backupStatus = language.text(
                    "복원에 실패했습니다: \(error.localizedDescription)",
                    "Restore failed: \(error.localizedDescription)"
                )
            }
            isBackupWorking = false
        }
    }

    private func exportHistory(format: HistoryExchangeFormat) {
        let panel = NSSavePanel()
        panel.title = language.text("ClipBox 기록 내보내기", "Export ClipBox History")
        panel.nameFieldStringValue = "ClipBox History \(backupFilenameTimestamp()).\(format.rawValue)"
        panel.allowedContentTypes = [historyType(format)]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = language.text(
            "\(format.rawValue.uppercased()) 기록을 내보내는 중…",
            "Exporting \(format.rawValue.uppercased()) history…"
        )
        Task {
            do {
                let service = try HistoryExchangeService()
                let result = try await service.export(to: destination, format: format)
                backupStatus = language.text(
                    "기록 \(result.recordCount)개를 내보냈습니다: \(result.path)",
                    "Exported \(result.recordCount) records: \(result.path)"
                )
            } catch {
                backupStatus = language.text(
                    "기록 내보내기에 실패했습니다: \(error.localizedDescription)",
                    "History export failed: \(error.localizedDescription)"
                )
            }
            isBackupWorking = false
        }
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = language.text("ClipBox 기록 가져오기", "Import ClipBox History")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .commaSeparatedText,
            UTType(filenameExtension: "jsonl") ?? .json,
        ]

        guard panel.runModal() == .OK, let source = panel.url else {
            return
        }

        isBackupWorking = true
        backupStatus = language.text("기록을 가져와 기존 기록과 합치는 중…", "Importing and merging history…")
        Task {
            do {
                let service = try HistoryExchangeService()
                let result = try await service.importHistory(from: source)
                backupStatus = language.text(
                    "\(result.recordsProcessed)개를 확인해 \(result.recordsAdded)개를 추가했고, 현재 기록은 \(result.finalRecordCount)개입니다.",
                    "Imported \(result.recordsProcessed) records, added \(result.recordsAdded), total \(result.finalRecordCount)."
                )
            } catch {
                backupStatus = language.text(
                    "기록 가져오기에 실패했습니다: \(error.localizedDescription)",
                    "History import failed: \(error.localizedDescription)"
                )
            }
            isBackupWorking = false
        }
    }

    private var clipBoxBackupType: UTType {
        UTType(filenameExtension: "clipboxbackup") ?? .data
    }

    private func historyType(_ format: HistoryExchangeFormat) -> UTType {
        switch format {
        case .csv:
            .commaSeparatedText
        case .jsonl:
            UTType(filenameExtension: "jsonl") ?? .json
        case .xlsx:
            UTType(filenameExtension: "xlsx") ?? .data
        }
    }

    private func backupFilenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }
}

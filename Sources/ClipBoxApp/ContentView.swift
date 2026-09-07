import AppKit
import ClipBoxCore
import SwiftUI

private enum SidebarSection: String, CaseIterable, Identifiable {
    case download = "Download"
    case collections = "Collections"
    case history = "History"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .collections: "rectangle.stack"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = DownloadViewModel()
    @State private var selection: SidebarSection? = .download

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("ClipBox")
        } detail: {
            switch selection ?? .download {
            case .download:
                downloadView
            case .collections:
                collectionsView
            case .history:
                historyView
            }
        }
    }

    private var downloadView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download media")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Inspect available formats and download the best quality ClipBox can retrieve without re-encoding.")
                        .foregroundStyle(.secondary)
                }

                dependencyBanner

                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Media URL", text: $model.sourceURL)
                            .textFieldStyle(.roundedBorder)

                        LabeledContent("Save to") {
                            HStack(spacing: 10) {
                                Text(model.outputDirectory.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)

                                Button("Choose…") {
                                    chooseOutputDirectory()
                                }
                            }
                        }

                        HStack {
                            Button("Analyze") {
                                model.analyze()
                            }
                            .disabled(!model.canAnalyze)

                            Spacer()

                            if model.isWorking {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button("Download Best Quality") {
                                model.download()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canDownload)
                        }
                    }
                    .padding(6)
                }

                if let media = model.media {
                    mediaSummary(media)
                }

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
        }
        .navigationTitle("Download")
    }

    @ViewBuilder
    private var dependencyBanner: some View {
        if let dependencies = model.dependencies {
            if !dependencies.ytDlp.isAvailable {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("yt-dlp is not installed", systemImage: "wrench.and.screwdriver")
                            .fontWeight(.semibold)
                        Text("ClipBox currently uses yt-dlp as its public-site extraction engine. Install it with Homebrew (`brew install yt-dlp`) or place a compatible executable in PATH.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            } else if !dependencies.ffmpeg.isAvailable {
                Label("ffmpeg is missing. Some high-quality formats cannot be merged without it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func mediaSummary(_ media: MediaMetadata) -> some View {
        GroupBox("Media") {
            VStack(alignment: .leading, spacing: 10) {
                Text(media.title ?? "Untitled")
                    .font(.headline)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Source").foregroundStyle(.secondary)
                        Text(media.site)
                    }
                    GridRow {
                        Text("Media ID").foregroundStyle(.secondary)
                        Text(media.mediaID).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Best reported size").foregroundStyle(.secondary)
                        Text(resolution(media))
                    }
                    GridRow {
                        Text("Formats").foregroundStyle(.secondary)
                        Text("\(media.formats.count)")
                    }
                }

                if !media.formats.isEmpty {
                    Divider()
                    Text("Top available formats")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    ForEach(media.formats.prefix(8)) { format in
                        HStack(spacing: 12) {
                            Text(format.formatID)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 80, alignment: .leading)
                            Text(format.resolutionDescription)
                                .frame(width: 100, alignment: .leading)
                            Text(format.extensionName ?? "-")
                                .frame(width: 44, alignment: .leading)
                            Text(format.videoCodec ?? "-")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download history")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("\(model.archiveCount) archived records. File presence is not required for an item to remain remembered.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshHistory() }
                }
            }

            if model.recentHistory.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Successful downloads and failures will appear here.")
                )
            } else {
                List {
                    ForEach(model.recentHistory) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.title ?? "Untitled")
                                    .fontWeight(.medium)
                                Spacer()
                                if record.status == .downloaded {
                                    Text(record.status.rawValue.capitalized)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(record.status.rawValue.capitalized)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("\(record.site):\(record.mediaID)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let outputPath = record.outputPath {
                                Text(outputPath)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(28)
        .navigationTitle("History")
    }

    private var collectionsView: some View {
        ContentUnavailableView(
            "Collections are next",
            systemImage: "rectangle.stack",
            description: Text("Incremental Likes, Bookmarks, Watch Later, and custom adapter collections will build on the archive engine now in place.")
        )
        .navigationTitle("Collections")
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            model.setOutputDirectory(selectedURL)
        }
    }

    private func resolution(_ media: MediaMetadata) -> String {
        guard let width = media.width, let height = media.height else {
            return "Unknown"
        }
        return "\(width)x\(height)"
    }
}

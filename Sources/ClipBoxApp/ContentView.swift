import AppKit
import ClipBoxCore
import SwiftUI

struct ContentView: View {
    @State private var sourceURL = ""
    @State private var outputDirectory = ClipBoxPaths.defaultDownloadDirectory

    var body: some View {
        NavigationSplitView {
            List {
                Label("Download", systemImage: "arrow.down.circle")
                Label("Collections", systemImage: "rectangle.stack")
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .navigationTitle("ClipBox")
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download media")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Paste a media URL. The download engine will be connected in the next implementation phase.")
                        .foregroundStyle(.secondary)
                }

                Form {
                    TextField("Media URL", text: $sourceURL)
                        .textFieldStyle(.roundedBorder)

                    LabeledContent("Save to") {
                        HStack(spacing: 10) {
                            Text(outputDirectory.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)

                            Button("Choose…") {
                                chooseOutputDirectory()
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Download") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .help("The download engine is not implemented yet.")
                }

                Spacer()
            }
            .padding(28)
            .navigationTitle("Download")
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            outputDirectory = selectedURL
        }
    }
}

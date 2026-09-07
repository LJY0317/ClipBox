import ClipBoxCore
import Combine
import Foundation

@MainActor
final class PrivateAdapterViewModel: ObservableObject {
    @Published var adapters: [PrivateAdapterManifest] = []
    @Published var selectedAdapterID: String?
    @Published var selectedCollectionID = ""
    @Published var browser: BrowserCookieSource = .safari
    @Published var scanLimit = 100
    @Published var scanAll = false
    @Published var outputDirectory: URL
    @Published var newAdapterID = ""
    @Published var scanResult: PrivateAdapterScanResult?
    @Published var syncResult: PrivateAdapterSyncResult?
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let manager = PrivateAdapterManager()
    private let syncService: PrivateAdapterSyncService?
    private let initializationError: Error?

    init() {
        outputDirectory = ((try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()).resolvedOutputDirectory
        do {
            syncService = try PrivateAdapterSyncService(manager: manager)
            initializationError = nil
        } catch {
            syncService = nil
            initializationError = error
        }

        Task {
            await refreshAdapters()
        }
    }

    var selectedAdapter: PrivateAdapterManifest? {
        guard let selectedAdapterID else { return nil }
        return adapters.first { $0.id == selectedAdapterID }
    }

    var availableCollections: [PrivateAdapterCollectionDefinition] {
        selectedAdapter?.collections ?? []
    }

    var effectiveLimit: Int? {
        scanAll ? nil : max(1, scanLimit)
    }

    var canRun: Bool {
        selectedAdapter != nil && !selectedCollectionID.isEmpty && !isWorking
    }

    func refreshAdapters() async {
        do {
            adapters = try await manager.list()
            if let selectedAdapterID,
               adapters.contains(where: { $0.id == selectedAdapterID }) {
                ensureCollectionSelection()
            } else {
                selectedAdapterID = adapters.first?.id
                ensureCollectionSelection()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectAdapter(_ id: String?) {
        selectedAdapterID = id
        scanResult = nil
        syncResult = nil
        ensureCollectionSelection()
    }

    func createScaffold() {
        let id = newAdapterID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            errorMessage = "Enter a private adapter ID first."
            return
        }

        isWorking = true
        statusMessage = "Creating private adapter scaffold…"
        errorMessage = nil
        Task {
            do {
                let directory = try await manager.initialize(id: id)
                newAdapterID = ""
                await refreshAdapters()
                selectAdapter(id)
                statusMessage = "Private adapter created outside the Git repository: \(directory.path)"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func doctor() {
        guard let id = selectedAdapterID else { return }
        isWorking = true
        statusMessage = "Checking private adapter…"
        errorMessage = nil
        Task {
            do {
                let response = try await manager.doctor(id: id)
                statusMessage = response.message ?? (response.ok ? "Adapter is ready." : "Adapter reported a problem.")
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func preview() {
        guard let syncService,
              let id = selectedAdapterID,
              !selectedCollectionID.isEmpty else {
            errorMessage = initializationError?.localizedDescription ?? "Select an adapter and collection first."
            return
        }

        let collection = selectedCollectionID
        let browser = browser
        let limit = effectiveLimit
        isWorking = true
        statusMessage = "Reading private collection…"
        errorMessage = nil
        syncResult = nil
        Task {
            do {
                let result = try await syncService.scan(
                    adapterID: id,
                    collection: collection,
                    browser: browser,
                    limit: limit
                )
                scanResult = result
                statusMessage = "Found \(result.items.count) items; \(result.unarchivedCount) are not archived."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func sync() {
        guard let syncService,
              let id = selectedAdapterID,
              !selectedCollectionID.isEmpty else {
            errorMessage = initializationError?.localizedDescription ?? "Select an adapter and collection first."
            return
        }

        let collection = selectedCollectionID
        let browser = browser
        let limit = effectiveLimit
        let outputDirectory = outputDirectory
        isWorking = true
        statusMessage = "Synchronizing private collection…"
        errorMessage = nil
        Task {
            do {
                let result = try await syncService.sync(
                    adapterID: id,
                    collection: collection,
                    browser: browser,
                    outputDirectory: outputDirectory,
                    limit: limit
                )
                syncResult = result
                scanResult = try await syncService.scan(
                    adapterID: id,
                    collection: collection,
                    browser: browser,
                    limit: limit
                )
                statusMessage = "Downloaded \(result.downloaded), skipped \(result.skippedAlreadyArchived), failed \(result.failed)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
            isWorking = false
        }
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        var preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        preferences.outputDirectoryPath = url.path
        do {
            try ClipBoxPreferencesStore.save(preferences)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedDirectoryURL() async -> URL? {
        guard let id = selectedAdapterID else { return nil }
        return try? await manager.directory(id: id)
    }

    private func ensureCollectionSelection() {
        let collections = availableCollections
        if collections.contains(where: { $0.id == selectedCollectionID }) {
            return
        }
        selectedCollectionID = collections.first?.id ?? ""
    }
}

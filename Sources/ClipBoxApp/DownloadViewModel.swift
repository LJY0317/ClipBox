import ClipBoxCore
import Combine
import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var sourceURL = "" {
        didSet {
            guard sourceURL != oldValue else { return }
            clearInspection()
        }
    }
    @Published var outputDirectory: URL
    @Published var browserCookieSource: BrowserCookieSource? {
        didSet {
            guard browserCookieSource != oldValue else { return }
            clearInspection()
        }
    }
    @Published var inspection: LinkInspection?
    @Published var selectedAssetIDs = Set<String>()
    @Published var dependencies: ClipBoxDependencyStatus?
    @Published var archiveCount = 0
    @Published var recentHistory: [ArchiveRecord] = []
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let service: ClipBoxService?
    private let initializationError: Error?

    init() {
        let preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        outputDirectory = preferences.resolvedOutputDirectory
        browserCookieSource = nil

        do {
            service = try ClipBoxService()
            initializationError = nil
        } catch {
            service = nil
            initializationError = error
        }

        Task { await refreshStatus() }
    }

    var assets: [LinkDownloadAsset] { inspection?.assets ?? [] }

    var selectedAssets: [LinkDownloadAsset] {
        assets.filter { selectedAssetIDs.contains($0.id) && !$0.alreadyDownloaded }
    }

    var usesGalleryPostResolver: Bool {
        GalleryDlClient.supportsPostURL(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var requiredDownloadComponentAvailable: Bool {
        if usesGalleryPostResolver {
            return dependencies?.galleryDl.isAvailable == true
        }
        return dependencies?.ytDlp.isAvailable == true
    }

    var canAnalyze: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isWorking
            && requiredDownloadComponentAvailable
    }

    var canDownload: Bool {
        guard canAnalyze else { return false }
        if inspection == nil { return true }
        return !selectedAssets.isEmpty
    }

    var selectedCount: Int { selectedAssets.count }

    var selectableCount: Int { assets.lazy.filter { !$0.alreadyDownloaded }.count }

    var allSelectableAssetsSelected: Bool {
        selectableCount > 0 && selectedCount == selectableCount
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        var preferences = (try? ClipBoxPreferencesStore.load()) ?? ClipBoxPreferences()
        preferences.outputDirectoryPath = url.path
        do {
            try ClipBoxPreferencesStore.save(preferences)
            errorMessage = nil
        } catch {
            errorMessage = AppLanguageStore.shared.text(
                "저장 위치를 기억하지 못했습니다. 이번 다운로드에는 선택한 폴더를 계속 사용할 수 있습니다.",
                "ClipBox couldn't remember this folder, but you can still use it for this download."
            )
        }
    }

    func analyze() {
        guard !isWorking else { return }
        Task { _ = await inspectLink(startedFromDownload: false) }
    }

    func download() {
        guard !isWorking else { return }
        Task {
            if inspection == nil {
                guard let result = await inspectLink(startedFromDownload: true) else { return }
                if result.assets.count > 1 {
                    statusMessage = AppLanguageStore.shared.text(
                        "저장할 항목을 골라 주세요.",
                        "Choose what you want to save."
                    )
                    return
                }
            }
            await downloadSelected()
        }
    }

    func setSelected(_ asset: LinkDownloadAsset, selected: Bool) {
        guard !asset.alreadyDownloaded else { return }
        if selected {
            selectedAssetIDs.insert(asset.id)
        } else {
            selectedAssetIDs.remove(asset.id)
        }
    }

    func selectAll() {
        selectedAssetIDs = Set(assets.lazy.filter { !$0.alreadyDownloaded }.map(\.id))
    }

    func selectNone() {
        selectedAssetIDs.removeAll()
    }

    private func inspectLink(startedFromDownload: Bool) async -> LinkInspection? {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? AppLanguageStore.shared.text(
                "지금은 다운로드 기능을 사용할 수 없습니다.",
                "Downloads aren't available right now."
            )
            return nil
        }

        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserCookieSource = browserCookieSource
        guard !url.isEmpty else { return nil }

        isWorking = true
        errorMessage = nil
        statusMessage = AppLanguageStore.shared.text(
            "링크에서 저장할 항목을 찾는 중…",
            "Finding downloadable items…"
        )

        defer { isWorking = false }
        do {
            let result = try await service.inspectLink(
                url: url,
                cookiesFromBrowser: browserCookieSource
            )
            inspection = result
            selectedAssetIDs = Set(result.assets.lazy.filter { !$0.alreadyDownloaded }.map(\.id))
            let newCount = result.assets.lazy.filter { !$0.alreadyDownloaded }.count
            let savedCount = result.assets.count - newCount

            if result.assets.count == 1 {
                if savedCount == 1 {
                    statusMessage = AppLanguageStore.shared.text(
                        "이미 저장한 항목입니다.",
                        "You've already saved this item."
                    )
                } else if !startedFromDownload {
                    statusMessage = AppLanguageStore.shared.text(
                        "저장할 항목 1개를 찾았습니다.",
                        "Found 1 item to save."
                    )
                }
            } else {
                statusMessage = savedCount > 0
                    ? AppLanguageStore.shared.text(
                        "항목 \(result.assets.count)개를 찾았습니다. 그중 \(savedCount)개는 이미 저장되어 있습니다.",
                        "Found \(result.assets.count) items. \(savedCount) already saved."
                    )
                    : AppLanguageStore.shared.text(
                        "항목 \(result.assets.count)개를 찾았습니다. 저장할 항목을 골라 주세요.",
                        "Found \(result.assets.count) items. Choose what you want to save."
                    )
            }
            return result
        } catch {
            errorMessage = friendlyError(error)
            statusMessage = ""
            return nil
        }
    }

    private func downloadSelected() async {
        guard let service else { return }
        let chosen = selectedAssets
        guard !chosen.isEmpty else {
            if assets.allSatisfy(\.alreadyDownloaded), !assets.isEmpty {
                statusMessage = AppLanguageStore.shared.text(
                    "이 링크의 항목은 모두 이미 저장되어 있습니다.",
                    "Everything in this link is already saved."
                )
            }
            return
        }

        let browserCookieSource = browserCookieSource
        isWorking = true
        errorMessage = nil
        var downloaded = 0
        var skipped = 0
        var failures: [String] = []
        var completedIDs = Set<String>()

        for (index, asset) in chosen.enumerated() {
            statusMessage = chosen.count == 1
                ? AppLanguageStore.shared.text("다운로드 중…", "Downloading…")
                : AppLanguageStore.shared.text(
                    "\(chosen.count)개 중 \(index + 1)번째를 다운로드하는 중…",
                    "Downloading item \(index + 1) of \(chosen.count)…"
                )
            do {
                let outcome = try await service.download(
                    asset: asset,
                    outputDirectory: outputDirectory,
                    cookiesFromBrowser: browserCookieSource
                )
                switch outcome {
                case .downloaded:
                    downloaded += 1
                    completedIDs.insert(asset.id)
                case .skippedAlreadyArchived:
                    skipped += 1
                    completedIDs.insert(asset.id)
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append(friendlyError(error))
            }
        }

        isWorking = false
        if let current = inspection {
            let refreshed = current.assets.map { asset in
                if completedIDs.contains(asset.id) {
                    var copy = asset
                    copy.alreadyDownloaded = true
                    return copy
                }
                return asset
            }
            inspection = LinkInspection(sourceURL: current.sourceURL, assets: refreshed)
            selectedAssetIDs.subtract(refreshed.lazy.filter(\.alreadyDownloaded).map(\.id))
        }
        await refreshHistory()

        if failures.isEmpty {
            if downloaded == 1 && chosen.count == 1 {
                statusMessage = AppLanguageStore.shared.text(
                    "다운로드를 마쳤습니다.",
                    "Download complete."
                )
            } else {
                statusMessage = AppLanguageStore.shared.text(
                    "\(downloaded)개를 저장했습니다\(skipped > 0 ? ", 이미 저장한 \(skipped)개는 건너뛰었습니다" : "").",
                    "Saved \(downloaded) item(s)\(skipped > 0 ? "; skipped \(skipped) already saved" : "")."
                )
            }
        } else {
            errorMessage = AppLanguageStore.shared.text(
                "일부 항목을 저장하지 못했습니다. \(failures.first ?? "다시 시도해 주세요.")",
                "Some items couldn't be saved. \(failures.first ?? "Please try again.")"
            )
            statusMessage = downloaded > 0
                ? AppLanguageStore.shared.text("\(downloaded)개는 저장했습니다.", "Saved \(downloaded) item(s).")
                : ""
        }
    }

    func refreshStatus() async {
        guard let service else {
            errorMessage = initializationError?.localizedDescription ?? AppLanguageStore.shared.text(
                "지금은 다운로드 기능을 사용할 수 없습니다.",
                "Downloads aren't available right now."
            )
            return
        }

        dependencies = await service.dependencyStatus()
        await refreshHistory()
    }

    func refreshHistory() async {
        guard let service else { return }
        do {
            async let count = service.historyCount()
            async let history = service.recentHistory(limit: 50)
            archiveCount = try await count
            recentHistory = try await history
        } catch {
            errorMessage = AppLanguageStore.shared.text(
                "다운로드 기록을 불러오지 못했습니다.",
                "Couldn't load download history."
            )
        }
    }

    private func clearInspection() {
        inspection = nil
        selectedAssetIDs.removeAll()
        statusMessage = ""
        errorMessage = nil
    }

    private func friendlyError(_ error: Error) -> String {
        if let galleryError = error as? GalleryDlError {
            switch galleryError {
            case .unavailable:
                return AppLanguageStore.shared.text(
                    "X나 Instagram 게시물을 읽는 데 필요한 다운로드 구성 요소가 없습니다.",
                    "A download component needed for X and Instagram posts is missing."
                )
            case .authenticationRequired(let browser):
                return AppLanguageStore.shared.text(
                    "\(browser.displayName)에서 이 사이트에 로그인한 뒤 다시 시도해 주세요.",
                    "Sign in to this site in \(browser.displayName), then try again."
                )
            case .sessionExpired:
                return AppLanguageStore.shared.text(
                    "브라우저의 로그인 시간이 만료되었습니다. 사이트에 다시 로그인한 뒤 시도해 주세요.",
                    "Your browser sign-in has expired. Sign in to the site again, then try again."
                )
            case .securityChallenge:
                return AppLanguageStore.shared.text(
                    "사이트에서 추가 확인을 요청했습니다. 브라우저에서 확인을 마친 뒤 다시 시도해 주세요.",
                    "The site needs an extra security check. Complete it in your browser, then try again."
                )
            case .rateLimited:
                return AppLanguageStore.shared.text(
                    "사이트가 잠시 요청을 제한하고 있습니다. 잠시 후 다시 시도해 주세요.",
                    "The site is temporarily limiting requests. Try again a little later."
                )
            case .accessDenied:
                return AppLanguageStore.shared.text(
                    "이 항목에 접근할 수 없습니다. 게시물이 비공개이거나 삭제되었는지, 선택한 브라우저에 로그인되어 있는지 확인해 주세요.",
                    "ClipBox can't access this item. Check whether the post is private or removed and whether you're signed in with the selected browser."
                )
            case .browserCookieAccessFailed(let browser, _):
                return AppLanguageStore.shared.text(
                    "ClipBox가 \(browser.displayName)의 로그인 정보를 읽을 수 없습니다. macOS 개인정보 보호 권한을 확인한 뒤 다시 시도해 주세요.",
                    "ClipBox can't read the sign-in from \(browser.displayName). Check macOS privacy permissions, then try again."
                )
            case .unsupportedSession:
                return AppLanguageStore.shared.text(
                    "이 브라우저 로그인 방식은 현재 사용할 수 없습니다. 다른 브라우저를 선택해 주세요.",
                    "This browser sign-in method isn't available here. Choose another browser."
                )
            case .scanFailed, .malformedOutput, .unsupportedCollection, .missingAccountName:
                return AppLanguageStore.shared.text(
                    "이 링크에서 저장할 사진이나 동영상을 불러오지 못했습니다. 링크와 로그인 상태를 확인한 뒤 다시 시도해 주세요.",
                    "ClipBox couldn't load photos or videos from this link. Check the link and your sign-in, then try again."
                )
            }
        }
        if error is YtDlpError {
            return AppLanguageStore.shared.text(
                "이 링크에서 다운로드할 항목을 찾지 못했습니다. 링크를 확인하거나 로그인된 브라우저를 선택해 다시 시도해 주세요.",
                "ClipBox couldn't find anything to download from this link. Check the link or choose a signed-in browser and try again."
            )
        }
        return error.localizedDescription
    }
}

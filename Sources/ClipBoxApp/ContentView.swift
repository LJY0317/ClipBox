import AppKit
import ClipBoxCore
import SwiftUI

@MainActor
private final class CollectionThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    private var task: Task<Void, Never>?
    private static let cache = NSCache<NSURL, NSImage>()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    func load(_ url: URL?) {
        task?.cancel()
        image = nil
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        task = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
                let (data, response) = try await Self.session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count <= 5 * 1024 * 1024,
                      let image = NSImage(data: data) else { return }
                Self.cache.setObject(image, forKey: url as NSURL)
                self?.image = image
            } catch { }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

private struct CollectionThumbnailView: View {
    let url: URL?
    @StateObject private var loader = CollectionThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: url) { loader.load(url) }
        .onDisappear { loader.cancel() }
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable {
    case download
    case collections
    case privateAdapters
    case history

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .collections: "rectangle.stack"
        case .privateAdapters: "puzzlepiece.extension"
        case .history: "clock.arrow.circlepath"
        }
    }

    @MainActor
    func title(_ language: AppLanguageStore) -> String {
        switch self {
        case .download: language.text("다운로드", "Download")
        case .collections: language.text("모음", "Collections")
        case .privateAdapters: language.text("개인 사이트", "Private Sites")
        case .history: language.text("기록", "History")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var language: AppLanguageStore
    @StateObject private var model = DownloadViewModel()
    @StateObject private var collectionModel = CollectionViewModel()
    @StateObject private var privateAdapterModel = PrivateAdapterViewModel()
    @State private var selection: SidebarSection? = .download

    private func observationRow(_ item: CollectionObservation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("#\(item.position)").monospacedDigit().foregroundStyle(.secondary)
            if collectionModel.thumbnailURL(for: item) != nil {
                CollectionThumbnailView(url: collectionModel.thumbnailURL(for: item))
            } else {
                Image(systemName: item.type.systemImage)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let creator = collectionModel.creatorHandle(for: item), !creator.isEmpty {
                    Text("@\(creator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.title ?? language.text("제목 없음", "Untitled")).lineLimit(2)
                Text(language.text(
                    "게시: \(item.publishedAt ?? "알 수 없음")",
                    "Published: \(item.publishedAt ?? "Unknown")"
                ))
                    .font(.caption).foregroundStyle(.secondary)
                if let date = item.bookmarkedAt {
                    Text(language.text("북마크: \(date)", "Bookmarked: \(date)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = URL(string: item.sourceURL), url.scheme == "https" {
                    Link(language.text("원문 열기", "Open original"), destination: url).font(.caption)
                }
            }
            Spacer()
            Text(item.downloaded ? language.text("저장됨", "Archived") : language.text("미저장", "Not saved"))
                .font(.caption)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title(language), systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("ClipBox")
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 240)
        } detail: {
            switch selection ?? .download {
            case .download:
                downloadView
            case .collections:
                collectionsView
            case .privateAdapters:
                privateAdaptersView
            case .history:
                historyView
            }
        }
    }

    private var downloadView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("미디어 다운로드", "Download media"))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(language.text(
                        "링크를 붙여넣으면 ClipBox가 저장할 수 있는 가장 좋은 품질을 확인하고 다운로드합니다.",
                        "Paste a link to inspect the available media and download the best quality ClipBox can retrieve."
                    ))
                        .foregroundStyle(.secondary)
                }

                dependencyBanner

                GroupBox(language.text("다운로드할 항목", "Source")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(language.text("미디어 주소", "Media URL"), text: $model.sourceURL)
                            .textFieldStyle(.roundedBorder)

                        Picker(language.text("로그인된 브라우저", "Browser login"), selection: $model.browserCookieSource) {
                            Text(language.text("사용 안 함 (공개 링크)", "None (public URL)"))
                                .tag(Optional<BrowserCookieSource>.none)
                            ForEach(BrowserCookieSource.allCases, id: \.self) { browser in
                                Text(browser.displayName)
                                    .tag(Optional(browser))
                            }
                        }

                        LabeledContent(language.text("저장 위치", "Save to")) {
                            HStack(spacing: 10) {
                                Text(model.outputDirectory.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)

                                Button(language.text("변경…", "Choose…")) {
                                    chooseOutputDirectory()
                                }
                            }
                        }

                        HStack {
                            Button(language.text("정보 확인", "Analyze")) {
                                model.analyze()
                            }
                            .disabled(!model.canAnalyze)

                            Spacer()

                            if model.isWorking {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button(language.text("최고 품질로 다운로드", "Download Best Quality")) {
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
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(language.text("다운로드", "Download"))
    }

    @ViewBuilder
    private var dependencyBanner: some View {
        if let dependencies = model.dependencies {
            if !dependencies.ytDlp.isAvailable {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(language.text("다운로드 구성 요소가 필요합니다", "A download component is required"), systemImage: "wrench.and.screwdriver")
                            .fontWeight(.semibold)
                        Text(language.text(
                            "현재 개발 버전에서는 yt-dlp가 필요합니다. Homebrew를 사용한다면 `brew install yt-dlp`로 설치할 수 있습니다.",
                            "This development build requires yt-dlp. If you use Homebrew, install it with `brew install yt-dlp`."
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            } else if !dependencies.ffmpeg.isAvailable {
                Label(language.text(
                    "ffmpeg가 없어 일부 고화질 형식을 합칠 수 없습니다.",
                    "ffmpeg is missing. Some high-quality formats cannot be merged without it."
                ), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func mediaSummary(_ media: MediaMetadata) -> some View {
        GroupBox(language.text("미디어 정보", "Media")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(media.title ?? language.text("제목 없음", "Untitled"))
                    .font(.headline)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text(language.text("서비스", "Source")).foregroundStyle(.secondary)
                        Text(media.site)
                    }
                    GridRow {
                        Text(language.text("미디어 ID", "Media ID")).foregroundStyle(.secondary)
                        Text(media.mediaID).textSelection(.enabled)
                    }
                    GridRow {
                        Text(language.text("최대 해상도", "Best reported size")).foregroundStyle(.secondary)
                        Text(resolution(media))
                    }
                    GridRow {
                        Text(language.text("사용 가능한 형식", "Formats")).foregroundStyle(.secondary)
                        Text("\(media.formats.count)")
                    }
                }

                if !media.formats.isEmpty {
                    Divider()
                    Text(language.text("주요 형식", "Top available formats"))
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
                    Text(language.text("다운로드 기록", "Download history"))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(language.text(
                        "지금까지 \(model.archiveCount)개를 기억하고 있습니다. 파일을 옮기거나 지워도 다운로드했던 기록은 남습니다.",
                        "ClipBox remembers \(model.archiveCount) archived items. Moving or deleting a file doesn't remove its download history."
                    ))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(language.text("새로고침", "Refresh")) {
                    Task { await model.refreshHistory() }
                }
            }

            if model.recentHistory.isEmpty {
                ContentUnavailableView(
                    language.text("아직 기록이 없습니다", "No History Yet"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(language.text("다운로드한 항목이 여기에 표시됩니다.", "Downloaded items will appear here."))
                )
            } else {
                List {
                    ForEach(model.recentHistory) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.title ?? language.text("제목 없음", "Untitled"))
                                    .fontWeight(.medium)
                                Spacer()
                                if record.status == .downloaded {
                                    Text(historyStatus(record.status))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(historyStatus(record.status))
                                        .foregroundStyle(.orange)
                                }
                            }

                            HStack(spacing: 10) {
                                if let creator = record.creator, !creator.isEmpty {
                                    Text(creator.hasPrefix("@") ? creator : "@\(creator)")
                                }
                                if let downloaded = historyDate(record.downloadedAt) {
                                    Text(downloaded)
                                }
                                if let sourceURL = record.sourceURL,
                                   let url = URL(string: sourceURL),
                                   url.scheme == "https" {
                                    Link(language.text("원문 열기", "Open Original"), destination: url)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            DisclosureGroup(language.text("세부 정보", "Details")) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(language.text("서비스: \(record.site)", "Service: \(record.site)"))
                                    Text(language.text("미디어 ID: \(record.mediaID)", "Media ID: \(record.mediaID)"))
                                        .textSelection(.enabled)
                                    if let outputPath = record.outputPath {
                                        Text(language.text("파일 위치: \(outputPath)", "File: \(outputPath)"))
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .padding(28)
        .navigationTitle(language.text("기록", "History"))
    }

    @ViewBuilder
    private var sessionButtons: some View {
        Button(language.text("브라우저에서 X 열기", "Open X in browser")) { collectionModel.openXLogin() }
        Button(language.text("연결 확인", "Test connection")) { collectionModel.testSessions() }
        Button(language.text("프로필 새로고침", "Refresh profiles")) { collectionModel.refreshSessions() }
        Button(language.text("연결 정보 지우기", "Forget")) { collectionModel.forgetConnection() }
    }

    private var collectionActions: some View {
        HStack {
            Button(language.text("미리보기", "Preview")) {
                collectionModel.preview()
            }
            .disabled(!collectionModel.canRun)

            Spacer()

            if collectionModel.isWorking {
                ProgressView().controlSize(.small)
                Button(language.text("중지", "Stop")) { collectionModel.cancel() }
            }

            Button(language.text("새 항목 다운로드", "Download New Items")) {
                collectionModel.sync()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!collectionModel.canRun)
        }

    }

    private var collectionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("저장한 미디어 가져오기", "Import saved media"))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(language.text("X나 YouTube에 저장해 둔 항목을 미리 보고, ClipBox에 아직 없는 미디어만 다운로드합니다.", "Preview items you've saved on X or YouTube, then download only media that isn't already in ClipBox."))
                        .foregroundStyle(.secondary)
                }

                GroupBox(language.text("가져올 모음", "Collection")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(language.text("서비스", "Source"), selection: collectionSourceBinding) {
                            ForEach(CollectionSourceMode.allCases) { source in
                                Text(collectionSourceName(source)).tag(source)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Picker(language.text("로그인된 브라우저", "Browser session"), selection: Binding(get: { collectionModel.browser }, set: { collectionModel.setBrowser($0) })) {
                                ForEach(BrowserCookieSource.allCases, id: \.self) { browser in
                                    Text(browser.displayName).tag(browser)
                                }
                            }
                            if collectionModel.isXMode {
                                Group {
                                    Picker(language.text("프로필", "Profile"), selection: Binding(
                                        get: { collectionModel.browserProfile },
                                        set: { collectionModel.setBrowserProfile($0) }
                                    )) {
                                        Text(collectionModel.browser == .safari ? language.text("자동 (기본 Safari 프로필)", "Automatic (default Safari profile)") : language.text("자동 (최근 사용)", "Automatic (most recently used)")).tag("")
                                        ForEach(collectionModel.profilesForBrowser) { session in
                                            Text(collectionModel.profileLabel(session)).tag(session.profile ?? "")
                                        }
                                        if !collectionModel.browserProfile.isEmpty,
                                           !collectionModel.profilesForBrowser.contains(where: { $0.profile == collectionModel.browserProfile }) {
                                            Text(language.text("저장된 사용자 지정 프로필", "Saved / custom profile")).tag(collectionModel.browserProfile)
                                        }
                                    }
                                    DisclosureGroup(language.text("고급 프로필 설정", "Advanced profile settings")) {
                                        if collectionModel.browser == .safari {
                                            Text(language.text(
                                                "Safari 저장소 위치는 선택한 프로필에서 자동으로 관리됩니다. 직접 경로를 지정해야 할 때만 아래 항목을 사용하세요.",
                                                "Safari storage is managed automatically from the selected profile. Use the manual path only when needed."
                                            ))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            DisclosureGroup(language.text("저장소 경로 직접 입력", "Enter Storage Path Manually")) {
                                                TextField(language.text("Safari 저장소 경로", "Safari storage path"), text: Binding(
                                                    get: { collectionModel.browserProfile },
                                                    set: { collectionModel.setBrowserProfile($0) }
                                                ))
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.caption.monospaced())
                                            }
                                        } else {
                                            TextField(language.text("프로필 경로 또는 이름", "Profile directory or name"), text: Binding(
                                                get: { collectionModel.browserProfile },
                                                set: { collectionModel.setBrowserProfile($0) }
                                            ))
                                                .textFieldStyle(.roundedBorder)
                                            if collectionModel.browser == .firefox {
                                                TextField(language.text("Firefox 컨테이너 (선택 사항)", "Firefox container (optional)"), text: Binding(
                                                    get: { collectionModel.browserContainer },
                                                    set: { collectionModel.setBrowserContainer($0) }
                                                ))
                                                    .textFieldStyle(.roundedBorder)
                                            }
                                        }
                                    }
                                }
                                if collectionModel.browser == .safari {
                                    Text(language.text("X에 로그인한 Safari 프로필을 선택한 뒤 ‘연결 확인’을 눌러 주세요. 프로필 이름을 확인할 수 없는 경우에도 저장소 자체는 선택할 수 있습니다.", "Choose the Safari profile where you're signed in to X, then use Test connection. Stores without a confirmed profile name remain selectable."))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(collectionModel.discoveryIssues.filter { $0.browser == collectionModel.browser }) { issue in
                                    Label(discoveryIssueMessage(issue), systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack { sessionButtons }
                                    VStack(alignment: .leading) { sessionButtons }
                                }
                                ForEach(collectionModel.sessionChecks) { check in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Label(collectionModel.profileLabel(check.session), systemImage: check.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                                            if check.connected {
                                                Button(language.text("사용", "Use")) { collectionModel.useSession(check.session) }
                                            }
                                        }
                                        Text(sessionCheckMessage(check)).font(.caption).foregroundStyle(.secondary)
                                        if let identity = check.identity {
                                            HStack(spacing: 6) {
                                                Text(language.text("X 계정:", "X account:")).font(.caption).foregroundStyle(.secondary)
                                                Text(identity.handle.map { "@\($0)" } ?? language.text("계정 확인됨", "Account verified"))
                                                    .font(.caption).fontWeight(.medium)
                                                Text(identity.evidence == .serverVerified ? language.text("확인 완료", "Verified") : language.text("브라우저 정보만 확인", "Browser claim only"))
                                                    .font(.caption2).foregroundStyle(identity.evidence == .serverVerified ? .green : .orange)
                                            }
                                        }
                                        Text(language.text("확인: \(check.checkedAt.formatted(date: .abbreviated, time: .standard))", "Checked \(check.checkedAt.formatted(date: .abbreviated, time: .standard))"))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(language.text("미디어 종류", "Media types")).font(.subheadline).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading) {
                                ForEach(MediaAssetType.allCases) { type in
                                    Toggle(mediaTypeName(type), isOn: mediaTypeBinding(type))
                                        .toggleStyle(.checkbox).fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }

                        if collectionModel.isXMode {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(language.text("X에서 가져올 목록", "X collections")).font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 20) {
                                    Toggle(language.text("좋아요", "Likes"), isOn: xCollectionBinding(.xLikes)).toggleStyle(.checkbox)
                                    Toggle(language.text("북마크", "Bookmarks"), isOn: xCollectionBinding(.xBookmarks)).toggleStyle(.checkbox)
                                }
                                Text(language.text(
                                    "같은 미디어는 한 번만 저장하고, 좋아요와 북마크에 포함됐던 기록은 각각 기억합니다.",
                                    "Each media item is stored once while Likes and Bookmarks membership is remembered separately."
                                ))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if collectionModel.requiresXAccountName {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(language.text("X 사용자 이름", "Your X username"))
                                HStack(spacing: 4) {
                                    Text("@").foregroundStyle(.secondary)
                                    TextField(language.text("사용자 이름", "username"), text: xHandleBinding).textFieldStyle(.roundedBorder)
                                }.frame(maxWidth: 360)
                                Text(language.text("선택한 브라우저 프로필에서 로그인한 X 계정과 같아야 합니다.", "Use the same X account signed in to the selected browser profile."))
                                    .font(.caption).foregroundStyle(.secondary)
                                Toggle(language.text("이 Mac에 사용자 이름 기억하기", "Remember username on this Mac"), isOn: $collectionModel.rememberAccount).toggleStyle(.checkbox)
                            }
                        }

                        Toggle(language.text("전체 기록 확인", "Scan all available history"), isOn: $collectionModel.scanAll)
                        if collectionModel.scanAll {
                            Text(language.text("처음 가져오거나 누락 여부를 점검할 때 사용하세요. 시간이 오래 걸릴 수 있습니다.", "Use this for the first import or an occasional completeness check. It can take a while."))
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if !collectionModel.scanAll && collectionModel.isXMode {
                            Text(language.text(
                                "미리보기는 한 번에 한 묶음씩 가져옵니다. 더 보고 싶을 때만 다음 항목을 불러오며, 다운로드할 때는 이미 확인한 항목을 다시 조회하지 않습니다.",
                                "Preview loads one batch at a time. Load more only when needed; downloading reuses the items already loaded in this preview."
                            ))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !collectionModel.scanAll {
                            ScanLimitControl(value: $collectionModel.scanLimit)
                        }

                        LabeledContent(language.text("저장 위치", "Save to")) {
                            HStack(spacing: 10) {
                                Text(collectionModel.outputDirectory.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button(language.text("변경…", "Choose…")) {
                                    chooseCollectionOutputDirectory()
                                }
                            }
                        }
                    }
                    .padding(6)
                    .disabled(collectionModel.isWorking)
                }

                Text(language.text("ClipBox는 선택한 브라우저의 로그인 상태를 사용하지만 쿠키나 세션 토큰을 별도로 저장하지 않습니다.", "ClipBox uses the selected browser login without exporting cookies or storing session tokens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(language.text("전체 기록 확인은 처음 가져오거나 가끔 누락 여부를 점검할 때만 권장합니다.", "A full history scan is best reserved for the first import or an occasional completeness check."))
                    .font(.caption)
                    .foregroundStyle(.secondary)


                if collectionModel.isXMode && !collectionModel.hasSelectedCollections {
                    Label(language.text("좋아요나 북마크를 하나 이상 선택해 주세요.", "Select Likes, Bookmarks, or both."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !collectionModel.hasSelectedMediaTypes {
                    Label(language.text("미디어 종류를 하나 이상 선택해 주세요.", "Select at least one media type."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !collectionModel.hasRequiredXAccountName {
                    Label(language.text("좋아요를 가져오려면 X 사용자 이름을 입력해 주세요.", "Enter the X username to import Likes."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let scanResult = collectionModel.scanResult {
                    GroupBox(language.text("미리보기", "Preview")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(language.text(
                                "미디어 \(scanResult.uniqueMediaCount)개 · 새 항목 \(scanResult.unarchivedCount)개",
                                "\(scanResult.uniqueMediaCount) media · \(scanResult.unarchivedCount) new"
                            ))
                                .font(.headline)

                            ForEach(scanResult.collections) { collection in
                                Text(language.text("\(collectionName(collection)): \(scanResult.items.filter { $0.collections.contains(collection) }.count)개", "\(collectionName(collection)): \(scanResult.items.filter { $0.collections.contains(collection) }.count) media"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            if let comparison = collectionModel.comparison {
                                Text(language.text("확인: \(comparison.current.capturedAt.formatted())", "Scanned \(comparison.current.capturedAt.formatted())"))
                                    .font(.caption)
                                Text(language.text(
                                    "이 비교는 현재 브라우저 프로필과 조회 설정을 기준으로 합니다. 목록에서 보이지 않았다고 삭제된 것으로 판단하지 않습니다.",
                                    "This comparison uses the current browser profile and scan settings. An item not returned this time is not treated as deleted."
                                ))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let previousDate = comparison.previousDate {
                                    Text(language.text(
                                        "이전 확인 \(previousDate.formatted()): 새로 보인 항목 \(comparison.added)개 · 이번에는 보이지 않은 항목 \(comparison.notReturned.count)개",
                                        "Compared with \(previousDate.formatted()): \(comparison.added) newly found · \(comparison.notReturned.count) not returned this time"
                                    ))
                                        .font(.caption)
                                }
                                DisclosureGroup(language.text("조회 세부 정보", "Scan details")) {
                                    if scanResult.duplicateOccurrencesCollapsed > 0 {
                                        Text(language.text(
                                            "여러 목록에 겹쳐 있던 항목 \(scanResult.duplicateOccurrencesCollapsed)개를 한 번만 표시했습니다.",
                                            "Merged \(scanResult.duplicateOccurrencesCollapsed) overlapping collection entries."
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(comparison.current.diagnostics, id: \.collection) { diagnostic in
                                        Text("\(diagnostic.collection): \(diagnostic.pages) page responses · \(diagnostic.entries) entries · \(diagnostic.stopDescription)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if comparison.current.diagnostics.isEmpty {
                                        Text(language.text("이 환경에서는 페이지별 세부 정보를 확인할 수 없습니다.", "Page diagnostics are unavailable in this environment."))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                DisclosureGroup(language.text("게시물 확인", "Check a post")) {
                                    TextField(language.text("X 게시물 주소 붙여넣기", "Paste an X post URL"), text: $collectionModel.comparisonPostURL)
                                        .textFieldStyle(.roundedBorder)
                                    if let message = collectionModel.postComparisonMessage {
                                        Text(message).font(.caption).textSelection(.enabled)
                                    }
                                }
                                Picker(language.text("목록", "Collection"), selection: $collectionModel.previewCollection) {
                                    ForEach(scanResult.collections) { collection in
                                        Text(collectionName(collection)).tag(collection)
                                    }
                                }
                                Text(language.text(
                                    "X에서 보여 준 순서를 그대로 따릅니다. 게시 날짜순이 아닙니다.",
                                    "This follows the order returned by X; it is not publication-date order."
                                ))
                                    .font(.caption).foregroundStyle(.secondary)
                                if collectionModel.isPagedXPreview {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(collectionModel.observedRows) { item in observationRow(item) }
                                    }
                                    if collectionModel.currentPreviewHasMore {
                                        Button(language.text("다음 항목 불러오기", "Load More")) {
                                            collectionModel.loadNextXPreviewPage()
                                        }
                                        .disabled(collectionModel.isWorking)
                                    } else {
                                        Text(language.text("끝까지 불러왔습니다.", "Reached the end."))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(language.text(
                                        "현재 \(collectionModel.currentPreviewPageResponses)페이지 · 미디어 \(collectionModel.observedRows.count)개 · \(collectionModel.currentPreviewHasMore ? "더 불러올 수 있음" : "끝까지 확인함")",
                                        "\(collectionModel.currentPreviewPageResponses) page(s) · \(collectionModel.observedRows.count) media · \(collectionModel.currentPreviewHasMore ? "more available" : "reached the end")"
                                    ))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(collectionModel.observedRows.prefix(collectionModel.previewRowLimit)) { item in
                                            observationRow(item)
                                        }
                                    }
                                    if collectionModel.observedRows.count > collectionModel.previewRowLimit {
                                        Button(language.text("다음 50개 보기", "Show Next 50")) { collectionModel.previewRowLimit += 50 }
                                    }
                                    Text(language.text(
                                        "이 목록의 미디어 \(collectionModel.observedRows.count)개 중 \(min(collectionModel.previewRowLimit, collectionModel.observedRows.count))개 표시 중입니다. 다운로드는 확인한 전체 항목을 대상으로 합니다.",
                                        "Showing \(min(collectionModel.previewRowLimit, collectionModel.observedRows.count)) of \(collectionModel.observedRows.count) media. Downloads include all discovered rows."
                                    ))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if !comparison.notReturned.isEmpty {
                                    DisclosureGroup(language.text("이번에는 보이지 않은 항목 (최대 50개)", "Not Returned This Time (up to 50)")) {
                                        ForEach(comparison.notReturned.prefix(50)) { item in observationRow(item) }
                                    }
                                }
                            }
                            if let warning = collectionModel.snapshotWarning {
                                Text(warning).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                if let syncResult = collectionModel.syncResult {
                    GroupBox(language.text("마지막 다운로드", "Last Download")) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow { Text(language.text("확인한 항목", "Checked items")).foregroundStyle(.secondary); Text("\(syncResult.scannedOccurrences)") }
                            GridRow { Text(language.text("미디어", "Media")).foregroundStyle(.secondary); Text("\(syncResult.uniqueMedia)") }
                            GridRow { Text(language.text("중복 정리", "Duplicates merged")).foregroundStyle(.secondary); Text("\(syncResult.duplicatesCollapsed)") }
                            GridRow { Text(language.text("새 항목", "New items")).foregroundStyle(.secondary); Text("\(syncResult.unarchived)") }
                            GridRow { Text(language.text("다운로드", "Downloaded")).foregroundStyle(.secondary); Text("\(syncResult.downloaded)") }
                            GridRow { Text(language.text("건너뜀", "Skipped")).foregroundStyle(.secondary); Text("\(syncResult.skippedAlreadyArchived)") }
                            GridRow { Text(language.text("실패", "Failed")).foregroundStyle(.secondary); Text("\(syncResult.failed)") }
                        }
                        .padding(6)
                    }
                }

                if !collectionModel.statusMessage.isEmpty,
                   collectionModel.isWorking || (collectionModel.scanResult == nil && collectionModel.syncResult == nil) {
                    Text(collectionModel.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = collectionModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom) {
            collectionActions
                .frame(maxWidth: 820)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .navigationTitle(language.text("모음", "Collections"))
    }

    private var privateAdaptersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("개인 사이트", "Private Sites"))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(language.text(
                        "기본 지원 목록에 없는 사이트를 이 Mac에서만 연결할 수 있습니다.",
                        "Connect sites that aren't built into ClipBox, only on this Mac."
                    ))
                        .foregroundStyle(.secondary)
                }

                Label(
                    language.text(
                        "여기서 만드는 연결은 이 Mac에서 실행되는 로컬 코드입니다. 신뢰할 수 있는 코드만 사용하세요.",
                        "Private-site connections run as local code on this Mac. Use only code you trust."
                    ),
                    systemImage: "exclamationmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                GroupBox(language.text("새 연결 만들기", "Create a Connection")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField(language.text("연결 ID", "connection-id"), text: $privateAdapterModel.newAdapterID)
                                .textFieldStyle(.roundedBorder)
                            Button(language.text("기본 파일 만들기", "Create Starter Files")) {
                                privateAdapterModel.createScaffold()
                            }
                            .disabled(privateAdapterModel.isWorking)
                        }
                        Text(language.text(
                            "파일은 ClipBox의 Application Support 폴더에만 만들어집니다.",
                            "Files are created only in ClipBox's Application Support folder."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                if privateAdapterModel.adapters.isEmpty {
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(language.text("아직 연결이 없습니다", "No Connections Yet"))
                                    .font(.headline)
                                Text(language.text(
                                    "위에서 연결 ID를 입력하고 기본 파일을 만든 뒤, 필요한 사이트 연결 코드를 이 Mac에서 설정하세요.",
                                    "Enter a connection ID above, create the starter files, then configure the site-specific code on this Mac."
                                ))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                } else {
                    GroupBox(language.text("연결", "Connection")) {
                        Form {
                            Picker(
                                language.text("연결", "Connection"),
                                selection: Binding(
                                    get: { privateAdapterModel.selectedAdapterID },
                                    set: { privateAdapterModel.selectAdapter($0) }
                                )
                            ) {
                                ForEach(privateAdapterModel.adapters) { adapter in
                                    Text(adapter.displayName)
                                        .tag(Optional(adapter.id))
                                }
                            }

                            Picker(language.text("모음", "Collection"), selection: $privateAdapterModel.selectedCollectionID) {
                                ForEach(privateAdapterModel.availableCollections) { collection in
                                    Text(collection.displayName).tag(collection.id)
                                }
                            }

                            Picker(language.text("로그인된 브라우저", "Browser login"), selection: $privateAdapterModel.browser) {
                                ForEach(BrowserCookieSource.allCases, id: \.self) { browser in
                                    Text(browser.displayName).tag(browser)
                                }
                            }

                            Toggle(language.text("전체 기록 확인", "Scan all available history"), isOn: $privateAdapterModel.scanAll)
                            if !privateAdapterModel.scanAll {
                                ScanLimitControl(value: $privateAdapterModel.scanLimit)
                            }

                            LabeledContent(language.text("저장 위치", "Save to")) {
                                HStack(spacing: 10) {
                                    Text(privateAdapterModel.outputDirectory.path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                    Button(language.text("변경…", "Choose…")) {
                                        choosePrivateAdapterOutputDirectory()
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }

                    HStack {
                        Button(language.text("폴더 열기", "Open Folder")) {
                            Task {
                                if let url = await privateAdapterModel.selectedDirectoryURL() {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                        Button(language.text("상태 확인", "Check Status")) {
                            privateAdapterModel.doctor()
                        }
                        Button(language.text("미리보기", "Preview")) {
                            privateAdapterModel.preview()
                        }
                        .disabled(!privateAdapterModel.canRun)

                        Spacer()
                        if privateAdapterModel.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(language.text("새 항목 다운로드", "Download New Items")) {
                            privateAdapterModel.sync()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!privateAdapterModel.canRun)
                    }

                    DisclosureGroup(language.text("고급 정보", "Advanced Information")) {
                        Text(language.text(
                            "ClipBox는 개인 사이트의 다운로드 기록을 연결 ID와 미디어 ID로 구분합니다. 실제 사이트 정보는 공개 저장소에 넣을 필요가 없습니다.",
                            "ClipBox namespaces private-site archive records by connection ID and media ID, so the public repository does not need to know which real site the connection represents."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let scanResult = privateAdapterModel.scanResult {
                        GroupBox(language.text("미리보기", "Preview")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(language.text(
                                    "확인한 항목 \(scanResult.items.count)개 · 새 항목 \(scanResult.unarchivedCount)개",
                                    "\(scanResult.items.count) checked · \(scanResult.unarchivedCount) new"
                                ))
                                    .font(.headline)
                                ForEach(scanResult.items.prefix(50)) { item in
                                    HStack(spacing: 8) {
                                        Image(systemName: item.alreadyDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                            .foregroundStyle(item.alreadyDownloaded ? .secondary : .primary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.item.title ?? language.text("제목 없음", "Untitled"))
                                                .lineLimit(1)
                                            Text(item.item.mediaID)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        Spacer()
                                        Text(item.alreadyDownloaded
                                            ? language.text("저장됨", "Archived")
                                            : (item.previouslySeen ? language.text("확인함", "Seen") : language.text("새 항목", "New")))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }

                    if let syncResult = privateAdapterModel.syncResult {
                        GroupBox(language.text("마지막 다운로드", "Last Download")) {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                GridRow { Text(language.text("확인한 항목", "Checked")).foregroundStyle(.secondary); Text("\(syncResult.scanned)") }
                                GridRow { Text(language.text("새 항목", "New items")).foregroundStyle(.secondary); Text("\(syncResult.unarchived)") }
                                GridRow { Text(language.text("다운로드", "Downloaded")).foregroundStyle(.secondary); Text("\(syncResult.downloaded)") }
                                GridRow { Text(language.text("건너뜀", "Skipped")).foregroundStyle(.secondary); Text("\(syncResult.skippedAlreadyArchived)") }
                                GridRow { Text(language.text("실패", "Failed")).foregroundStyle(.secondary); Text("\(syncResult.failed)") }
                            }
                            .padding(6)
                        }
                    }
                }

                if !privateAdapterModel.statusMessage.isEmpty {
                    Text(privateAdapterModel.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let errorMessage = privateAdapterModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(language.text("개인 사이트", "Private Sites"))
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = language.text("다운로드 폴더 선택", "Choose Download Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            model.setOutputDirectory(selectedURL)
        }
    }

    private func chooseCollectionOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = language.text("모음 다운로드 폴더 선택", "Choose Collection Download Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = collectionModel.outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            collectionModel.setOutputDirectory(selectedURL)
        }
    }

    private func mediaTypeBinding(_ type: MediaAssetType) -> Binding<Bool> {
        Binding(
            get: { collectionModel.isMediaTypeEnabled(type) },
            set: { collectionModel.setMediaType(type, enabled: $0) }
        )
    }

    private var collectionSourceBinding: Binding<CollectionSourceMode> {
        Binding(
            get: { collectionModel.selectedSource },
            set: { collectionModel.setSource($0) }
        )
    }

    private func xCollectionBinding(_ collection: BuiltInCollection) -> Binding<Bool> {
        Binding(
            get: { collectionModel.isXCollectionEnabled(collection) },
            set: { collectionModel.setXCollection(collection, enabled: $0) }
        )
    }

    private var xHandleBinding: Binding<String> {
        Binding(
            get: { collectionModel.xAccountName },
            set: { collectionModel.setXAccountName($0) }
        )
    }

    private func collectionMembershipLabel(_ collections: [BuiltInCollection]) -> String {
        collections.map { collection in
            switch collection {
            case .xLikes: language.text("좋아요", "Likes")
            case .xBookmarks: language.text("북마크", "Bookmarks")
            case .youtubeLiked: language.text("YouTube 좋아요", "YouTube Likes")
            case .youtubeWatchLater: language.text("나중에 볼 동영상", "Watch Later")
            }
        }.joined(separator: " + ")
    }

    private func choosePrivateAdapterOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = language.text("개인 사이트 다운로드 폴더 선택", "Choose Private Site Download Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = privateAdapterModel.outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            privateAdapterModel.setOutputDirectory(selectedURL)
        }
    }

    private func collectionSourceName(_ source: CollectionSourceMode) -> String {
        switch source {
        case .xCollections: language.text("X 좋아요 · 북마크", "X Likes & Bookmarks")
        case .youtubeLiked: language.text("YouTube 좋아요 표시한 동영상", "YouTube Liked Videos")
        case .youtubeWatchLater: language.text("YouTube 나중에 볼 동영상", "YouTube Watch Later")
        }
    }

    private func mediaTypeName(_ type: MediaAssetType) -> String {
        switch type {
        case .video: language.text("동영상", "Videos")
        case .photo: language.text("사진", "Photos")
        case .animated: language.text("움직이는 미디어", "Animated media")
        }
    }

    private func collectionName(_ collection: BuiltInCollection) -> String {
        switch collection {
        case .xLikes: language.text("X 좋아요", "X Likes")
        case .xBookmarks: language.text("X 북마크", "X Bookmarks")
        case .youtubeLiked: language.text("YouTube 좋아요", "YouTube Likes")
        case .youtubeWatchLater: language.text("YouTube 나중에 볼 동영상", "YouTube Watch Later")
        }
    }

    private func historyStatus(_ status: ArchiveStatus) -> String {
        switch status {
        case .discovered: language.text("확인됨", "Discovered")
        case .downloading: language.text("다운로드 중", "Downloading")
        case .downloaded: language.text("다운로드됨", "Downloaded")
        case .failed: language.text("실패", "Failed")
        }
    }

    private func historyDate(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func discoveryIssueMessage(_ issue: BrowserSessionDiscoveryIssue) -> String {
        guard language.language == .korean else { return issue.message }
        switch issue.kind {
        case .enumerationPermissionDenied:
            return "macOS가 브라우저 프로필 목록 접근을 허용하지 않았습니다. ClipBox의 개인정보 보호 권한을 확인해 주세요."
        case .fileReadPermissionDenied:
            return "브라우저 프로필은 찾았지만 로그인 정보에 접근할 권한이 없습니다."
        case .unsupportedFormat:
            return "이 Safari 프로필의 로그인 저장 형식은 현재 지원하지 않습니다."
        case .metadataPermissionDenied, .metadataUnreadable:
            return "Safari 프로필 이름을 확인하지 못했습니다. 이름을 알 수 없는 프로필도 선택해서 사용할 수 있습니다."
        }
    }

    private func sessionCheckMessage(_ check: BrowserSessionCheck) -> String {
        guard language.language == .korean else { return check.message }
        if check.connected, let identity = check.identity, identity.evidence == .serverVerified {
            return identity.handle.map { "X 계정 @\($0)에 정상적으로 연결되었습니다." } ?? "X 계정 연결을 확인했습니다."
        }
        if check.connected {
            return "X 로그인 상태는 확인했지만 계정 정보까지 확인하지 못했습니다."
        }
        return "이 프로필에서 사용할 수 있는 X 로그인을 찾지 못했습니다. X에 로그인한 프로필인지 확인해 주세요."
    }

    private func resolution(_ media: MediaMetadata) -> String {
        guard let width = media.width, let height = media.height else {
            return language.text("알 수 없음", "Unknown")
        }
        return "\(width)x\(height)"
    }
}

private struct ScanLimitControl: View {
    @EnvironmentObject private var language: AppLanguageStore
    @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("최근 항목만 확인", "Scan Newest Items"))
            HStack {
                TextField(language.text("개수", "Count"), value: $value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel(language.text("확인할 최근 항목 개수", "Number of newest items to scan"))
                    .onChange(of: value) { _, count in
                        value = min(1_000_000, max(1, count))
                    }
                Stepper(language.text("개수 조절", "Adjust count"), value: $value, in: 1...1_000_000)
                    .labelsHidden()
                Menu(language.text("빠른 선택", "Presets")) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { count in
                        Button(String(count)) { value = count }
                    }
                }.fixedSize()
            }
            Text(language.text(
                "숫자를 직접 입력하거나 빠른 선택을 사용할 수 있습니다. 전체 기록은 ‘전체 기록 확인’을 사용하세요.",
                "Enter a number directly or choose a preset. Use Scan all available history for the full collection."
            ))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

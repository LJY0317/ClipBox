import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .korean: "ko_KR"
        case .english: "en_US"
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    private static let preferenceKey = "ClipBoxAppLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.preferenceKey)
        }
    }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.preferenceKey),
           let language = AppLanguage(rawValue: stored) {
            self.language = language
        } else {
            // Korean is the first polished consumer-facing localization. The picker in
            // Settings keeps the UI ready for English and additional languages later.
            self.language = .korean
        }
    }

    func text(_ korean: String, _ english: String) -> String {
        language == .korean ? korean : english
    }
}

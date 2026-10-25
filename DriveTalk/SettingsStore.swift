import Foundation
import Security

enum KeychainHelper {
    private static let service = "DriveTalk"

    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// App settings. API keys are stored in the Keychain; everything else in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    @Published var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var openAIKey: String { didSet { KeychainHelper.save(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "openai") } }
    @Published var claudeKey: String { didSet { KeychainHelper.save(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "claude") } }
    @Published var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    @Published var geminiKey: String { didSet { KeychainHelper.save(geminiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "gemini") } }
    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }

    @Published var mode: PracticeMode { didSet { d.set(mode.rawValue, forKey: "mode"); fixScenario() } }
    @Published var scenarioID: String { didSet { d.set(scenarioID, forKey: "scenarioID") } }
    @Published var newsCategory: NewsCategory { didSet { d.set(newsCategory.rawValue, forKey: "newsCategory") } }
    /// Speech-to-text engine. OpenAI = more accurate (accents, 中英混講) but billed per minute.
    @Published var speechEngine: SpeechEngine { didSet { d.set(speechEngine.rawValue, forKey: "speechEngine") } }
    /// Apple recognition via Apple's servers (more accurate) instead of on-device only.
    @Published var appleServerRecognition: Bool { didSet { d.set(appleServerRecognition, forKey: "appleServerRecognition") } }
    @Published var shadowTopic: ShadowTopic { didSet { d.set(shadowTopic.rawValue, forKey: "shadowTopic") } }
    /// In shadowing, also read the Chinese meaning of each sentence.
    @Published var shadowSayChinese: Bool { didSet { d.set(shadowSayChinese, forKey: "shadowSayChinese") } }
    /// Say the Chinese meaning every time the sentence is replayed (not only the first time).
    @Published var shadowChineseEveryTime: Bool { didSet { d.set(shadowChineseEveryTime, forKey: "shadowChineseEveryTime") } }
    @Published var shadowLength: ShadowLength { didSet { d.set(shadowLength.rawValue, forKey: "shadowLength") } }
    /// Tries per sentence before moving on.
    @Published var shadowMaxAttempts: Int { didSet { d.set(shadowMaxAttempts, forKey: "shadowMaxAttempts") } }
    /// After this many failed tries, practice the missed words one by one (0 = off).
    @Published var shadowWordDrillAfter: Int { didSet { d.set(shadowWordDrillAfter, forKey: "shadowWordDrillAfter") } }
    /// Word drill covers every word of the sentence (true) or only the missed words (false).
    @Published var shadowDrillAllWords: Bool { didSet { d.set(shadowDrillAllWords, forKey: "shadowDrillAllWords") } }

    @Published var usageContext: UsageContext { didSet { d.set(usageContext.rawValue, forKey: "usageContext") } }
    @Published var musicEnabled: Bool { didSet { d.set(musicEnabled, forKey: "musicEnabled") } }
    @Published var musicStyle: MusicStyle { didSet { d.set(musicStyle.rawValue, forKey: "musicStyle") } }
    @Published var musicVolume: Double { didSet { d.set(musicVolume, forKey: "musicVolume") } }
    @Published var level: EnglishLevel { didSet { d.set(level.rawValue, forKey: "level") } }
    @Published var feedbackEnabled: Bool { didSet { d.set(feedbackEnabled, forKey: "feedbackEnabled") } }
    @Published var feedbackLanguage: FeedbackLanguage { didSet { d.set(feedbackLanguage.rawValue, forKey: "feedbackLanguage") } }

    /// AVSpeechUtterance rate (0.0–1.0; default speaking rate is 0.5).
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    /// Seconds of silence that end the user's turn.
    @Published var silenceTimeout: Double { didSet { d.set(silenceTimeout, forKey: "silenceTimeout") } }
    @Published var useOpenAITTS: Bool { didSet { d.set(useOpenAITTS, forKey: "useOpenAITTS") } }
    @Published var openAIVoice: String { didSet { d.set(openAIVoice, forKey: "openAIVoice") } }

    static let openAIVoices = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    init() {
        provider = AIProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .openAI
        openAIKey = KeychainHelper.load("openai")
        claudeKey = KeychainHelper.load("claude")
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-4.1-mini"
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-haiku-4-5"
        geminiKey = KeychainHelper.load("gemini")
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-3.5-flash-lite"
        mode = PracticeMode(rawValue: d.string(forKey: "mode") ?? "") ?? .free
        scenarioID = d.string(forKey: "scenarioID") ?? "fae_boot"
        newsCategory = NewsCategory(rawValue: d.string(forKey: "newsCategory") ?? "") ?? .technology
        speechEngine = SpeechEngine(rawValue: d.string(forKey: "speechEngine") ?? "") ?? .apple
        appleServerRecognition = d.object(forKey: "appleServerRecognition") as? Bool ?? true
        shadowTopic = ShadowTopic(rawValue: d.string(forKey: "shadowTopic") ?? "") ?? .work
        shadowSayChinese = d.object(forKey: "shadowSayChinese") as? Bool ?? true
        shadowChineseEveryTime = d.object(forKey: "shadowChineseEveryTime") as? Bool ?? false
        shadowLength = ShadowLength(rawValue: d.string(forKey: "shadowLength") ?? "") ?? .medium
        shadowMaxAttempts = d.object(forKey: "shadowMaxAttempts") as? Int ?? 3
        shadowWordDrillAfter = d.object(forKey: "shadowWordDrillAfter") as? Int ?? 2
        shadowDrillAllWords = d.object(forKey: "shadowDrillAllWords") as? Bool ?? false
        usageContext = UsageContext(rawValue: d.string(forKey: "usageContext") ?? "") ?? .driving
        musicEnabled = d.object(forKey: "musicEnabled") as? Bool ?? false
        musicStyle = MusicStyle(rawValue: d.string(forKey: "musicStyle") ?? "") ?? .auto
        musicVolume = d.object(forKey: "musicVolume") as? Double ?? 0.35
        level = EnglishLevel(rawValue: d.string(forKey: "level") ?? "") ?? .intermediate
        feedbackEnabled = d.object(forKey: "feedbackEnabled") as? Bool ?? true
        feedbackLanguage = FeedbackLanguage(rawValue: d.string(forKey: "feedbackLanguage") ?? "") ?? .english
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.48
        silenceTimeout = d.object(forKey: "silenceTimeout") as? Double ?? 1.4
        useOpenAITTS = d.object(forKey: "useOpenAITTS") as? Bool ?? false
        openAIVoice = d.string(forKey: "openAIVoice") ?? "coral"
        fixScenario()
    }

    private func fixScenario() {
        let list = Scenario.scenarios(for: mode)
        if !list.isEmpty, !list.contains(where: { $0.id == scenarioID }) {
            scenarioID = list[0].id
        }
    }

    /// nil in free-conversation mode.
    var scenario: Scenario? {
        guard mode.usesScenario else { return nil }
        return Scenario.all.first { $0.id == scenarioID }
    }

    var activeKey: String {
        switch provider {
        case .openAI: return openAIKey
        case .claude: return claudeKey
        case .gemini: return geminiKey
        }
    }

    var activeModel: String {
        switch provider {
        case .openAI: return openAIModel
        case .claude: return claudeModel
        case .gemini: return geminiModel
        }
    }

    var sessionTitle: String {
        if let s = scenario { return "\(mode.rawValue)・\(s.title)" }
        if mode == .news { return "\(mode.rawValue)・\(newsCategory.rawValue)" }
        if mode == .shadowing { return "\(mode.rawValue)・\(shadowTopic.rawValue)" }
        return mode.rawValue
    }

    var isConfigured: Bool { !activeKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

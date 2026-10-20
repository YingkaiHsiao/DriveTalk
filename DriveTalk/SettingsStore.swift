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

    @Published var mode: PracticeMode { didSet { d.set(mode.rawValue, forKey: "mode"); fixScenario() } }
    @Published var scenarioID: String { didSet { d.set(scenarioID, forKey: "scenarioID") } }
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
        mode = PracticeMode(rawValue: d.string(forKey: "mode") ?? "") ?? .free
        scenarioID = d.string(forKey: "scenarioID") ?? "fae_boot"
        level = EnglishLevel(rawValue: d.string(forKey: "level") ?? "") ?? .intermediate
        feedbackEnabled = d.object(forKey: "feedbackEnabled") as? Bool ?? true
        feedbackLanguage = FeedbackLanguage(rawValue: d.string(forKey: "feedbackLanguage") ?? "") ?? .english
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.48
        silenceTimeout = d.object(forKey: "silenceTimeout") as? Double ?? 1.8
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
        guard mode != .free else { return nil }
        return Scenario.all.first { $0.id == scenarioID }
    }

    var activeKey: String { provider == .openAI ? openAIKey : claudeKey }
    var activeModel: String { provider == .openAI ? openAIModel : claudeModel }

    var sessionTitle: String {
        if let s = scenario { return "\(mode.rawValue)・\(s.title)" }
        return mode.rawValue
    }

    var isConfigured: Bool { !activeKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

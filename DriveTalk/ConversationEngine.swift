import Foundation
import AVFoundation
import UIKit

/// Runs the hands-free loop: AI speaks → user speaks → (feedback) → AI replies → ...
@MainActor
final class ConversationEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, listening, thinking, speaking, paused, summarizing
        var label: String {
            switch self {
            case .idle: return "準備就緒"
            case .preparing: return "啟動中…"
            case .listening: return "請說英文…"
            case .thinking: return "思考中…"
            case .speaking: return "AI 說話中"
            case .paused: return "暫停（音訊被中斷）"
            case .summarizing: return "產生學習摘要…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var errorText: String?
    @Published var finishedSession: SessionRecord?
    /// Seconds the AI took for the last reply (shown on screen to help pick a faster model).
    @Published private(set) var lastLatency: Double?

    let recognizer = SpeechRecognizer()
    let speaker = Speaker()
    let history = HistoryStore()

    private var loopTask: Task<Void, Never>?
    private var llmHistory: [LLMMessage] = []
    private var lastReply = ""
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { loopTask != nil }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: typeRaw) }
        })
    }

    // MARK: Public controls

    func start(settings: SettingsStore) {
        guard loopTask == nil else { return }
        errorText = nil
        loopTask = Task { [weak self] in
            await self?.run(settings: settings)
        }
    }

    /// Stops the session; a learning summary is generated if there was enough conversation.
    func stop() {
        loopTask?.cancel()
        recognizer.finish()
        speaker.stop()
    }

    // MARK: Main loop

    private func run(settings s: SettingsStore) async {
        defer { cleanup() }
        phase = .preparing

        guard s.isConfigured else {
            errorText = "請先到「設定」輸入 \(s.provider.rawValue) API Key"
            return
        }
        guard await SpeechRecognizer.requestPermissions() else {
            errorText = "需要「麥克風」與「語音辨識」權限，請到 iOS 設定 > DriveTalk 開啟"
            return
        }
        do {
            try AudioSessionManager.activate()
            try recognizer.startEngine()
        } catch {
            errorText = "音訊啟動失敗：\(error.localizedDescription)"
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true

        messages = []
        llmHistory = []
        lastReply = ""
        let system = PromptBuilder.system(mode: s.mode, scenario: s.scenario, level: s.level,
                                          feedback: s.feedbackEnabled, feedbackLanguage: s.feedbackLanguage)
        let service = LLMService(provider: s.provider, apiKey: s.activeKey, model: s.activeModel)

        // Opening line from the AI
        _ = await assistantTurn(userText: PromptBuilder.startToken, system: system, service: service, settings: s)

        conversation: while !Task.isCancelled {
            // Wait while a phone call / Siri etc. holds the audio.
            while interrupted && !Task.isCancelled {
                phase = .paused
                try? await Task.sleep(for: .milliseconds(500))
            }
            if Task.isCancelled { break }

            phase = .listening
            recognizer.silenceTimeout = s.silenceTimeout
            let heard = await recognizer.listen()
            if Task.isCancelled { break }

            if heard.isEmpty {
                if let err = recognizer.lastError {
                    errorText = err
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                continue   // keep listening quietly — the driver may be busy
            }
            errorText = nil

            switch VoiceCommand(heard) {
            case .end:
                await say("Okay, let's stop here. Great job today!", settings: s)
                break conversation
            case .repeatLast:
                if !lastReply.isEmpty { await say(lastReply, settings: s) }
                continue
            case .slower:
                s.speechRate = max(0.35, s.speechRate - 0.05)
                await say("Sure, I'll speak more slowly.", settings: s)
                continue
            case .faster:
                s.speechRate = min(0.6, s.speechRate + 0.05)
                await say("Okay, I'll speak a bit faster.", settings: s)
                continue
            case .normal:
                break
            }

            messages.append(ChatMessage(role: .user, text: heard))
            let ok = await assistantTurn(userText: heard, system: system, service: service, settings: s)
            if !ok {
                messages.removeLast()
            }
        }

        // Session summary
        let userTurns = messages.filter { $0.role == .user }.count
        if userTurns >= 2 {
            phase = .summarizing
            let summary = (try? await service.complete(
                system: PromptBuilder.summarySystem(),
                messages: [LLMMessage(role: "user", content: PromptBuilder.transcriptText(messages))],
                maxTokens: 1200)) ?? "（摘要產生失敗，請檢查網路。對話紀錄已保存。）"
            let record = SessionRecord(date: Date(), title: s.sessionTitle, summary: summary,
                                       turns: userTurns, transcript: messages)
            history.add(record)
            finishedSession = record
        }
    }

    /// Sends the user's text, speaks feedback + reply. Returns false on network/API failure.
    private func assistantTurn(userText: String, system: String, service: LLMService, settings s: SettingsStore) async -> Bool {
        phase = .thinking
        llmHistory.append(LLMMessage(role: "user", content: userText))
        trimHistory()
        do {
            let t0 = Date()
            let raw = try await service.complete(system: system, messages: llmHistory, maxTokens: 350, json: s.feedbackEnabled)
            lastLatency = Date().timeIntervalSince(t0)
            if Task.isCancelled { llmHistory.removeLast(); return false }
            let parsed = PromptBuilder.parse(raw, expectJSON: s.feedbackEnabled)
            llmHistory.append(LLMMessage(role: "assistant", content: raw))

            if !parsed.feedback.isEmpty, let i = messages.lastIndex(where: { $0.role == .user }) {
                messages[i].feedback = parsed.feedback
            }
            messages.append(ChatMessage(role: .assistant, text: parsed.reply))
            lastReply = parsed.reply

            if !parsed.feedback.isEmpty {
                let lang = s.feedbackLanguage == .chinese ? "zh-TW" : "en-US"
                await say(parsed.feedback, language: lang, settings: s)
            }
            if Task.isCancelled { return true }
            await say(parsed.reply, settings: s)
            return true
        } catch {
            llmHistory.removeLast()
            errorText = error.localizedDescription
            if !Task.isCancelled {
                await say("Sorry, I had a connection problem. Could you say that again?", settings: s)
            }
            return false
        }
    }

    private func say(_ text: String, language: String = "en-US", settings s: SettingsStore) async {
        guard !Task.isCancelled else { return }
        phase = .speaking
        if s.useOpenAITTS, !s.openAIKey.isEmpty,
           let data = try? await LLMService.openAISpeech(key: s.openAIKey, text: text,
                                                          voice: s.openAIVoice, speed: s.speechRate),
           !Task.isCancelled,
           await speaker.play(data) {
            return
        }
        guard !Task.isCancelled else { return }
        await speaker.speak(text, language: language, rate: Float(s.speechRate))
    }

    /// Keep the context small (fast + cheap). Must start with a user message for Claude.
    private func trimHistory() {
        let maxCount = 30
        if llmHistory.count > maxCount {
            llmHistory.removeFirst(llmHistory.count - maxCount)
        }
        while let first = llmHistory.first, first.role != "user" {
            llmHistory.removeFirst()
        }
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw), isRunning else { return }
        switch type {
        case .began:
            interrupted = true
            recognizer.finish()
            speaker.stop()
        case .ended:
            try? AudioSessionManager.activate()
            recognizer.restartEngine()
            interrupted = false
        @unknown default:
            break
        }
    }

    private func cleanup() {
        recognizer.stopEngine()
        speaker.stop()
        AudioSessionManager.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        interrupted = false
        phase = .idle
        loopTask = nil
    }
}

// MARK: - Voice commands (hands-free control)

enum VoiceCommand {
    case end, repeatLast, slower, faster, normal

    init(_ text: String) {
        let t = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        let words = t.split(separator: " ").count
        if t.contains("stop practice") || t.contains("end practice") || t.contains("end session")
            || t.contains("stop the session") || t.contains("stop session") {
            self = .end
        } else if words <= 4 && (t.contains("repeat") || t.contains("say that again") || t.contains("say it again")) {
            self = .repeatLast
        } else if words <= 5 && (t.contains("slow down") || t.contains("speak slower") || t.contains("more slowly")) {
            self = .slower
        } else if words <= 5 && (t.contains("speak faster") || t.contains("speed up")) {
            self = .faster
        } else {
            self = .normal
        }
    }
}

// MARK: - Audio session

enum AudioSessionManager {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        // .allowBluetooth = HFP, so the car's hands-free microphone can be used.
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try s.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - History persistence

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [SessionRecord] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            records = list
        }
    }

    func add(_ r: SessionRecord) {
        records.insert(r, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

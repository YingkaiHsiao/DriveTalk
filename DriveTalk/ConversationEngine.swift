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
    private var pendingArticle: NewsArticle?
    private var pendingShadowSaved = false
    private var usedNewsLinks: Set<String> = []
    /// Title shown on screen for the current session (e.g. the news headline).
    @Published private(set) var sessionSubtitle: String?

    var isRunning: Bool { loopTask != nil }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: typeRaw) }
        })
    }

    // MARK: Public controls

    /// - Parameter article: start a news-discussion session about this article (from the 新聞 tab).
    /// - Parameter shadowSaved: start a shadowing session using only the saved expressions.
    func start(settings: SettingsStore, article: NewsArticle? = nil, shadowSaved: Bool = false) {
        guard loopTask == nil else { return }
        errorText = nil
        pendingArticle = article
        pendingShadowSaved = shadowSaved
        loopTask = Task { [weak self] in
            await self?.run(settings: settings)
        }
    }

    /// Stops the session; a learning summary is generated if there was enough conversation.
    func stop() {
        loopTask?.cancel()
        cancelSpeech()
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
        let startedAt = Date()
        defer { ProgressStore.shared.addPractice(seconds: Date().timeIntervalSince(startedAt)) }

        messages = []
        llmHistory = []
        lastReply = ""
        sessionSubtitle = nil
        let service = s.makeService()
        let shadowSaved = pendingShadowSaved
        let mode: PracticeMode = pendingArticle != nil ? .news : (shadowSaved ? .shadowing : s.mode)
        var article = pendingArticle
        pendingArticle = nil
        pendingShadowSaved = false
        configureRecognition(settings: s, article: article)

        if mode == .shadowing {
            await runShadowing(settings: s, savedOnly: shadowSaved || s.shadowTopic == .saved)
            let attempts = messages.filter { $0.role == .user }.count
            if attempts > 0 {
                let t = ProgressStore.shared.today
                let avg = t.shadowCount == 0 ? 0 : t.shadowScoreSum / t.shadowCount
                let record = SessionRecord(date: Date(), title: shadowSaved ? "跟讀練習・我的表達方式" : s.sessionTitle,
                                           summary: "跟讀 \(attempts) 次。今日累計跟讀 \(t.shadowCount) 句，平均 \(avg) 分。\n\n每次跟讀的分數與漏掉的字請看「完整對話」。",
                                           turns: attempts, transcript: messages)
                history.add(record)
                finishedSession = record
            }
            return
        }
        var reviewWords: [VocabEntry] = []
        var reviewExprs: [SavedExpression] = []

        switch mode {
        case .news:
            if article == nil {
                await say("Let me get today's \(s.newsCategory == .technology ? "tech " : "")news for you.", settings: s)
                article = await loadNextArticle(settings: s)
                if article == nil {
                    await say("Sorry, I couldn't get the news right now. Let's try again later.", settings: s)
                    return
                }
            }
            if let a = article { await readArticle(a, settings: s) }
        case .vocabReview:
            reviewWords = VocabStore.shared.reviewBatch(limit: 10)
            reviewExprs = Array(ProgressStore.shared.dueExpressions.prefix(5))
            if reviewWords.isEmpty && reviewExprs.isEmpty {
                errorText = "生字本和表達方式都還是空的：先查單字、讀新聞或開啟糾錯練習對話"
                await say("There's nothing to review yet. Save some words first, then come back.", settings: s)
                return
            }
            sessionSubtitle = "智慧複習：\(reviewWords.count) 個單字、\(reviewExprs.count) 個表達"
        default:
            break
        }
        if Task.isCancelled { return }

        func makeSystem() -> String {
            PromptBuilder.system(mode: mode, scenario: s.scenario, level: s.level,
                                 feedback: s.feedbackEnabled, feedbackLanguage: s.feedbackLanguage,
                                 article: article, reviewWords: reviewWords, reviewExpressions: reviewExprs)
        }
        var system = makeSystem()

        // Opening line from the AI
        _ = await assistantTurn(userText: PromptBuilder.startToken, system: system, service: service, settings: s)

        conversation: while !Task.isCancelled {
            await waitIfInterrupted()
            if Task.isCancelled { break }

            phase = .listening
            let heard = await listenOnce(settings: s, chinese: chineseNext)
            chineseNext = false
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
            case .nextNews:
                guard mode == .news else { break }
                await say("Okay, here's the next story.", settings: s)
                guard let next = await loadNextArticle(settings: s) else {
                    await say("Sorry, I couldn't get another story.", settings: s)
                    continue
                }
                article = next
                system = makeSystem()
                llmHistory = []
                await readArticle(next, settings: s)
                _ = await assistantTurn(userText: PromptBuilder.startToken, system: system, service: service, settings: s)
                continue
            case .chinese:
                chineseNext = true
                await say("好，請說中文。", language: "zh-TW", settings: s)
                continue
            case .skip, .normal:
                break
            }

            messages.append(ChatMessage(role: .user, text: heard))
            ProgressStore.shared.recordUtterance(heard)
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

    /// Sends the user's text and STREAMS the answer: feedback / Chinese explanation / each reply sentence
    /// is spoken as soon as it arrives. Returns false on network/API failure.
    private func assistantTurn(userText: String, system: String, service: LLMService, settings s: SettingsStore) async -> Bool {
        phase = .thinking
        llmHistory.append(LLMMessage(role: "user", content: userText))
        trimHistory()
        var parser = StreamSpeechParser()
        let feedbackLang = s.feedbackLanguage == .chinese ? "zh-TW" : "en-US"
        let t0 = Date()
        var latencyMarked = false

        func speak(_ segments: [StreamSpeechParser.Segment]) {
            for seg in segments {
                if !latencyMarked { lastLatency = Date().timeIntervalSince(t0); latencyMarked = true }
                switch seg {
                case .feedback(let t): enqueueSpeech(t, feedbackLang, s)
                case .chinese(let t): enqueueSpeech(t, "zh-TW", s)
                case .reply(let t): enqueueSpeech(t, "en-US", s)
                }
            }
        }

        var raw = ""
        do {
            let stats = try await service.stream(system: system, messages: llmHistory, maxTokens: 400) { delta in
                speak(parser.feed(delta))
            }
            raw = stats.text
        } catch {
            if !parser.emittedAny || Task.isCancelled {
                llmHistory.removeLast()
                cancelSpeech()
                errorText = error.localizedDescription
                if !Task.isCancelled {
                    await say("Sorry, I had a connection problem. Could you say that again?", settings: s)
                }
                return false
            }
            raw = parser.receivedText   // keep what already arrived and was spoken
        }
        speak(parser.finish())
        if Task.isCancelled { llmHistory.removeLast(); return false }

        let parsed = PromptBuilder.parse(raw)
        if !parser.emittedAny {
            // Model ignored the line format: speak the parsed reply in one go.
            if !parsed.explainZh.isEmpty { enqueueSpeech(parsed.explainZh, "zh-TW", s) }
            if !parsed.reply.isEmpty { enqueueSpeech(parsed.reply, "en-US", s) }
            if !latencyMarked { lastLatency = Date().timeIntervalSince(t0) }
        }
        for w in parsed.vocab { VocabStore.shared.add(w, source: "對話") }
        applyGrades(parsed.graded)
        llmHistory.append(LLMMessage(role: "assistant", content: raw))

        if !parsed.feedback.isEmpty, let i = messages.lastIndex(where: { $0.role == .user }) {
            messages[i].feedback = parsed.feedback
            if !parsed.better.isEmpty {
                ProgressStore.shared.addExpression(original: messages[i].text, better: parsed.better,
                                                   note: parsed.feedback, source: "對話糾錯")
            }
        }
        let shown = [parsed.explainZh, parsed.reply].filter { !$0.isEmpty }.joined(separator: "\n")
        messages.append(ChatMessage(role: .assistant, text: shown))
        lastReply = parsed.reply.isEmpty ? parsed.explainZh : parsed.reply

        await drainSpeech()
        return true
    }

    // MARK: Speech queue (lets speaking overlap with the streaming reply)

    private var speechItems: [(String, String)] = []
    private var speechTask: Task<Void, Never>?

    private func enqueueSpeech(_ text: String, _ language: String, _ s: SettingsStore) {
        speechItems.append((text, language))
        guard speechTask == nil else { return }
        speechTask = Task { [weak self] in
            guard let self else { return }
            while !self.speechItems.isEmpty && !Task.isCancelled {
                let item = self.speechItems.removeFirst()
                await self.say(item.0, language: item.1, settings: s)
            }
            self.speechTask = nil
        }
    }

    private func drainSpeech() async {
        while let t = speechTask {
            await t.value
            if speechTask == t { speechTask = nil }
        }
    }

    private func cancelSpeech() {
        speechItems.removeAll()
        speechTask?.cancel()
        speechTask = nil
        speaker.stop()
    }

    // MARK: Recognition setup

    private var chineseNext = false
    private var transcribePrompt = ""

    private static let baseHints = [
        "U-Boot", "device tree", "kernel", "Linux", "BSP", "Yocto", "OpenWrt", "Wi-Fi", "firmware", "bootloader",
        "backport", "patch", "CVE", "driver", "UART", "bring-up", "SoC", "debug", "log", "schedule", "deadline",
    ]

    private func configureRecognition(settings s: SettingsStore, article: NewsArticle?) {
        var hints = Self.baseHints
        hints += VocabStore.shared.entries.prefix(60).map(\.info.word)
        hints += article?.vocabulary.map(\.word) ?? []
        recognizer.hints = hints
        recognizer.onDeviceOnly = !s.appleServerRecognition
        transcribePrompt = "A Taiwanese engineer practicing spoken English; may mix in Mandarin Chinese " +
            "(write Chinese in Traditional characters). Terms: " + hints.prefix(40).joined(separator: ", ")
    }

    private func listenOnce(settings s: SettingsStore, chinese: Bool = false) async -> String {
        recognizer.silenceTimeout = s.silenceTimeout
        let transcriber: OpenAITranscriber? = (s.speechEngine == .openAI && !s.openAIKey.isEmpty)
            ? OpenAITranscriber(apiKey: s.openAIKey, prompt: transcribePrompt) : nil
        return await recognizer.listen(locale: chinese ? "zh-TW" : "en-US", transcriber: transcriber)
    }

    /// Smart review: update the spaced-repetition schedule from the AI's grading.
    private func applyGrades(_ graded: [(item: String, correct: Bool)]) {
        for g in graded {
            let key = g.item.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if VocabStore.shared.contains(key) {
                VocabStore.shared.grade(word: key, g.correct ? .good : .again)
            } else if let e = ProgressStore.shared.expressions.first(where: {
                $0.better.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    == key.trimmingCharacters(in: .punctuationCharacters)
            }) {
                ProgressStore.shared.gradeExpression(e.id, g.correct ? .good : .again)
            }
        }
    }

    private func waitIfInterrupted() async {
        // Wait while a phone call / Siri etc. holds the audio.
        while interrupted && !Task.isCancelled {
            phase = .paused
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Shadowing (跟讀) — scored locally, almost no tokens

    private func runShadowing(settings s: SettingsStore, savedOnly: Bool) async {
        var first = true
        while !Task.isCancelled {
            var items: [(en: String, zh: String, exprID: UUID?)] = []
            let saved = ProgressStore.shared.expressionsForPractice(limit: savedOnly ? 10 : 3)
            items += saved.map { (en: $0.better, zh: "", exprID: UUID?.some($0.id)) }
            if !savedOnly {
                phase = .thinking
                do {
                    let gen = try await StudyService(settings: s).shadowSentences(topic: s.shadowTopic, level: s.level, count: 8)
                    items += gen.map { (en: $0.en, zh: $0.zh, exprID: UUID?.none) }
                } catch {
                    errorText = error.localizedDescription
                }
            }
            if Task.isCancelled { return }
            if items.isEmpty {
                if savedOnly {
                    errorText = "還沒有存下的表達方式：開啟即時糾錯練習對話，或用「查詢 > 文法修正」收集"
                    await say("You don't have any saved expressions yet.", settings: s)
                } else {
                    await say("Sorry, I couldn't prepare sentences. Please check the connection.", settings: s)
                }
                return
            }
            if first {
                await say("Let's do shadowing. Listen, then repeat after me. Say next to skip a sentence.", settings: s)
                first = false
            }

            for item in items {
                if Task.isCancelled { return }
                sessionSubtitle = item.en
                messages.append(ChatMessage(role: .assistant, text: item.zh.isEmpty ? item.en : "\(item.en)\n\(item.zh)"))
                lastReply = item.en
                var best = 0
                var attempt = 0
                sentence: while attempt < 3 && !Task.isCancelled {
                    attempt += 1
                    await waitIfInterrupted()
                    await say(item.en, settings: s, rateScale: 0.9)
                    if attempt == 1, s.shadowSayChinese, !item.zh.isEmpty {
                        await say(item.zh, language: "zh-TW", settings: s)
                    }
                    if Task.isCancelled { return }
                    phase = .listening
                    let heard = await listenOnce(settings: s)
                    if Task.isCancelled { return }
                    if heard.isEmpty { continue }   // silence: play it again

                    switch VoiceCommand(heard) {
                    case .end:
                        await say("Okay, great practice today!", settings: s)
                        return
                    case .skip, .nextNews:
                        break sentence
                    case .chinese:
                        attempt -= 1
                        continue
                    case .repeatLast:
                        attempt -= 1
                        continue
                    case .slower:
                        s.speechRate = max(0.35, s.speechRate - 0.05)
                        attempt -= 1
                        continue
                    case .faster:
                        s.speechRate = min(0.6, s.speechRate + 0.05)
                        attempt -= 1
                        continue
                    case .normal:
                        break
                    }

                    ProgressStore.shared.recordUtterance(heard)
                    let result = ShadowScorer.score(target: item.en, heard: heard)
                    best = max(best, result.score)
                    var user = ChatMessage(role: .user, text: heard)
                    user.feedback = "跟讀分數 \(result.score)" + (result.missed.isEmpty ? "" : "・沒聽到：" + result.missed.joined(separator: ", "))
                    messages.append(user)

                    if result.score >= 85 {
                        await say(result.score >= 98 ? "Perfect!" : ["Great!", "Nice job!", "Very good!"].randomElement()!, settings: s)
                        break sentence
                    } else if attempt < 3 {
                        let hint = result.missed.prefix(3).joined(separator: ", ")
                        await say(hint.isEmpty ? "Almost! One more time." : "Almost! Listen for: \(hint). Again.", settings: s)
                    } else {
                        await say("Good try. Let's move on.", settings: s)
                    }
                }
                if best > 0 { ProgressStore.shared.recordShadow(score: best) }
                if let id = item.exprID { ProgressStore.shared.markPracticed(id) }
            }
            if Task.isCancelled { return }
            await say(savedOnly ? "That's all your saved expressions. Let's go through them again." : "Nice work! Here come more sentences.", settings: s)
        }
    }

    // MARK: News helpers

    private func loadNextArticle(settings s: SettingsStore) async -> NewsArticle? {
        phase = .thinking
        let store = NewsStore.shared
        if store.items.isEmpty || store.loadedCategory != s.newsCategory {
            await store.refresh(s.newsCategory)
        }
        guard let item = store.nextItem(after: usedNewsLinks) else {
            errorText = store.errorText ?? "目前沒有新聞"
            return nil
        }
        usedNewsLinks.insert(item.link)
        do {
            return try await store.article(for: item, settings: s)
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    private func readArticle(_ a: NewsArticle, settings s: SettingsStore) async {
        sessionSubtitle = a.title
        messages.append(ChatMessage(role: .assistant, text: "📰 " + a.fullText))
        await say(a.title, settings: s)
        for para in a.paragraphs {
            if Task.isCancelled { return }
            await say(para, settings: s)
        }
    }

    private func say(_ text: String, language: String = "en-US", settings s: SettingsStore, rateScale: Double = 1) async {
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
        await speaker.speak(text, language: language, rate: Float(s.speechRate * rateScale))
    }

    /// Keep the context small (fast + cheap). Must start with a user message for Claude.
    private func trimHistory() {
        let maxCount = 16   // shorter history = faster replies and fewer tokens
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
    case end, repeatLast, slower, faster, nextNews, skip, chinese, normal

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
        } else if words <= 5 && (t.contains("next news") || t.contains("next story") || t.contains("another story")) {
            self = .nextNews
        } else if words <= 3 && t.contains("chinese") && !t.contains("explain") {
            self = .chinese
        } else if words <= 3 && (t == "next" || t == "skip" || t.contains("next one") || t.contains("next sentence")
                                 || t.contains("skip it") || t.contains("skip this")) {
            self = .skip
        } else {
            self = .normal
        }
    }
}

// MARK: - Audio session

@MainActor
enum AudioSessionManager {
    /// True while a driving practice session owns the audio session.
    private(set) static var practiceActive = false

    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        // .allowBluetooth = HFP, so the car's hands-free microphone can be used.
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try s.setActive(true)
        practiceActive = true
    }

    static func deactivate() {
        practiceActive = false
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

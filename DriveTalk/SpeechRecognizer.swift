import Foundation
import AVFoundation
import Speech

/// Forwards microphone buffers (on the audio thread) to the current recognition requests, if any.
final class BufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SFSpeechAudioBufferRecognitionRequest] = []

    var requests: [SFSpeechAudioBufferRecognitionRequest] {
        get { lock.lock(); defer { lock.unlock() }; return _requests }
        set { lock.lock(); _requests = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let rs = _requests; lock.unlock()
        for r in rs { r.append(buffer) }
    }
}

/// Hands-free speech recognition (English, optionally English + 中文 at the same time).
/// The audio engine keeps running for the whole session (this also keeps the app alive in the
/// background / with the screen locked); each `listen()` call creates new recognition requests
/// and returns when the user stops talking for `silenceTimeout` seconds.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var partial = ""
    @Published private(set) var lastError: String?

    var silenceTimeout: TimeInterval = 1.8
    var noSpeechTimeout: TimeInterval = 20
    /// Also run a zh-TW recognizer so the user can ask questions in Chinese.
    var bilingual = false

    /// One recognizer + request + task for one language.
    private final class Channel {
        let locale: String
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence: Float = 0
        var done = false
        init(locale: String, request: SFSpeechAudioBufferRecognitionRequest) {
            self.locale = locale
            self.request = request
        }
    }

    private let recognizers: [String: SFSpeechRecognizer] = {
        var d: [String: SFSpeechRecognizer] = [:]
        for id in ["en-US", "zh-TW"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)) { d[id] = r }
        }
        return d
    }()
    private let engine = AVAudioEngine()
    private let router = BufferRouter()
    private var channels: [Channel] = []
    private var timer: Timer?
    private var continuation: CheckedContinuation<String, Never>?
    private var generation = 0
    private var finalizing = false
    private var configObserver: NSObjectProtocol?
    private(set) var engineRunning = false

    static func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
    }

    // MARK: Engine

    func startEngine() throws {
        guard !engineRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "DriveTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到可用的麥克風輸入"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(router))
        engine.prepare()
        try engine.start()
        engineRunning = true

        if configObserver == nil {
            // Fired e.g. when car Bluetooth connects/disconnects and the input format changes.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.restartEngine() }
            }
        }
    }

    func stopEngine() {
        finish()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engineRunning = false
    }

    func restartEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engineRunning = false
        do { try startEngine() } catch { lastError = error.localizedDescription }
    }

    // MARK: Listening

    /// Listens for one utterance. Returns "" if nothing was said within `noSpeechTimeout`.
    func listen() async -> String {
        finish()
        partial = ""
        lastError = nil
        finalizing = false

        guard let en = recognizers["en-US"], en.isAvailable else {
            lastError = "語音辨識目前無法使用（請確認網路或已下載英文語音辨識模型）"
            return ""
        }
        if !engineRunning {
            do { try startEngine() } catch {
                lastError = error.localizedDescription
                return ""
            }
        }

        var list: [(String, SFSpeechRecognizer)] = [("en-US", en)]
        if bilingual, let zh = recognizers["zh-TW"], zh.isAvailable { list.append(("zh-TW", zh)) }

        generation += 1
        let gen = generation

        return await withCheckedContinuation { cont in
            continuation = cont
            channels = list.map { pair in
                let (id, recognizer) = pair
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                req.addsPunctuation = true
                req.taskHint = .dictation
                if recognizer.supportsOnDeviceRecognition {
                    req.requiresOnDeviceRecognition = true   // faster, private, no 1-minute limit
                }
                return Channel(locale: id, request: req)
            }
            router.requests = channels.map(\.request)
            for (i, ch) in channels.enumerated() {
                guard let recognizer = recognizers[ch.locale] else { continue }
                ch.task = recognizer.recognitionTask(with: ch.request,
                                                     resultHandler: Self.makeHandler(owner: self, generation: gen, index: i))
            }
            armTimer(noSpeechTimeout, generation: gen, silence: false)
        }
    }

    /// Ends the current turn immediately with whatever was heard so far.
    func finish() {
        resolve(with: bestText(final: false))
    }

    private func resolve(with text: String) {
        timer?.invalidate()
        timer = nil
        router.requests = []
        for ch in channels {
            ch.request.endAudio()
            ch.task?.cancel()
        }
        channels = []
        finalizing = false
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// User stopped talking. With one language we're done; with two, wait briefly for the final
    /// results (which carry confidence scores) and pick the better language.
    private func endOfSpeech(generation gen: Int) {
        guard gen == generation, continuation != nil, !finalizing else { return }
        if channels.count <= 1 {
            finish()
            return
        }
        finalizing = true
        router.requests = []
        for ch in channels { ch.request.endAudio() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))   // safety deadline
            guard gen == self.generation, self.finalizing else { return }
            self.resolve(with: self.bestText(final: true))
        }
    }

    private func handle(index: Int, text: String?, isFinal: Bool, confidence: Float, failed: Bool, generation gen: Int) {
        guard gen == generation, continuation != nil, index < channels.count else { return }
        let ch = channels[index]
        if let text, !text.isEmpty {
            ch.text = text
            if isFinal { ch.confidence = confidence }
            if !finalizing {
                partial = bestText(final: false)
                armTimer(silenceTimeout, generation: gen, silence: true)
            }
        }
        if isFinal || failed { ch.done = true }

        if finalizing {
            if channels.allSatisfy(\.done) { resolve(with: bestText(final: true)) }
        } else if channels.count == 1, isFinal || failed {
            finish()
        }
    }

    /// Picks English or Chinese. While talking: show Chinese only if it clearly is Chinese.
    /// At the end: compare the recognizers' confidence.
    private func bestText(final: Bool) -> String {
        guard let en = channels.first(where: { $0.locale == "en-US" }) else { return partial }
        guard let zh = channels.first(where: { $0.locale == "zh-TW" }), zh.text.containsChinese else { return en.text }
        if en.text.isEmpty { return zh.text }
        if final, zh.confidence > 0 || en.confidence > 0 {
            return zh.confidence > en.confidence + 0.05 ? zh.text : en.text
        }
        // Heuristic before final scores: lots of Chinese characters → Chinese speech.
        let cjk = zh.text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return cjk >= 4 && en.text.split(separator: " ").count <= cjk / 2 ? zh.text : en.text
    }

    private func armTimer(_ interval: TimeInterval, generation gen: Int, silence: Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if silence { self.endOfSpeech(generation: gen) } else { self.finish() }
            }
        }
    }

    // Built in nonisolated context so the closures are not main-actor isolated
    // (they are called on audio / recognition background threads).
    nonisolated private static func makeTap(_ router: BufferRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in router.append(buffer) }
    }

    nonisolated private static func makeHandler(owner: SpeechRecognizer, generation: Int, index: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let segs = result?.bestTranscription.segments ?? []
            let conf: Float = segs.isEmpty ? 0 : segs.map(\.confidence).reduce(0, +) / Float(segs.count)
            let failed = error != nil
            Task { @MainActor in
                owner?.handle(index: index, text: text, isFinal: isFinal, confidence: conf,
                              failed: failed, generation: generation)
            }
        }
    }
}

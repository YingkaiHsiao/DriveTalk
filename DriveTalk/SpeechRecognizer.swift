import Foundation
import AVFoundation
import Speech

/// Forwards microphone buffers (on the audio thread) to the current recognition request,
/// and optionally records them to a file (for OpenAI transcription).
final class BufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _file: AVAudioFile?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    var file: AVAudioFile? {
        get { lock.lock(); defer { lock.unlock() }; return _file }
        set { lock.lock(); _file = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = _request; let f = _file; lock.unlock()
        r?.append(buffer)
        try? f?.write(from: buffer)
    }
}

/// Sends a recorded utterance to OpenAI speech-to-text (much better with accents and 中英混講).
struct OpenAITranscriber {
    let apiKey: String
    var model = "gpt-4o-mini-transcribe"
    /// Words/topic hints that help recognition.
    var prompt = ""

    func transcribe(_ fileURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await LLMService.session.data(for: req)
        try LLMService.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw LLMError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Hands-free speech recognition.
/// The audio engine keeps running for the whole session (this also keeps the app alive in the
/// background / with the screen locked). Apple's recognizer gives live captions and detects when
/// the user stops talking; optionally the recorded audio is then sent to OpenAI for a more
/// accurate transcript.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var partial = ""
    @Published private(set) var lastError: String?
    /// True while waiting for the OpenAI transcript.
    @Published private(set) var transcribing = false

    var silenceTimeout: TimeInterval = 1.5
    var noSpeechTimeout: TimeInterval = 20
    /// false = use Apple's servers (more accurate); true = on-device only (faster, offline).
    var onDeviceOnly = false
    /// Words that are likely to be said (scenario terms, vocab book…) — improves recognition.
    var hints: [String] = []

    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private let engine = AVAudioEngine()
    private let router = BufferRouter()
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var continuation: CheckedContinuation<String, Never>?
    private var generation = 0
    private var heardSomething = false
    private var recordingURL: URL?
    private var configObserver: NSObjectProtocol?
    private(set) var engineRunning = false

    static func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
    }

    private func recognizer(for locale: String) -> SFSpeechRecognizer? {
        if let r = recognizers[locale] { return r }
        let r = SFSpeechRecognizer(locale: Locale(identifier: locale))
        recognizers[locale] = r
        return r
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
    /// - Parameters:
    ///   - locale: "en-US" normally; "zh-TW" for a one-off Chinese question.
    ///   - transcriber: if set, the recorded audio is re-transcribed by OpenAI (falls back to Apple's text).
    func listen(locale: String = "en-US", transcriber: OpenAITranscriber? = nil) async -> String {
        finish()
        partial = ""
        lastError = nil
        heardSomething = false

        guard let rec = recognizer(for: locale), rec.isAvailable else {
            lastError = "語音辨識目前無法使用（請確認網路，或到 iOS 設定下載語音辨識語言）"
            return ""
        }
        if !engineRunning {
            do { try startEngine() } catch {
                lastError = error.localizedDescription
                return ""
            }
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if !hints.isEmpty { req.contextualStrings = Array(hints.prefix(100)) }
        if onDeviceOnly && rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        if transcriber != nil { startRecording() }

        generation += 1
        let gen = generation

        let appleText: String = await withCheckedContinuation { cont in
            continuation = cont
            router.request = req
            task = rec.recognitionTask(with: req, resultHandler: Self.makeHandler(owner: self, generation: gen))
            armTimer(noSpeechTimeout, generation: gen)
        }

        let recorded = stopRecording()
        guard let transcriber, let file = recorded, heardSomething, !Task.isCancelled else {
            if let recorded { try? FileManager.default.removeItem(at: recorded) }
            return appleText
        }
        transcribing = true
        defer {
            transcribing = false
            try? FileManager.default.removeItem(at: file)
        }
        do {
            try? await Task.sleep(for: .milliseconds(80))   // let the audio thread release the file
            let text = try await transcriber.transcribe(file)
            if !text.isEmpty { partial = text }
            return text.isEmpty ? appleText : text
        } catch {
            lastError = "OpenAI 轉文字失敗，改用 iPhone 辨識結果"
            return appleText
        }
    }

    /// Ends the current listening turn (the awaiting `listen()` returns what was heard so far).
    func finish() {
        timer?.invalidate()
        timer = nil
        router.request?.endAudio()
        router.request = nil
        task?.cancel()
        task = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: partial.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == generation, continuation != nil else { return }
        if let text, !text.isEmpty {
            partial = text
            heardSomething = true
            // A finished-looking sentence (ends with . ? !) → end the turn a bit sooner.
            let ended = text.last.map { ".?!。？！".contains($0) } ?? false
            armTimer(ended ? max(0.8, silenceTimeout * 0.7) : silenceTimeout, generation: gen)
        }
        if isFinal || failed { finish() }
    }

    private func armTimer(_ interval: TimeInterval, generation gen: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.finish()
            }
        }
    }

    // MARK: Recording (for OpenAI transcription)

    private func startRecording() {
        let format = engine.inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utt-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            router.file = try AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            recordingURL = url
        } catch {
            router.file = nil
            recordingURL = nil
        }
    }

    private func stopRecording() -> URL? {
        router.file = nil          // releasing the AVAudioFile closes it
        defer { recordingURL = nil }
        return recordingURL
    }

    // Built in nonisolated context so the closures are not main-actor isolated
    // (they are called on audio / recognition background threads).
    nonisolated private static func makeTap(_ router: BufferRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in router.append(buffer) }
    }

    nonisolated private static func makeHandler(owner: SpeechRecognizer, generation: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                owner?.handle(text: text, isFinal: isFinal, failed: failed, generation: generation)
            }
        }
    }
}

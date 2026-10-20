import Foundation
import AVFoundation
import Speech

/// Forwards microphone buffers (on the audio thread) to the current recognition request, if any.
final class BufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = _request; lock.unlock()
        r?.append(buffer)
    }
}

/// Hands-free English speech recognition.
/// The audio engine keeps running for the whole session (this also keeps the app alive in the
/// background / with the screen locked); each `listen()` call creates a new recognition request
/// and returns when the user stops talking for `silenceTimeout` seconds.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var partial = ""
    @Published private(set) var lastError: String?

    var silenceTimeout: TimeInterval = 1.8
    var noSpeechTimeout: TimeInterval = 20

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let router = BufferRouter()
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var continuation: CheckedContinuation<String, Never>?
    private var generation = 0
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

    /// Listens for one user utterance. Returns "" if nothing was said within `noSpeechTimeout`.
    func listen() async -> String {
        finish()
        partial = ""
        lastError = nil

        guard let recognizer, recognizer.isAvailable else {
            lastError = "語音辨識目前無法使用（請確認網路或已下載英文語音辨識模型）"
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
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // faster, private, no 1-minute limit
        }

        generation += 1
        let gen = generation

        return await withCheckedContinuation { cont in
            continuation = cont
            router.request = req
            task = recognizer.recognitionTask(with: req, resultHandler: Self.makeHandler(owner: self, generation: gen))
            armTimer(noSpeechTimeout, generation: gen)
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
            armTimer(silenceTimeout, generation: gen)
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

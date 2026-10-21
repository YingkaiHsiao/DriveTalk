import Foundation
import AVFoundation

/// Text-to-speech: Apple on-device voices (free, offline) or pre-rendered audio (OpenAI TTS).
@MainActor
final class Speaker: NSObject, ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentID: ObjectIdentifier?
    /// Utterances handed to the synthesizer's own queue (spoken back-to-back with no gap).
    private var queued: Set<ObjectIdentifier> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    var isBusy: Bool { !queued.isEmpty || currentID != nil }

    /// Speaks with the best installed Apple voice for `language` (e.g. "en-US", "zh-TW").
    func speak(_ text: String, language: String = "en-US", rate: Float = 0.48) async {
        if isBusy { stop() }   // don't cancel the silent prewarm utterances
        let u = Self.utterance(text, language: language, rate: rate)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            currentID = ObjectIdentifier(u)
            synth.speak(u)
        }
    }

    /// Adds text to the synthesizer queue without waiting. Queued utterances play back-to-back,
    /// so switching English → Chinese or sentence → sentence has no pause.
    func enqueue(_ text: String, language: String = "en-US", rate: Float = 0.48) {
        let u = Self.utterance(text, language: language, rate: rate)
        queued.insert(ObjectIdentifier(u))
        synth.speak(u)
    }

    /// Waits until everything queued with `enqueue` has been spoken (or stopped).
    func waitUntilIdle() async {
        guard !queued.isEmpty else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            idleWaiters.append(c)
        }
    }

    /// Speaks several segments back-to-back and waits for the end.
    func speakSequence(_ segments: [(text: String, language: String)], rate: Float) async {
        if isBusy { stop() }
        for seg in segments where !seg.text.isEmpty { enqueue(seg.text, language: seg.language, rate: rate) }
        await waitUntilIdle()
    }

    /// Loads the voices in advance (the first utterance with a new voice can take a second or more).
    func prewarm(_ languages: [String]) {
        for lang in languages {
            let u = Self.utterance(" ", language: lang, rate: 0.5)
            u.volume = 0
            u.postUtteranceDelay = 0
            synth.speak(u)
        }
    }

    /// Plays encoded audio (mp3). Returns false if the data could not be played.
    func play(_ data: Data) async -> Bool {
        stop()
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        p.delegate = self
        player = p
        let id = ObjectIdentifier(p)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            currentID = id
            if !p.play() { done(id) }
        }
        return true
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        if let id = currentID { done(id) }
        queued.removeAll()
        resumeIdleWaiters()
    }

    fileprivate func done(_ id: ObjectIdentifier) {
        if queued.remove(id) != nil, queued.isEmpty { resumeIdleWaiters() }
        guard id == currentID, let c = continuation else { return }
        continuation = nil
        currentID = nil
        c.resume()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private static func utterance(_ text: String, language: String, rate: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = bestVoice(for: language)
        u.rate = rate
        u.postUtteranceDelay = 0.05
        return u
    }

    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    /// Best installed voice (premium > enhanced > default), cached — listing voices is slow.
    /// Download better voices in Settings > Accessibility > Spoken Content > Voices.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let v = voiceCache[language] { return v }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let v = candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
        if let v { voiceCache[language] = v }
        return v
    }
}

/// A short soft "ding" so you hear immediately that your turn was received.
@MainActor
final class Chime {
    static let shared = Chime()
    private var player: AVAudioPlayer?

    private init() {
        player = try? AVAudioPlayer(data: Self.makeTone())
        player?.volume = 0.35
        player?.prepareToPlay()
    }

    func play() {
        player?.currentTime = 0
        player?.play()
    }

    /// 110 ms, two-note sine tone with fade in/out, as a 16-bit mono WAV.
    private static func makeTone() -> Data {
        let rate = 22_050.0, duration = 0.11
        let n = Int(rate * duration)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let freq = i < n / 2 ? 880.0 : 1320.0
            let env = min(1, Double(i) / 300) * min(1, Double(n - i) / 600)
            samples[i] = Int16(sin(2 * .pi * freq * t) * env * 12_000)
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = UInt32(n * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

extension Speaker: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.done(id) }
    }
}

/// Tap-to-pronounce for the study screens (word lookup, translation, news, vocab book).
@MainActor
final class Pronouncer: ObservableObject {
    static let shared = Pronouncer()
    private let speaker = Speaker()
    private var playTask: Task<Void, Never>?
    /// Identifier of what is currently being read (to show a stop button).
    @Published private(set) var speakingID: String?

    private init() {}

    func speak(_ text: String, id: String? = nil, language: String = "en-US", rate: Float = 0.45) {
        speakSequence([(text, language)], id: id ?? text, rate: rate)
    }

    /// Speaks several segments in order (e.g. word in English, then meaning in Chinese).
    func speakSequence(_ segments: [(String, String)], id: String, rate: Float = 0.45) {
        stop()
        prepareSession()
        speakingID = id
        playTask = Task {
            await speaker.speakSequence(segments.map { (text: $0.0, language: $0.1) }, rate: rate)
            if !Task.isCancelled { speakingID = nil }
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        speaker.stop()
        speakingID = nil
    }

    private func prepareSession() {
        let s = AVAudioSession.sharedInstance()
        // Don't touch the session while a driving practice (playAndRecord) is running.
        guard !AudioSessionManager.practiceActive else { return }
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
    }
}

import Foundation
import AVFoundation

/// Text-to-speech: Apple on-device voices (free, offline) or pre-rendered audio (OpenAI TTS).
@MainActor
final class Speaker: NSObject, ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentID: ObjectIdentifier?

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    /// Speaks with the best installed Apple voice for `language` (e.g. "en-US", "zh-TW").
    func speak(_ text: String, language: String = "en-US", rate: Float = 0.48) async {
        stop()
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice(for: language)
        u.rate = rate
        u.postUtteranceDelay = 0.15
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            currentID = ObjectIdentifier(u)
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
    }

    fileprivate func done(_ id: ObjectIdentifier) {
        guard id == currentID, let c = continuation else { return }
        continuation = nil
        currentID = nil
        c.resume()
    }

    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        // premium > enhanced > default. Download better voices in
        // Settings > Accessibility > Spoken Content > Voices.
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
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
            for (text, lang) in segments {
                if Task.isCancelled { break }
                await speaker.speak(text, language: lang, rate: rate)
            }
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

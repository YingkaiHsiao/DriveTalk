import Foundation
import AVFoundation

/// Background music generated in the app (no files, no network, no copyright issues).
/// It is ducked (turned down) while it's the user's turn to speak, so it doesn't disturb recognition.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isPreviewing = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: MusicSynth.sampleRate, channels: 2)!
    private var cache: [MusicStyle: AVAudioPCMBuffer] = [:]
    private var baseVolume: Float = 0.35
    private var ducked = false
    private var rampTask: Task<Void, Never>?
    private var currentStyle: MusicStyle?
    private var configObserver: NSObjectProtocol?

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        }
    }

    /// Picks a style that fits the practice mode / scenario.
    static func style(for mode: PracticeMode, scenario: Scenario?, preferred: MusicStyle) -> MusicStyle {
        guard preferred == .auto else { return preferred }
        switch mode {
        case .free: return .lofi
        case .rolePlay:
            if let id = scenario?.id, ["airport", "hotel", "restaurant"].contains(id) { return .travel }
            return .lofi
        case .workTech, .vocabReview: return .focus
        case .news: return .news
        case .shadowing: return .calm
        }
    }

    func start(style: MusicStyle, volume: Double) async {
        let style = style == .auto ? .lofi : style
        baseVolume = Float(volume) * 0.6           // music stays well under the voice
        let buffer = await buffer(for: style)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        if currentStyle != style || !node.isPlaying {
            node.stop()
            node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            node.volume = 0
            node.play()
            currentStyle = style
        }
        isPlaying = true
        ramp(to: ducked ? baseVolume * 0.12 : baseVolume, seconds: 1.5)
    }

    func stop() {
        isPlaying = false
        isPreviewing = false
        currentStyle = nil
        rampTask?.cancel()
        node.stop()
        engine.stop()
    }

    /// Lower the music while the user is speaking.
    func setDucked(_ value: Bool) {
        guard ducked != value else { return }
        ducked = value
        guard isPlaying else { return }
        ramp(to: value ? baseVolume * 0.12 : baseVolume, seconds: value ? 0.3 : 0.8)
    }

    func setVolume(_ volume: Double) {
        baseVolume = Float(volume) * 0.6
        if isPlaying { ramp(to: ducked ? baseVolume * 0.12 : baseVolume, seconds: 0.3) }
    }

    func togglePreview(style: MusicStyle, volume: Double) {
        if isPreviewing || (isPlaying && !AudioSessionManager.practiceActive) {
            stop()
            return
        }
        if !AudioSessionManager.practiceActive {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        }
        ducked = false
        isPreviewing = true
        Task { await start(style: style, volume: volume) }
    }

    /// After a phone call or a Bluetooth route change the engine stops; start it again.
    func resumeIfNeeded() {
        guard isPlaying, let style = currentStyle else { return }
        currentStyle = nil
        Task { await start(style: style, volume: Double(baseVolume / 0.6)) }
    }

    private func ramp(to target: Float, seconds: Double) {
        rampTask?.cancel()
        let startVol = node.volume
        let steps = max(1, Int(seconds * 20))
        rampTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.node.volume = startVol + (target - startVol) * Float(i) / Float(steps)
            }
        }
    }

    private func buffer(for style: MusicStyle) async -> AVAudioPCMBuffer {
        if let b = cache[style] { return b }
        let rendered = await Task.detached(priority: .userInitiated) { MusicSynth.render(style) }.value
        let frames = AVAudioFrameCount(rendered.left.count)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        rendered.left.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: Int(frames))
        }
        rendered.right.withUnsafeBufferPointer { src in
            buf.floatChannelData![1].update(from: src.baseAddress!, count: Int(frames))
        }
        cache[style] = buf
        return buf
    }
}

/// A tiny offline synthesizer: soft pads, bass, plucked arpeggio and light percussion,
/// rendered into a seamless loop.
enum MusicSynth {
    static let sampleRate: Double = 22_050

    struct Preset {
        let bpm: Double
        let chords: [[Int]]          // MIDI notes
        let pad: Float
        let pluck: Float
        let bass: Float
        let drums: Float
        let arpEighths: Bool
        let bassEighths: Bool
    }

    static func preset(_ style: MusicStyle) -> Preset {
        switch style {
        case .auto, .lofi:
            return Preset(bpm: 74, chords: [[57, 60, 64, 67], [50, 57, 60, 65], [55, 59, 62, 65], [48, 55, 59, 64]],
                          pad: 0.10, pluck: 0.10, bass: 0.16, drums: 0.10, arpEighths: false, bassEighths: false)
        case .focus:
            return Preset(bpm: 62, chords: [[48, 55, 59, 64], [45, 52, 55, 60], [41, 48, 52, 57], [43, 50, 55, 59]],
                          pad: 0.12, pluck: 0.07, bass: 0.12, drums: 0, arpEighths: true, bassEighths: false)
        case .news:
            return Preset(bpm: 96, chords: [[50, 57, 62, 65], [46, 53, 58, 62], [41, 48, 53, 57], [48, 55, 60, 64]],
                          pad: 0.08, pluck: 0.06, bass: 0.15, drums: 0.12, arpEighths: false, bassEighths: true)
        case .travel:
            return Preset(bpm: 104, chords: [[48, 55, 60, 64], [43, 50, 55, 59], [45, 52, 57, 60], [41, 48, 53, 57]],
                          pad: 0.07, pluck: 0.11, bass: 0.14, drums: 0.09, arpEighths: true, bassEighths: false)
        case .calm:
            return Preset(bpm: 56, chords: [[41, 48, 52, 57], [40, 47, 50, 55], [38, 45, 48, 53], [36, 43, 47, 52]],
                          pad: 0.13, pluck: 0.04, bass: 0.08, drums: 0, arpEighths: false, bassEighths: false)
        }
    }

    static func render(_ style: MusicStyle) -> (left: [Float], right: [Float]) {
        let p = preset(style)
        let spb = 60.0 / p.bpm                     // seconds per beat
        let beatsPerChord = 8
        let totalBeats = beatsPerChord * p.chords.count
        let n = Int(Double(totalBeats) * spb * sampleRate)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)

        func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

        /// Adds a note; samples past the end wrap to the start so the loop is seamless.
        func note(_ f: Double, at start: Double, length: Double, amp: Float, pan: Float,
                  attack: Double, decay: Double?, release: Double, harmonics: [Float]) {
            let s0 = Int(start * sampleRate)
            let total = Int((length + release) * sampleRate)
            let gl = (1 - pan) * 0.5 + 0.25, gr = (1 + pan) * 0.5 + 0.25
            let w = 2 * Double.pi * f / sampleRate
            for i in 0..<total {
                let t = Double(i) / sampleRate
                var env = min(1, t / attack)
                if let decay { env *= exp(-t / decay) }
                if t > length { env *= max(0, 1 - (t - length) / release) }
                var v: Double = 0
                for (h, a) in harmonics.enumerated() { v += Double(a) * sin(w * Double(h + 1) * Double(i)) }
                let x = Float(v * env) * amp
                let idx = (s0 + i) % n
                left[idx] += x * gl
                right[idx] += x * gr
            }
        }

        var rng = SystemRandomNumberGenerator()
        for (ci, chord) in p.chords.enumerated() {
            let chordStart = Double(ci * beatsPerChord) * spb
            let chordLen = Double(beatsPerChord) * spb

            // Pad: soft, slow sines spread across the stereo field
            if p.pad > 0 {
                for (k, m) in chord.enumerated() {
                    note(freq(m + 12), at: chordStart, length: chordLen, amp: p.pad, pan: Float(k) / 2 - 0.75,
                         attack: 1.2, decay: nil, release: 1.5, harmonics: [1, 0.25])
                }
            }
            // Bass: root, one or two octaves down
            if p.bass > 0 {
                let step = p.bassEighths ? 0.5 : 2.0
                var b = 0.0
                while b < Double(beatsPerChord) {
                    note(freq(chord[0] - 12), at: chordStart + b * spb, length: step * spb * 0.9, amp: p.bass, pan: 0,
                         attack: 0.01, decay: 0.6, release: 0.08, harmonics: [1, 0.3])
                    b += step
                }
            }
            // Plucked arpeggio (electric-piano-like)
            if p.pluck > 0 {
                let step = p.arpEighths ? 0.5 : 1.0
                var b = 0.0, k = 0
                while b < Double(beatsPerChord) {
                    let m = chord[(k % (chord.count - 1)) + 1] + 12
                    note(freq(m), at: chordStart + b * spb, length: 0.35, amp: p.pluck, pan: k % 2 == 0 ? -0.4 : 0.4,
                         attack: 0.005, decay: 0.35, release: 0.2, harmonics: [1, 0.4, 0.15])
                    b += step
                    k += 1
                }
            }
        }

        // Light drums: soft kick on 1 & 3, hi-hat on eighths (lo-fi swing)
        if p.drums > 0 {
            for beat in 0..<totalBeats {
                let t0 = Double(beat) * spb
                if beat % 2 == 0 {
                    let s0 = Int(t0 * sampleRate), len = Int(0.18 * sampleRate)
                    var phase = 0.0
                    for i in 0..<len {
                        let t = Double(i) / sampleRate
                        phase += 2 * .pi * (95 - 50 * t / 0.18) / sampleRate
                        let x = Float(sin(phase) * exp(-t / 0.06)) * p.drums * 1.6
                        let idx = (s0 + i) % n
                        left[idx] += x; right[idx] += x
                    }
                }
                for half in 0..<2 {
                    let swing = half == 1 ? 0.58 : 0.0
                    let s0 = Int((t0 + swing * spb) * sampleRate), len = Int(0.03 * sampleRate)
                    var prev: Float = 0
                    for i in 0..<len {
                        let noise = Float.random(in: -1...1, using: &rng)
                        let hp = noise - prev          // crude high-pass → "tss"
                        prev = noise
                        let x = hp * Float(exp(-Double(i) / Double(len) * 4)) * p.drums * 0.25
                        let idx = (s0 + i) % n
                        left[idx] += x * 0.8; right[idx] += x
                    }
                }
            }
        }

        // Warmth (one-pole low-pass) + normalize
        var l: Float = 0, r: Float = 0, peak: Float = 0.0001
        for i in 0..<n {
            l += 0.35 * (left[i] - l); r += 0.35 * (right[i] - r)
            left[i] = l; right[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        let gain = 0.5 / peak
        for i in 0..<n { left[i] *= gain; right[i] *= gain }
        return (left, right)
    }
}

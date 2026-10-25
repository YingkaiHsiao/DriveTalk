import SwiftUI

/// Main screen: designed to be started BEFORE driving, then used entirely by voice.
struct DriveView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: ConversationEngine
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showTranscript = false
    @State private var showHelp = false

    private var active: Bool { engine.phase != .idle }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                VStack(spacing: 18) {
                    header
                    Spacer(minLength: 8)
                    statusOrb
                    captions
                    Spacer(minLength: 8)
                    if let err = engine.errorText {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.pause)
                            .multilineTextAlignment(.leading)
                            .themeCard(padding: 12)
                    }
                    if active && settings.usageContext == .everyday { controlRow }
                    bigButton
                    if !active { voiceCommandHint }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // Fill the screen when there's room (Spacers work), scroll when there isn't (no overlap).
                .frame(minHeight: geo.size.height)
                // No implicit animations on this screen: nothing slides / flies in or out.
                .transaction { $0.animation = nil }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(AppBackground())
            .navigationTitle("English Mate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .disabled(active)
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("使用說明")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showTranscript = true } label: { Image(systemName: "text.bubble") }
                        .disabled(engine.messages.isEmpty)
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(active)
                }
            }
            .onAppear { LLMService.warmUp(settings.provider) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHelp) { HelpView() }
            .sheet(isPresented: $showHistory) { HistoryView(store: engine.history) }
            .sheet(isPresented: $showTranscript) { TranscriptView(messages: engine.messages) }
            .sheet(item: $engine.finishedSession) { record in
                NavigationStack { SessionDetailView(record: record) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            if !active {
                Picker("使用情境", selection: $settings.usageContext) {
                    ForEach(UsageContext.allCases) { c in
                        Label(c == .driving ? "開車練習" : "一般練習", systemImage: c.icon).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            Text(settings.sessionTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let sub = engine.sessionSubtitle, active, engine.shadowTarget == nil {
                Text(sub)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Chip(text: settings.activeModel, icon: "cpu")
                Chip(text: settings.level.rawValue, icon: "chart.bar.fill", color: Theme.speak)
                if settings.feedbackEnabled { Chip(text: "糾錯", icon: "checkmark.bubble", color: Theme.listen) }
                if settings.musicEnabled { Chip(text: "音樂", icon: "music.note", color: Theme.think) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if let t = engine.lastLatency, active {
                Label(String(format: "AI 回應 %.1f 秒", t), systemImage: "bolt.fill")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(t > 3 ? Theme.pause : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Status orb

    private var orbColor: Color {
        switch engine.phase {
        case .listening: return Theme.listen
        case .thinking, .summarizing, .preparing: return Theme.think
        case .speaking: return Theme.speak
        case .paused: return Theme.pause
        case .idle: return Theme.accent
        }
    }

    private var statusOrb: some View {
        let big = active
        let pulsing = engine.phase == .listening || engine.phase == .speaking || engine.phase == .thinking
        return VStack(spacing: 12) {
            ZStack {
                // Soft glow rings — the "breathing" only scales, so the layout never moves.
                PulseRing(color: orbColor.opacity(0.14), size: big ? 196 : 150, amount: 0.06,
                          period: engine.phase == .listening ? 1.4 : 2.6, running: pulsing)
                PulseRing(color: orbColor.opacity(0.22), size: big ? 158 : 120, amount: 0.03,
                          period: engine.phase == .listening ? 1.4 : 2.6, running: pulsing)
                Circle()
                    .fill(RadialGradient(colors: [orbColor.opacity(0.85), orbColor], center: .topLeading,
                                         startRadius: 10, endRadius: 120))
                    .frame(width: big ? 124 : 96, height: big ? 124 : 96)
                    .shadow(color: orbColor.opacity(0.5), radius: big ? 22 : 12)
                Image(systemName: icon)
                    .font(.system(size: big ? 46 : 38, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: engine.phase == .speaking || engine.phase == .listening)
            }
            .frame(width: 210, height: big ? 206 : 156)

            Text(engine.phase.label)
                .font(.title2.weight(.bold))
                .foregroundStyle(engine.phase == .idle ? Color.primary : orbColor)
        }
    }

    private var icon: String {
        switch engine.phase {
        case .listening: return "mic.fill"
        case .speaking: return "speaker.wave.3.fill"
        case .thinking, .summarizing, .preparing: return "ellipsis"
        case .paused: return "pause.fill"
        case .idle: return settings.usageContext.icon
        }
    }

    // MARK: Captions (glanceable only — the app never requires reading)

    @ViewBuilder
    private var captions: some View {
        let fallback = engine.messages.last(where: { $0.role == .assistant })?.text ?? ""
        let feedback = engine.messages.last(where: { $0.role == .user })?.feedback
        if active {
            VStack(spacing: 12) {
                if let target = engine.shadowTarget, active {
                    // Shadowing: keep the sentence to repeat on screen; what you say appears below it.
                    VStack(spacing: 6) {
                        Text(target.en)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .minimumScaleFactor(0.7)
                        if !target.zh.isEmpty {
                            Text(target.zh)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                        }
                    }
                    Divider()
                    ShadowHeardCaption(recognizer: engine.recognizer, listening: engine.phase == .listening)
                } else {
                    RecognizerCaption(recognizer: engine.recognizer,
                                      listening: engine.phase == .listening,
                                      fallback: fallback)
                }
                if let fb = feedback, active {
                    Label(fb, systemImage: "lightbulb.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.tip)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.tipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .themeCard()
        }
    }

    // MARK: Start / stop

    private var bigButton: some View {
        Button {
            if active { engine.stop() } else { engine.start(settings: settings) }
        } label: {
            Label(active ? "結束練習" : "開始練習", systemImage: active ? "stop.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(active ? Theme.stopGradient : Theme.startGradient,
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: (active ? Color.red : Color.green).opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(engine.phase == .summarizing)
        .opacity(engine.phase == .summarizing ? 0.6 : 1)
        .sensoryFeedback(.impact(weight: .medium), trigger: active)
    }

    /// Everyday mode: buttons instead of (or in addition to) voice commands.
    private var controlRow: some View {
        HStack(spacing: 10) {
            if engine.phase == .listening {
                controlButton("說完了", "checkmark.circle.fill", Theme.listen) { engine.endUserTurn() }
            } else if engine.phase == .speaking {
                controlButton("略過", "forward.fill", Theme.speak) { engine.skipSpeech() }
            }
            controlButton("重播", "arrow.counterclockwise", Theme.accent) { engine.send(.repeatLast) }
            controlButton("翻譯", "character.bubble", Theme.accent) { engine.send(.translate) }
            if engine.shadowTarget != nil {
                controlButton("下一句", "forward.end.fill", Theme.accent) { engine.send(.skip) }
            }
        }
        .disabled(engine.phase == .preparing || engine.phase == .summarizing)
    }

    private func controlButton(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3.weight(.semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var voiceCommandHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(settings.usageContext == .driving ? "出發前按開始，行車中全程用說的" : "可以用說的，也可以點畫面上的按鈕",
                  systemImage: settings.usageContext == .driving ? "hand.raised.fill" : "hand.tap.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(["Translate", "Repeat", "Slow down", "Chinese please", "Next", "Stop practice"], id: \.self) { c in
                    Chip(text: c, icon: "waveform", color: Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(padding: 12)
    }
}

/// A circle that gently scales in and out. Driven by TimelineView, so it can't drag the rest of
/// the screen into the animation (which made the centre jump in and out at launch).
private struct PulseRing: View {
    let color: Color
    let size: CGFloat
    let amount: Double
    let period: Double
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let scale = running ? 1 + amount * sin(t * 2 * .pi / period) : 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(scale)
        }
    }
}

/// Shadowing: what you're saying, shown under the target sentence.
private struct ShadowHeardCaption: View {
    @ObservedObject var recognizer: SpeechRecognizer
    let listening: Bool

    var body: some View {
        if listening {
            if recognizer.transcribing {
                Label("辨識中…", systemImage: "waveform").foregroundStyle(Theme.heard)
            } else if recognizer.partial.isEmpty {
                Label("請跟著唸", systemImage: "mic.fill").foregroundStyle(Theme.heard)
            } else {
                Text(recognizer.partial)
                    .font(.body)
                    .foregroundStyle(Theme.heard)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }
}

/// Observes the recognizer directly so partial captions update live.
private struct RecognizerCaption: View {
    @ObservedObject var recognizer: SpeechRecognizer
    let listening: Bool
    let fallback: String

    var body: some View {
        if listening && recognizer.transcribing {
            Label("辨識中…", systemImage: "waveform")
                .font(.title3)
                .foregroundStyle(Theme.heard)
        } else if listening && !recognizer.partial.isEmpty {
            Text(recognizer.partial)
                .font(.title3)
                .foregroundStyle(Theme.heard)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        } else {
            Text(fallback)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
    }
}

struct TranscriptView: View {
    let messages: [ChatMessage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TranscriptList(messages: messages)
                .navigationTitle("對話紀錄")
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct TranscriptList: View {
    let messages: [ChatMessage]
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(messages) { m in
                    HStack {
                        if m.role == .user { Spacer(minLength: 40) }
                        VStack(alignment: m.role == .user ? .trailing : .leading, spacing: 6) {
                            Text(m.text)
                                .foregroundStyle(m.role == .user ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(m.role == .user ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .textSelection(.enabled)
                            if let fb = m.feedback, !fb.isEmpty {
                                Label(fb, systemImage: "lightbulb.fill")
                                    .font(.callout)
                                    .foregroundStyle(Theme.tip)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.tipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        if m.role == .assistant { Spacer(minLength: 40) }
                    }
                }
            }
            .padding()
        }
        .background(AppBackground())
    }
}

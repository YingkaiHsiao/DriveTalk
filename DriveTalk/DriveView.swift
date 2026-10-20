import SwiftUI

/// Main screen: designed to be started BEFORE driving, then used entirely by voice.
struct DriveView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: ConversationEngine
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showTranscript = false

    private var active: Bool { engine.phase != .idle }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                header
                Spacer(minLength: 0)
                statusOrb
                captions
                Spacer(minLength: 0)
                if let err = engine.errorText {
                    Text(err)
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                bigButton
                if !active { voiceCommandHint }
            }
            .padding()
            .navigationTitle("DriveTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .disabled(active)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showTranscript = true } label: { Image(systemName: "text.bubble") }
                        .disabled(engine.messages.isEmpty)
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(active)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView(store: engine.history) }
            .sheet(isPresented: $showTranscript) { TranscriptView(messages: engine.messages) }
            .sheet(item: $engine.finishedSession) { record in
                NavigationStack { SessionDetailView(record: record) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(settings.sessionTitle)
                .font(.headline)
            if let sub = engine.sessionSubtitle, active {
                Text(sub)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text("\(settings.provider.rawValue)・\(settings.level.rawValue)\(settings.feedbackEnabled ? "・即時糾錯" : "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let t = engine.lastLatency, active {
                Text("AI 回應 \(t, specifier: "%.1f") 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(t > 4 ? Color.orange : Color.secondary)
            }
        }
    }

    private var orbColor: Color {
        switch engine.phase {
        case .listening: return .green
        case .thinking, .summarizing, .preparing: return .yellow
        case .speaking: return .blue
        case .paused: return .orange
        case .idle: return .gray
        }
    }

    private var statusOrb: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(orbColor.opacity(0.25))
                    .frame(width: 170, height: 170)
                    .scaleEffect(engine.phase == .listening ? 1.08 : 1.0)
                    .animation(engine.phase == .listening
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : .default, value: engine.phase)
                Circle()
                    .fill(orbColor)
                    .frame(width: 120, height: 120)
                Image(systemName: icon)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(engine.phase.label)
                .font(.title.bold())
        }
    }

    private var icon: String {
        switch engine.phase {
        case .listening: return "mic.fill"
        case .speaking: return "speaker.wave.3.fill"
        case .thinking, .summarizing, .preparing: return "ellipsis"
        case .paused: return "pause.fill"
        case .idle: return "car.fill"
        }
    }

    /// Large captions (glanceable only — the app never requires reading).
    private var captions: some View {
        VStack(spacing: 10) {
            RecognizerCaption(recognizer: engine.recognizer,
                              listening: engine.phase == .listening,
                              fallback: engine.messages.last(where: { $0.role == .assistant })?.text ?? "")
            if let fb = engine.messages.last(where: { $0.role == .user })?.feedback, active {
                Text(fb)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(minHeight: 120)
        .padding(.horizontal)
    }

    private var bigButton: some View {
        Button {
            if active { engine.stop() } else { engine.start(settings: settings) }
        } label: {
            Label(active ? "結束練習" : "開始練習", systemImage: active ? "stop.fill" : "play.fill")
                .font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 96)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? .red : .green)
        .disabled(engine.phase == .summarizing)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var voiceCommandHint: some View {
        Text("請在出發前按下開始，行車中全程用語音。\n語音指令：「repeat」「slow down」「speak faster」「next news」「stop practice」\n不懂的字直接問：「What does … mean?」")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

/// Observes the recognizer directly so partial captions update live.
private struct RecognizerCaption: View {
    @ObservedObject var recognizer: SpeechRecognizer
    let listening: Bool
    let fallback: String

    var body: some View {
        if listening && !recognizer.partial.isEmpty {
            Text(recognizer.partial)
                .font(.title3)
                .foregroundStyle(.green)
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
        List(messages) { m in
            VStack(alignment: .leading, spacing: 6) {
                Text(m.role == .user ? "你" : "AI")
                    .font(.caption.bold())
                    .foregroundStyle(m.role == .user ? .green : .blue)
                Text(m.text)
                if let fb = m.feedback, !fb.isEmpty {
                    Label(fb, systemImage: "lightbulb.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

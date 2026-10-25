import SwiftUI

// MARK: - 生字本 tab (words + expressions + smart review)

struct VocabView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: ConversationEngine
    @EnvironmentObject var router: AppRouter
    @ObservedObject private var vocab = VocabStore.shared
    @ObservedObject private var progress = ProgressStore.shared
    @State private var tab = 0
    @State private var showReview = false

    private var dueCount: Int { vocab.dueEntries.count + progress.dueExpressions.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                smartReviewBanner
                Picker("", selection: $tab) {
                    Text("單字 \(vocab.entries.count)").tag(0)
                    Text("表達方式 \(progress.expressions.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if tab == 0 { WordListView() } else { ExpressionListView() }
            }
            .themeBackground()
            .navigationTitle("生字本")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showReview) { SmartReviewView() }
        }
    }

    private var smartReviewBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("智慧複習").font(.headline)
                    Text(dueCount > 0 ? "今天有 \(dueCount) 個到期要複習" : "目前沒有到期的項目 👍")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("已熟記 \(vocab.masteredCount) 個單字（3 週以上不忘）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button {
                    showReview = true
                } label: {
                    Label("卡片複習", systemImage: "rectangle.on.rectangle.angled").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vocab.entries.isEmpty && progress.expressions.isEmpty)

                Button {
                    settings.mode = .vocabReview
                    engine.start(settings: settings)
                    router.tab = .practice
                } label: {
                    Label("開車語音複習", systemImage: "car.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.phase != .idle || (vocab.entries.isEmpty && progress.expressions.isEmpty))
            }
        }
        .themeCard()
        .padding()
    }
}

private struct WordListView: View {
    @ObservedObject private var vocab = VocabStore.shared
    @ObservedObject private var pron = Pronouncer.shared
    @State private var search = ""
    @State private var selected: WordRef?

    private var filtered: [VocabEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vocab.entries }
        return vocab.entries.filter { $0.key.contains(q) || $0.info.meaningZh.contains(q) }
    }

    var body: some View {
        Group {
            if vocab.entries.isEmpty {
                ContentUnavailableView("生字本是空的", systemImage: "bookmark",
                                       description: Text("查詢單字、閱讀新聞時按「加入生字本」，或開車時用語音問單字，都會自動收進來。"))
            } else {
                List {
                    Section {
                        ForEach(filtered) { e in
                            Button { selected = WordRef(word: e.info.word, hint: e.info) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.info.word).font(.headline).foregroundStyle(.primary)
                                        Text(e.info.meaningZh).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ReviewBadge(state: e.review)
                                    Button { pron.speak(e.info.word, rate: 0.4) } label: {
                                        Image(systemName: "speaker.wave.1")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .onDelete { vocab.delete(at: $0, in: filtered) }
                    }
                }
                .searchable(text: $search, prompt: "搜尋單字或中文")
                .toolbar {
                    Button {
                        if pron.speakingID == "vocab-all" { pron.stop(); return }
                        let segs = filtered.prefix(50).flatMap { [($0.info.word, "en-US"), ($0.info.meaningZh, "zh-TW")] }
                        pron.speakSequence(Array(segs), id: "vocab-all", rate: 0.42)
                    } label: {
                        Label(pron.speakingID == "vocab-all" ? "停止" : "全部朗讀",
                              systemImage: pron.speakingID == "vocab-all" ? "stop.fill" : "play.fill")
                    }
                }
            }
        }
        .sheet(item: $selected) { ref in
            WordLookupSheet(word: ref.word, source: "查詢", hint: ref.hint)
        }
    }
}

/// Small label showing when an item is due again.
struct ReviewBadge: View {
    let state: ReviewState
    var body: some View {
        Group {
            if state.isDue {
                Text("待複習").foregroundStyle(.orange)
            } else if state.isMastered {
                Text("已熟記").foregroundStyle(.green)
            } else {
                Text(state.due.formatted(.relative(presentation: .numeric))).foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

private struct ExpressionListView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: ConversationEngine
    @EnvironmentObject var router: AppRouter
    @ObservedObject private var progress = ProgressStore.shared
    @ObservedObject private var pron = Pronouncer.shared

    var body: some View {
        if progress.expressions.isEmpty {
            ContentUnavailableView("還沒有表達方式", systemImage: "text.quote",
                                   description: Text("開啟「即時糾錯」練習對話，或用「查詢 > 文法修正」，更自然的說法會自動收進來。"))
        } else {
            List {
                Section {
                    Button {
                        engine.start(settings: settings, shadowSaved: true)
                        router.tab = .practice
                    } label: {
                        Label("跟讀這些句子（開車可用）", systemImage: "repeat")
                    }
                    .disabled(engine.phase != .idle)
                }
                Section {
                    ForEach(progress.expressions) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text(e.better).font(.body.weight(.semibold))
                                Spacer()
                                Button { pron.speak(e.better) } label: { Image(systemName: "speaker.wave.1") }
                                    .buttonStyle(.borderless)
                            }
                            if !e.original.isEmpty {
                                Text(e.original).font(.callout).strikethrough().foregroundStyle(.secondary)
                            }
                            if !e.note.isEmpty {
                                Text(e.note).font(.caption).foregroundStyle(Theme.tip)
                            }
                            HStack {
                                Text("\(e.source)・\(e.date.formatted(date: .abbreviated, time: .omitted))")
                                Spacer()
                                ReviewBadge(state: e.review)
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                    .onDelete { offsets in
                        progress.deleteExpressions(ids: Set(offsets.map { progress.expressions[$0].id }))
                    }
                }
            }
        }
    }
}

// MARK: - Smart review (flashcards with spaced repetition)

private enum ReviewCard: Identifiable {
    case word(VocabEntry, reverse: Bool)     // reverse = show Chinese, recall English
    case expression(SavedExpression)

    var id: String {
        switch self {
        case .word(let e, let r): return "w-\(e.id)-\(r)"
        case .expression(let e): return "e-\(e.id)"
        }
    }

    var state: ReviewState {
        switch self {
        case .word(let e, _): return e.review
        case .expression(let e): return e.review
        }
    }
}

struct SmartReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pron = Pronouncer.shared
    @State private var queue: [ReviewCard] = []
    @State private var revealed = false
    @State private var done = 0
    @State private var remembered = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let card = queue.first {
                    Text("剩下 \(queue.count) 張・已完成 \(done)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    front(card)
                    if revealed { back(card) }
                    Spacer()
                    if revealed { gradeButtons(card) } else {
                        Button {
                            withAnimation { revealed = true }
                            if case .expression(let e) = card { pron.speak(e.better) }
                            if case .word(let e, true) = card { pron.speak(e.info.word, rate: 0.4) }
                        } label: {
                            Text("顯示答案").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if loaded {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(.green)
                    Text(done == 0 ? "目前沒有需要複習的項目" : "完成 \(done) 張！記得 \(remembered) 張")
                        .font(.title2.bold())
                    Text("系統會依你的記憶狀況，在快忘記的時候再安排複習。")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("智慧複習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("結束") { dismiss() } }
        }
        .onAppear(perform: load)
        .onDisappear { pron.stop() }
    }

    private func load() {
        guard !loaded else { return }
        var cards: [ReviewCard] = VocabStore.shared.dueEntries.prefix(30).map { ReviewCard.word($0, reverse: Bool.random()) }
        cards += ProgressStore.shared.dueExpressions.prefix(10).map { ReviewCard.expression($0) }
        queue = cards.shuffled()
        loaded = true
        speakFront()
    }

    private func speakFront() {
        if case .word(let e, false) = queue.first { pron.speak(e.info.word, rate: 0.4) }
    }

    @ViewBuilder
    private func front(_ card: ReviewCard) -> some View {
        switch card {
        case .word(let e, let reverse):
            VStack(spacing: 10) {
                Text(reverse ? "英文怎麼說？" : "這個字是什麼意思？").font(.callout).foregroundStyle(.secondary)
                Text(reverse ? e.info.meaningZh : e.info.word)
                    .font(.system(size: 38, weight: .bold))
                    .multilineTextAlignment(.center)
                if !reverse {
                    Button { pron.speak(e.info.word, rate: 0.4) } label: { Image(systemName: "speaker.wave.2.fill").font(.title2) }
                }
            }
        case .expression(let e):
            VStack(spacing: 10) {
                Text("這句怎麼說更自然？").font(.callout).foregroundStyle(.secondary)
                Text(e.original.isEmpty ? e.note : e.original)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func back(_ card: ReviewCard) -> some View {
        VStack(spacing: 8) {
            Divider()
            switch card {
            case .word(let e, let reverse):
                Text(reverse ? e.info.word : e.info.meaningZh).font(.title.bold())
                if !e.info.phonetic.isEmpty { Text(e.info.phonetic).foregroundStyle(.secondary) }
                if let ex = e.info.examples.first {
                    Text(ex.en).font(.callout)
                    Text(ex.zh).font(.caption).foregroundStyle(.secondary)
                }
            case .expression(let e):
                Text(e.better).font(.title3.bold()).foregroundStyle(.green).multilineTextAlignment(.center)
                if !e.note.isEmpty { Text(e.note).font(.callout).foregroundStyle(.secondary) }
                Button { pron.speak(e.better) } label: { Label("再聽一次", systemImage: "speaker.wave.2") }
            }
        }
        .multilineTextAlignment(.center)
        .transition(.opacity)
    }

    private func gradeButtons(_ card: ReviewCard) -> some View {
        HStack(spacing: 8) {
            ForEach(ReviewState.Grade.allCases, id: \.rawValue) { g in
                Button {
                    grade(card, g)
                } label: {
                    VStack(spacing: 2) {
                        Text(g.label).font(.headline)
                        Text(ReviewState.preview(g, from: card.state)).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(color(g))
            }
        }
    }

    private func color(_ g: ReviewState.Grade) -> Color {
        switch g {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }

    private func grade(_ card: ReviewCard, _ g: ReviewState.Grade) {
        switch card {
        case .word(let e, _): VocabStore.shared.grade(e.id, g)
        case .expression(let e): ProgressStore.shared.gradeExpression(e.id, g)
        }
        queue.removeFirst()
        done += 1
        if g != .again { remembered += 1 }
        // Forgotten cards come back at the end of this session.
        if g == .again {
            switch card {
            case .word(let e, let r):
                if let fresh = VocabStore.shared.entries.first(where: { $0.id == e.id }) { queue.append(.word(fresh, reverse: r)) }
            case .expression(let e):
                if let fresh = ProgressStore.shared.expressions.first(where: { $0.id == e.id }) { queue.append(.expression(fresh)) }
            }
        }
        revealed = false
        speakFront()
    }
}

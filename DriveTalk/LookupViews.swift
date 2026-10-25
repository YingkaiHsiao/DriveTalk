import SwiftUI

// MARK: - Shared word detail

/// Full dictionary card for one word, with pronunciation and save-to-vocab.
struct WordDetailContent: View {
    let info: WordInfo
    let source: String
    @ObservedObject private var vocab = VocabStore.shared
    @ObservedObject private var pron = Pronouncer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.word).font(.largeTitle.bold())
                Spacer()
                Button {
                    pron.speak(info.word, rate: 0.4)
                } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.title2)
                }
                .accessibilityLabel("發音")
            }
            HStack(spacing: 8) {
                if !info.phonetic.isEmpty { Text(info.phonetic).foregroundStyle(.secondary) }
                if !info.partOfSpeech.isEmpty {
                    Text(info.partOfSpeech)
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.chip, in: Capsule())
                }
            }
            Text(info.meaningZh).font(.title3.weight(.semibold))
            if !info.definitionEn.isEmpty {
                Text(info.definitionEn).foregroundStyle(.secondary)
            }

            if !info.examples.isEmpty {
                Divider()
                Text("例句").font(.headline)
                ForEach(info.examples, id: \.self) { ex in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.en)
                            Text(ex.zh).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { pron.speak(ex.en) } label: { Image(systemName: "speaker.wave.1") }
                    }
                }
            }
            if !info.synonyms.isEmpty {
                Text("近義：" + info.synonyms.joined(separator: ", ")).font(.callout)
            }
            if !info.note.isEmpty {
                Label(info.note, systemImage: "lightbulb.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.tip)
            }

            Button {
                if vocab.contains(info.word) { vocab.remove(info.word) } else { vocab.add(info, source: source) }
            } label: {
                Label(vocab.contains(info.word) ? "已加入生字本（點擊移除）" : "加入生字本",
                      systemImage: vocab.contains(info.word) ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(vocab.contains(info.word) ? .gray : .accentColor)
        }
        .textSelection(.enabled)
    }
}

/// Looks a word up (cache first: the vocab book) and shows the detail card. Used from news & vocab.
struct WordLookupSheet: View {
    let word: String
    let source: String
    var hint: WordInfo? = nil
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: WordInfo?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let info {
                        WordDetailContent(info: info, source: source)
                    } else if let error {
                        VStack(spacing: 12) {
                            if let hint { Text("\(hint.word)：\(hint.meaningZh)").font(.title3) }
                            Text(error).foregroundStyle(.orange)
                            Button("重試") { Task { await load() } }
                        }
                    } else {
                        VStack(spacing: 12) {
                            if let hint { Text("\(hint.word)：\(hint.meaningZh)").font(.title3) }
                            ProgressView("查詢中…")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("單字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        error = nil
        if let cached = VocabStore.shared.entries.first(where: { $0.key == word.lowercased() }),
           !cached.info.examples.isEmpty {
            info = cached.info
            return
        }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        do {
            let full = try await StudyService(settings: settings).lookup(word)
            info = full
            // Upgrade a short entry (saved from news/conversation) with the full lookup.
            if VocabStore.shared.contains(word) { VocabStore.shared.add(full, source: source) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Wrapper so a word can drive `.sheet(item:)`.
struct WordRef: Identifiable, Hashable {
    let word: String
    var hint: WordInfo? = nil
    var id: String { word.lowercased() }
}

// MARK: - 查詢 tab

struct LookupView: View {
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("單字").tag(0)
                    Text("翻譯").tag(1)
                    Text("文法修正").tag(2)
                    Text("中文發問").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case 0: WordLookupPane()
                case 1: TranslatePane()
                case 2: GrammarPane()
                default: AskPane()
                }
            }
            .themeBackground()
            .navigationTitle("查詢")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct WordLookupPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var query = ""
    @State private var result: WordInfo?
    @State private var loading = false
    @State private var error: String?
    @State private var recent: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("輸入英文單字／片語，或中文", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .onSubmit { Task { await search() } }
                    Button("查詢") { Task { await search() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }

                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.orange) }
                if let result { WordDetailContent(info: result, source: "查詢") }

                if result == nil && !recent.isEmpty {
                    Text("最近查詢").font(.headline)
                    ForEach(recent, id: \.self) { w in
                        Button(w) { query = w; Task { await search() } }
                    }
                }
                if result == nil && recent.isEmpty && !loading {
                    Text("開車時也可以直接用說的查：\n「What does mitigate mean?」\n「How do I say 延期 in English?」\nAI 會用語音解釋，並自動存進生字本。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        error = nil
        // Free & instant: reuse a full entry already in the vocab book.
        if let cached = VocabStore.shared.entries.first(where: { $0.key == q.lowercased() }),
           !cached.info.examples.isEmpty {
            result = cached.info
            return
        }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        loading = true
        defer { loading = false }
        do {
            result = try await StudyService(settings: settings).lookup(q)
            recent.removeAll { $0 == q }
            recent.insert(q, at: 0)
            if recent.count > 10 { recent.removeLast() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TranslatePane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var pron = Pronouncer.shared
    @State private var input = ""
    @State private var result: TranslationResult?
    @State private var resultForEnglish = true
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $input)
                    .focused($focused)
                    .frame(minHeight: 120)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("輸入中文 → 翻成英文；輸入英文 → 翻成中文")
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Button {
                        Task { await translate() }
                    } label: {
                        Label(input.containsChinese ? "翻成英文" : "翻成中文", systemImage: "character.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)

                    if !input.isEmpty {
                        Button("清除") { input = ""; result = nil }
                            .buttonStyle(.bordered)
                    }
                }

                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.orange) }

                if let r = result {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Text(r.translation).font(.title3.weight(.semibold))
                            Spacer()
                            if resultForEnglish {
                                Button { pron.speak(r.translation) } label: { Image(systemName: "speaker.wave.2.fill") }
                            }
                            Button { UIPasteboard.general.string = r.translation } label: { Image(systemName: "doc.on.doc") }
                        }
                        ForEach(r.alternatives.filter { !$0.isEmpty }, id: \.self) { alt in
                            HStack(alignment: .top) {
                                Text("・" + alt)
                                Spacer()
                                Button { pron.speak(alt) } label: { Image(systemName: "speaker.wave.1") }
                            }
                            .font(.callout)
                        }
                        if !r.notes.isEmpty {
                            Label(r.notes, systemImage: "lightbulb.fill")
                                .font(.callout)
                                .foregroundStyle(Theme.tip)
                        }
                        if !resultForEnglish {
                            Button { pron.speak(input) } label: { Label("朗讀英文原文", systemImage: "speaker.wave.2") }
                                .font(.callout)
                        }
                    }
                    .textSelection(.enabled)
                    .themeCard()
                }
            }
            .padding(.horizontal)
        }
    }

    private func translate() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        focused = false
        error = nil
        loading = true
        defer { loading = false }
        do {
            resultForEnglish = text.containsChinese
            result = try await StudyService(settings: settings).translate(text)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Reusable multi-line input with placeholder.
private struct InputBox: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextEditor(text: $text)
            .focused(focused)
            .frame(minHeight: 110)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct GrammarPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var pron = Pronouncer.shared
    @ObservedObject private var progress = ProgressStore.shared
    @State private var input = ""
    @State private var checked = ""
    @State private var result: GrammarResult?
    @State private var loading = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InputBox(text: $input, placeholder: "貼上或輸入你寫的英文（email、訊息、想說的話），幫你修正文法並改成更自然的說法",
                         focused: $focused)
                Button {
                    Task { await check() }
                } label: {
                    Label("修正文法", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)

                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.orange) }

                if let r = result {
                    VStack(alignment: .leading, spacing: 12) {
                        row(title: "修正後", text: r.corrected)
                        if !r.natural.isEmpty, r.natural != r.corrected {
                            row(title: "更自然的說法", text: r.natural)
                        }
                        if !r.issues.isEmpty {
                            Text("問題說明").font(.headline)
                            ForEach(r.issues, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(i.wrong).strikethrough().foregroundStyle(.red)
                                        Image(systemName: "arrow.right")
                                        Text(i.right).foregroundStyle(.green)
                                    }
                                    .font(.callout.weight(.semibold))
                                    Text(i.explainZh).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !r.summaryZh.isEmpty {
                            Label(r.summaryZh, systemImage: "lightbulb.fill").font(.callout).foregroundStyle(Theme.tip)
                        }
                        if !r.issues.isEmpty || r.natural != checked {
                            Button {
                                progress.addExpression(original: checked,
                                                       better: r.natural.isEmpty ? r.corrected : r.natural,
                                                       note: r.summaryZh, source: "文法修正")
                                saved = true
                            } label: {
                                Label(saved ? "已存到表達方式" : "存到表達方式（可跟讀練習）",
                                      systemImage: saved ? "checkmark" : "text.badge.plus")
                            }
                            .disabled(saved)
                        }
                    }
                    .textSelection(.enabled)
                    .themeCard()
                }
            }
            .padding(.horizontal)
        }
    }

    private func row(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(text).font(.body.weight(.semibold))
                Spacer()
                Button { pron.speak(text) } label: { Image(systemName: "speaker.wave.2.fill") }
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
            }
        }
    }

    private func check() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        focused = false
        error = nil
        saved = false
        loading = true
        defer { loading = false }
        do {
            checked = text
            result = try await StudyService(settings: settings).grammarCheck(text)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AskPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var pron = Pronouncer.shared
    @State private var input = ""
    @State private var answer: QAAnswer?
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let samples = ["affect 和 effect 差在哪？", "「我晚點回覆你」英文怎麼說比較自然？",
                           "什麼時候用 present perfect？", "跟客戶說「延期」用 postpone 還是 delay？"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InputBox(text: $input, placeholder: "用中文問任何英文問題", focused: $focused)
                Button {
                    Task { await ask() }
                } label: {
                    Label("發問", systemImage: "questionmark.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)

                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.orange) }

                if let a = answer {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text(a.answerZh)
                            Spacer()
                            Button {
                                if pron.speakingID == "qa" { pron.stop() }
                                else { pron.speak(a.answerZh, id: "qa", language: "zh-TW", rate: 0.5) }
                            } label: {
                                Image(systemName: pron.speakingID == "qa" ? "stop.fill" : "speaker.wave.2.fill")
                            }
                        }
                        ForEach(a.examples, id: \.self) { ex in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ex.en).font(.body.weight(.semibold))
                                    Text(ex.zh).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { pron.speak(ex.en) } label: { Image(systemName: "speaker.wave.1") }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .themeCard()
                } else if !loading {
                    Text("例如：").font(.callout).foregroundStyle(.secondary)
                    ForEach(samples, id: \.self) { q in
                        Button(q) { input = q; Task { await ask() } }.font(.callout)
                    }
                    Text("開車時也能用中文問：先說「Chinese please」再說中文（或在設定改用 OpenAI 高準確度辨識直接說中文），AI 會用中文語音解釋。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func ask() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        focused = false
        error = nil
        loading = true
        defer { loading = false }
        do {
            answer = try await StudyService(settings: settings).ask(q)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

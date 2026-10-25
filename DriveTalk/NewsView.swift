import SwiftUI

struct NewsView: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var store = NewsStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("類別", selection: $settings.newsCategory) {
                        ForEach(NewsCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                if let err = store.errorText {
                    Text(err).foregroundStyle(.orange)
                }

                Section {
                    ForEach(store.items) { item in
                        NavigationLink {
                            NewsReaderView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top) {
                                    Text(item.title).font(.headline)
                                    if store.cachedArticle(for: item, level: settings.level) != nil {
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel("已改寫")
                                    }
                                }
                                Text(item.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                if let d = item.pubDate {
                                    Text(d.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("新聞標題與摘要來自 BBC News RSS；AI 依你的程度（\(settings.level.rawValue)）改寫成短文。點進去才會使用 AI，看過的會存起來不重複消耗 token。")
                }
            }
            .overlay { if store.loading && store.items.isEmpty { ProgressView("載入新聞…") } }
            .themeBackground()
            .navigationTitle("新聞短文")
            .refreshable { await store.refresh(settings.newsCategory) }
            .task(id: settings.newsCategory) {
                if store.loadedCategory != settings.newsCategory || store.items.isEmpty {
                    await store.refresh(settings.newsCategory)
                }
            }
        }
    }
}

struct NewsReaderView: View {
    let item: NewsItem
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: ConversationEngine
    @EnvironmentObject var router: AppRouter
    @ObservedObject private var pron = Pronouncer.shared
    @ObservedObject private var vocab = VocabStore.shared
    @State private var article: NewsArticle?
    @State private var error: String?
    @State private var lookup: WordRef?

    private var readID: String { "news-" + item.link }

    var body: some View {
        ScrollView {
            if let a = article {
                content(a)
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.orange)
                    Button("重試") { Task { await load() } }
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("AI 依你的程度改寫中…").foregroundStyle(.secondary)
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                }
                .padding(.top, 60)
                .padding(.horizontal)
            }
        }
        .navigationTitle("新聞")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { if pron.speakingID == readID { pron.stop() } }
        .sheet(item: $lookup) { ref in
            WordLookupSheet(word: ref.word, source: "新聞", hint: ref.hint)
        }
    }

    @ViewBuilder
    private func content(_ a: NewsArticle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TappableText(text: a.title, font: .title2.bold()) { lookup = WordRef(word: $0) }

            HStack {
                Button {
                    if pron.speakingID == readID { pron.stop() }
                    else { pron.speakSequence(([a.title] + a.paragraphs).map { ($0, "en-US") }, id: readID,
                                              rate: Float(settings.speechRate)) }
                } label: {
                    Label(pron.speakingID == readID ? "停止" : "朗讀", systemImage: pron.speakingID == readID ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    pron.stop()
                    engine.start(settings: settings, article: a)
                    router.tab = .practice
                } label: {
                    Label("開車聽＋語音討論", systemImage: "car.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.phase != .idle)
            }

            Text("點任何單字可查詢").font(.caption).foregroundStyle(.secondary)

            ForEach(Array(a.paragraphs.enumerated()), id: \.offset) { _, p in
                TappableText(text: p, font: .body) { lookup = WordRef(word: $0) }
                    .lineSpacing(4)
            }

            if !a.vocabulary.isEmpty {
                Divider()
                Text("重點單字").font(.headline)
                ForEach(a.vocabulary, id: \.self) { v in
                    HStack {
                        Button { lookup = WordRef(word: v.word, hint: v) } label: {
                            VStack(alignment: .leading) {
                                Text(v.word).font(.body.weight(.semibold))
                                Text(v.meaningZh).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { pron.speak(v.word, rate: 0.4) } label: { Image(systemName: "speaker.wave.1") }
                            .buttonStyle(.borderless)
                        Button {
                            if vocab.contains(v.word) { vocab.remove(v.word) } else { vocab.add(v, source: "新聞") }
                        } label: {
                            Image(systemName: vocab.contains(v.word) ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("全部加入生字本") { a.vocabulary.forEach { vocab.add($0, source: "新聞") } }
                    .font(.callout)
            }

            if !a.questions.isEmpty {
                Divider()
                Text("討論問題").font(.headline)
                ForEach(Array(a.questions.enumerated()), id: \.offset) { i, q in
                    Text("\(i + 1). \(q)")
                }
                Text("按「開車聽＋語音討論」，AI 會朗讀全文後逐題用語音問你。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let url = URL(string: item.link) {
                Divider()
                Link(destination: url) {
                    Label("閱讀 BBC 原文：\(item.title)", systemImage: "safari")
                        .font(.callout)
                }
            }
        }
        .padding()
    }

    private func load() async {
        error = nil
        if let cached = NewsStore.shared.cachedArticle(for: item, level: settings.level) {
            article = cached
            return
        }
        guard settings.isConfigured else { error = "請先到「練習」頁右上角設定 API Key"; return }
        do {
            article = try await NewsStore.shared.article(for: item, settings: settings)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Text where every English word is tappable (opens the dictionary), with normal line wrapping.
struct TappableText: View {
    let text: String
    let font: Font
    let onWord: (String) -> Void

    var body: some View {
        Text(Self.attributed(text))
            .font(font)
            .tint(.primary)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "dtword",
                      let w = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "q" })?.value else { return .systemAction }
                onWord(w)
                return .handled
            })
    }

    static func attributed(_ s: String) -> AttributedString {
        var result = AttributedString()
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’-]*[A-Za-z]|[A-Za-z]")
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                result += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let word = ns.substring(with: m.range)
            var piece = AttributedString(word)
            var comps = URLComponents()
            comps.scheme = "dtword"
            comps.host = "lookup"
            comps.queryItems = [URLQueryItem(name: "q", value: word.lowercased())]
            if let url = comps.url { piece.link = url }
            result += piece
            last = m.range.location + m.range.length
        }
        if last < ns.length {
            result += AttributedString(ns.substring(from: last))
        }
        return result
    }
}

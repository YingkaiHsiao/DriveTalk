import Foundation

struct TranslationResult: Codable, Hashable {
    var translation: String
    var alternatives: [String]
    var notes: String

    enum CodingKeys: String, CodingKey { case translation, alternatives, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translation = (try? c.decode(String.self, forKey: .translation)) ?? ""
        alternatives = (try? c.decode([String].self, forKey: .alternatives)) ?? []
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }
}

struct ShadowSentence: Codable, Hashable {
    var en: String
    var zh: String
}

struct GrammarResult: Codable, Hashable {
    var corrected: String
    var natural: String
    var issues: [Issue]
    var summaryZh: String

    struct Issue: Codable, Hashable {
        var wrong: String
        var right: String
        var explainZh: String
    }

    enum CodingKeys: String, CodingKey { case corrected, natural, issues, summaryZh }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        corrected = (try? c.decode(String.self, forKey: .corrected)) ?? ""
        natural = (try? c.decode(String.self, forKey: .natural)) ?? ""
        issues = (try? c.decode([Issue].self, forKey: .issues)) ?? []
        summaryZh = (try? c.decode(String.self, forKey: .summaryZh)) ?? ""
    }
}

struct QAAnswer: Codable, Hashable {
    var answerZh: String
    var examples: [WordInfo.Example]

    enum CodingKeys: String, CodingKey { case answerZh, examples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerZh = (try? c.decode(String.self, forKey: .answerZh)) ?? ""
        examples = (try? c.decode([WordInfo.Example].self, forKey: .examples)) ?? []
    }
}

extension SettingsStore {
    func makeService() -> LLMService {
        LLMService(provider: provider, apiKey: activeKey, model: activeModel)
    }
}

extension String {
    /// True if the text contains CJK characters (used to auto-detect 中→英).
    var containsChinese: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}

/// One-shot AI tasks for the study tools: dictionary, translation, news article.
@MainActor
struct StudyService {
    let settings: SettingsStore

    private var service: LLMService { settings.makeService() }

    // MARK: Dictionary

    func lookup(_ query: String) async throws -> WordInfo {
        let system = """
        You are a concise English-Chinese learner's dictionary for a Taiwanese engineer (Traditional Chinese, Taiwan usage).
        The user gives an English word/phrase, OR a Chinese word (then give the most natural English word/phrase for it).
        Respond ONLY with JSON:
        {"word": "<English headword>", "phonetic": "<IPA, US>", "partOfSpeech": "<n./v./adj./phr. ...>",
         "meaningZh": "<繁體中文意思, short>", "definitionEn": "<simple English definition>",
         "examples": [{"en": "...", "zh": "..."}, {"en": "...", "zh": "..."}],
         "synonyms": ["...", "..."],
         "note": "<繁體中文：常見搭配、易混淆字或工作情境用法，一句話；沒有就空字串>"}
        Give 2 short, natural examples; prefer workplace or tech examples when it fits.
        """
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: query)],
                                             maxTokens: 500, json: true)
        var info: WordInfo = try Self.decode(raw)
        if info.word.isEmpty { info.word = query }
        ProgressStore.shared.recordLookup()
        return info
    }

    // MARK: Translation

    func translate(_ text: String) async throws -> TranslationResult {
        let toEnglish = text.containsChinese
        let system = toEnglish ? """
        Translate the user's Traditional Chinese text into natural, fluent English as a native speaker would say it \
        (workplace-appropriate). Respond ONLY with JSON:
        {"translation": "<best English version>", "alternatives": ["<more casual or more formal version>", "..."],
         "notes": "<繁體中文：1-2 句說明用字選擇或台式英文常見錯誤；沒有就空字串>"}
        """ : """
        Translate the user's English text into natural Traditional Chinese (Taiwan usage). Respond ONLY with JSON:
        {"translation": "<繁體中文翻譯>", "alternatives": [],
         "notes": "<繁體中文：解釋其中較難的片語或文法，1-2 句；沒有就空字串>"}
        """
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: text)],
                                             maxTokens: 800, json: true)
        let r: TranslationResult = try Self.decode(raw)
        ProgressStore.shared.recordTranslation()
        return r
    }

    // MARK: Grammar correction

    func grammarCheck(_ text: String) async throws -> GrammarResult {
        let system = """
        You are a patient English writing and speaking coach for a Taiwanese engineer. Check the user's English text \
        for grammar, word choice and naturalness. Respond ONLY with JSON:
        {"corrected": "<minimal grammatical correction, keep their wording>",
         "natural": "<how a native speaker would naturally say it (workplace-appropriate)>",
         "issues": [{"wrong": "<original fragment>", "right": "<fixed fragment>", "explainZh": "<繁體中文：為什麼，一句話>"}],
         "summaryZh": "<繁體中文：整體評語與最需要注意的一點，1-2 句>"}
        If the text is already correct and natural, return it unchanged with "issues": [] and say so in summaryZh.
        """
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: text)],
                                             maxTokens: 900, json: true)
        let r: GrammarResult = try Self.decode(raw)
        ProgressStore.shared.recordGrammarCheck()
        return r
    }

    // MARK: Ask in Chinese

    func ask(_ question: String) async throws -> QAAnswer {
        let system = """
        You are an English teacher for a Taiwanese engineer. The user asks a question about English, usually in \
        Chinese (e.g. word differences, usage, grammar, how to say something, pronunciation tips). Answer clearly and \
        concisely in Traditional Chinese (Taiwan), with English words where needed. Respond ONLY with JSON:
        {"answerZh": "<繁體中文解答，可分段，不要用 markdown 符號>",
         "examples": [{"en": "<example sentence>", "zh": "<中文>"}]}
        Give 2-4 short, natural examples.
        """
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: question)],
                                             maxTokens: 1000, json: true)
        let r: QAAnswer = try Self.decode(raw)
        ProgressStore.shared.recordLookup()
        return r
    }

    // MARK: Shadowing sentences

    func shadowSentences(topic: ShadowTopic, level: EnglishLevel, count: Int) async throws -> [ShadowSentence] {
        // Different situations + grammar each time, and avoid sentences used recently.
        let subs = Array(Variety.shadowSubtopics(topic).shuffled().prefix(3))
        let focus = Array(Variety.grammarFocus.shuffled().prefix(2))
        let avoid = Variety.recentShadow.suffix(25)
        let system = """
        Create \(count) natural English sentences for shadowing practice (the learner listens and repeats aloud). \
        Topic: \(topic.prompt). Situations for this set: \(subs.joined(separator: ", ")). \
        Include some \(focus.joined(separator: " and ")). Learner level: \(level.promptDescription)
        Each sentence 6-16 words, very natural spoken English, useful in real life, varied in structure. \
        Avoid rare names and numbers. Do NOT reuse or closely paraphrase these recent sentences: \
        \(avoid.isEmpty ? "none" : avoid.joined(separator: " | "))
        Respond ONLY with JSON: {"sentences": [{"en": "...", "zh": "<自然的繁體中文意思>"}]}
        """
        struct Batch: Decodable { var sentences: [ShadowSentence] }
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: "Make a new set.")],
                                             maxTokens: 1100, json: true)
        let b: Batch = try Self.decode(raw)
        let seen = Set(Variety.recentShadow.map(Variety.normalized))
        var out: [ShadowSentence] = []
        var batchSeen = Set<String>()
        for s in b.sentences where !s.en.isEmpty {
            let k = Variety.normalized(s.en)
            if seen.contains(k) || batchSeen.contains(k) { continue }
            batchSeen.insert(k)
            out.append(s)
        }
        Variety.rememberShadow(out.map(\.en))
        return out
    }

    // MARK: News article

    func newsArticle(from item: NewsItem, level: EnglishLevel) async throws -> NewsArticle {
        let words: String
        switch level {
        case .beginner: words = "100-130"
        case .intermediate: words = "140-180"
        case .advanced: words = "180-230"
        }
        let system = """
        You write short news readings for an English learner. Learner level: \(level.promptDescription)
        Using ONLY the facts in the given headline and summary, write an original short article of \(words) words in \
        2-4 short paragraphs. Do not invent quotes, names, numbers, dates or details that are not in the source. \
        You may add one or two sentences of general background knowledge that is widely known and clearly general. \
        It will also be read aloud by text-to-speech, so use plain text with no markdown, no bullet points, no parentheses.
        Respond ONLY with JSON:
        {"title": "<simple headline>", "paragraphs": ["...", "..."],
         "vocabulary": [{"word": "<useful word or phrase from the article>", "meaningZh": "<繁體中文意思>"}],
         "questions": ["<3 short spoken-style questions: 1 comprehension, 1 opinion, 1 personal/work connection>"]}
        Give 5-8 vocabulary items.
        """
        let user = "Headline: \(item.title)\nSummary: \(item.summary)"
        let raw = try await service.complete(system: system,
                                             messages: [LLMMessage(role: "user", content: user)],
                                             maxTokens: 1200, json: true)
        let article: NewsArticle = try Self.decode(raw)
        guard !article.paragraphs.isEmpty else { throw LLMError.badResponse }
        return article
    }

    // MARK: JSON helper

    static func decode<T: Decodable>(_ raw: String) throws -> T {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end,
              let data = String(t[start...end]).data(using: .utf8) else { throw LLMError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

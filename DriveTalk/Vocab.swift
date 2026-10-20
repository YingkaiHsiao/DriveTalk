import Foundation

/// Result of a dictionary lookup (from the AI).
struct WordInfo: Codable, Hashable {
    var word: String
    var phonetic: String = ""
    var partOfSpeech: String = ""
    var meaningZh: String
    var definitionEn: String = ""
    var examples: [Example] = []
    var synonyms: [String] = []
    var note: String = ""

    struct Example: Codable, Hashable {
        var en: String
        var zh: String
    }

    enum CodingKeys: String, CodingKey {
        case word, phonetic, partOfSpeech, meaningZh, definitionEn, examples, synonyms, note
    }

    init(word: String, meaningZh: String) {
        self.word = word
        self.meaningZh = meaningZh
    }

    // Lenient decoding: models sometimes omit fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = (try? c.decode(String.self, forKey: .word)) ?? ""
        phonetic = (try? c.decode(String.self, forKey: .phonetic)) ?? ""
        partOfSpeech = (try? c.decode(String.self, forKey: .partOfSpeech)) ?? ""
        meaningZh = (try? c.decode(String.self, forKey: .meaningZh)) ?? ""
        definitionEn = (try? c.decode(String.self, forKey: .definitionEn)) ?? ""
        examples = (try? c.decode([Example].self, forKey: .examples)) ?? []
        synonyms = (try? c.decode([String].self, forKey: .synonyms)) ?? []
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

/// Spaced-repetition state (simplified SM-2), shared by words and expressions.
struct ReviewState: Codable, Hashable {
    enum Grade: Int, CaseIterable { case again = 0, hard, good, easy
        var label: String {
            switch self {
            case .again: return "忘記"
            case .hard: return "模糊"
            case .good: return "記得"
            case .easy: return "很熟"
            }
        }
    }

    var due: Date = Date()
    var interval: Double = 0      // days
    var ease: Double = 2.5
    var reps: Int = 0
    var lapses: Int = 0

    var isDue: Bool { due <= Date() }
    /// Remembered for 3+ weeks.
    var isMastered: Bool { interval >= 21 }

    mutating func grade(_ g: Grade, now: Date = Date()) {
        reps += 1
        switch g {
        case .again:
            lapses += 1
            ease = max(1.3, ease - 0.2)
            interval = 0
            due = now.addingTimeInterval(10 * 60)       // again in 10 minutes
            return
        case .hard:
            ease = max(1.3, ease - 0.15)
            interval = max(1, interval * 1.2)
        case .good:
            interval = interval < 1 ? 1 : (interval < 2 ? 3 : interval * ease)
        case .easy:
            ease += 0.15
            interval = interval < 1 ? 4 : interval * ease * 1.3
        }
        interval = min(interval, 365)
        due = now.addingTimeInterval(interval * 86_400)
    }

    /// Text for the next review time, e.g. "10 分鐘後" / "3 天後".
    static func preview(_ g: Grade, from state: ReviewState) -> String {
        var s = state
        s.grade(g)
        let sec = s.due.timeIntervalSinceNow
        if sec < 3600 { return "\(max(1, Int(sec / 60))) 分" }
        if sec < 86_400 * 1.5 { return "1 天" }
        return "\(Int((sec / 86_400).rounded())) 天"
    }
}

/// A word saved in the vocabulary book.
struct VocabEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var info: WordInfo
    var source: String          // 查詢 / 新聞 / 對話
    var added: Date = Date()
    var reviewCount: Int = 0
    var review = ReviewState()

    var key: String { info.word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    enum CodingKeys: String, CodingKey { case id, info, source, added, reviewCount, review }

    init(info: WordInfo, source: String) {
        self.info = info
        self.source = source
    }

    // Lenient decoding so vocab saved by older versions still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        info = try c.decode(WordInfo.self, forKey: .info)
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        added = (try? c.decode(Date.self, forKey: .added)) ?? Date()
        reviewCount = (try? c.decode(Int.self, forKey: .reviewCount)) ?? 0
        review = (try? c.decode(ReviewState.self, forKey: .review)) ?? ReviewState()
    }
}

@MainActor
final class VocabStore: ObservableObject {
    static let shared = VocabStore()

    @Published private(set) var entries: [VocabEntry] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vocab.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([VocabEntry].self, from: data) {
            entries = list
        }
    }

    func contains(_ word: String) -> Bool {
        let k = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.contains { $0.key == k }
    }

    /// Adds a word (or upgrades a short entry with a full lookup result).
    func add(_ info: WordInfo, source: String) {
        let k = info.word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !info.meaningZh.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.key == k }) {
            if info.examples.count > entries[i].info.examples.count { entries[i].info = info }
        } else {
            entries.insert(VocabEntry(info: info, source: source), at: 0)
        }
        save()
    }

    func remove(_ word: String) {
        let k = word.lowercased()
        entries.removeAll { $0.key == k }
        save()
    }

    func delete(at offsets: IndexSet, in list: [VocabEntry]) {
        let ids = Set(offsets.map { list[$0].id })
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    var dueEntries: [VocabEntry] { entries.filter { $0.review.isDue }.sorted { $0.review.due < $1.review.due } }
    var masteredCount: Int { entries.filter { $0.review.isMastered }.count }

    /// Smart review batch: due words first (most overdue first), then the least-practiced ones.
    func reviewBatch(limit: Int = 12) -> [VocabEntry] {
        let due = dueEntries
        if due.count >= limit { return Array(due.prefix(limit)) }
        let rest = entries.filter { !$0.review.isDue }.sorted { $0.review.due < $1.review.due }
        return Array((due + rest).prefix(limit))
    }

    func grade(_ id: UUID, _ g: ReviewState.Grade) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].review.grade(g)
        entries[i].reviewCount += 1
        save()
    }

    func grade(word: String, _ g: ReviewState.Grade) {
        let k = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = entries.first(where: { $0.key == k }) { grade(e.id, g) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

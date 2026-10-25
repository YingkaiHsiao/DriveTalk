import Foundation

/// A better way of saying something (from conversation corrections or the grammar tool).
struct SavedExpression: Identifiable, Codable, Hashable {
    var id = UUID()
    var original: String
    var better: String
    var note: String
    var source: String          // 對話糾錯 / 文法修正
    var date: Date = Date()
    var practiced: Int = 0
    var review = ReviewState()
    /// Chinese meaning (filled in the first time it's used for shadowing).
    var zh: String?
}

struct DayStat: Codable {
    var practiceSeconds: Double = 0   // driving practice (voice)
    var studySeconds: Double = 0      // reading / lookup / vocab screens
    var sessions = 0
    var userTurns = 0
    var userWords = 0
    var shadowCount = 0
    var shadowScoreSum = 0
    var lookups = 0
    var translations = 0
    var grammarChecks = 0
    var corrections = 0

    var totalMinutes: Double { (practiceSeconds + studySeconds) / 60 }
}

/// Learning statistics + saved expressions, persisted as one JSON file.
@MainActor
final class ProgressStore: ObservableObject {
    static let shared = ProgressStore()

    @Published private(set) var days: [String: DayStat] = [:]
    @Published private(set) var expressions: [SavedExpression] = []
    /// Unique English words the user has spoken → times used.
    @Published private(set) var wordsUsed: [String: Int] = [:]

    private struct FileData: Codable {
        var days: [String: DayStat]
        var expressions: [SavedExpression]
        var wordsUsed: [String: Int]
    }

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("progress.json")
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { keyFormatter.string(from: date) }

    private init() {
        if let data = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(FileData.self, from: data) {
            days = f.days
            expressions = f.expressions
            wordsUsed = f.wordsUsed
        }
    }

    private func update(_ change: (inout DayStat) -> Void) {
        let k = Self.key(Date())
        var d = days[k] ?? DayStat()
        change(&d)
        days[k] = d
        save()
    }

    // MARK: Recording

    func addPractice(seconds: Double) { if seconds > 5 { update { $0.practiceSeconds += seconds; $0.sessions += 1 } } }
    func addStudy(seconds: Double) { if seconds > 3 { update { $0.studySeconds += seconds } } }
    func recordLookup() { update { $0.lookups += 1 } }
    func recordTranslation() { update { $0.translations += 1 } }
    func recordGrammarCheck() { update { $0.grammarChecks += 1 } }
    func recordShadow(score: Int) { update { $0.shadowCount += 1; $0.shadowScoreSum += score } }

    func recordUtterance(_ text: String) {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { $0.count >= 2 && $0.unicodeScalars.allSatisfy { $0.isASCII } }
        guard !words.isEmpty else { return }
        for w in words { wordsUsed[w, default: 0] += 1 }
        update { $0.userTurns += 1; $0.userWords += words.count }
    }

    func addExpression(original: String, better: String, note: String, source: String) {
        let b = better.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, b.lowercased() != original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if expressions.contains(where: { $0.better.lowercased() == b.lowercased() }) { return }
        expressions.insert(SavedExpression(original: original, better: b, note: note, source: source), at: 0)
        update { $0.corrections += 1 }
    }

    func deleteExpressions(ids: Set<UUID>) {
        expressions.removeAll { ids.contains($0.id) }
        save()
    }

    /// Least-practiced saved expressions first (for shadowing).
    func expressionsForPractice(limit: Int) -> [SavedExpression] {
        Array(expressions.sorted { $0.practiced != $1.practiced ? $0.practiced < $1.practiced : $0.date > $1.date }
            .prefix(limit))
    }

    var dueExpressions: [SavedExpression] { expressions.filter { $0.review.isDue }.sorted { $0.review.due < $1.review.due } }

    func gradeExpression(_ id: UUID, _ g: ReviewState.Grade) {
        if let i = expressions.firstIndex(where: { $0.id == id }) {
            expressions[i].review.grade(g)
            save()
        }
    }

    func setChinese(_ zh: String, for id: UUID) {
        if let i = expressions.firstIndex(where: { $0.id == id }) {
            expressions[i].zh = zh
            save()
        }
    }

    func markPracticed(_ id: UUID) {
        if let i = expressions.firstIndex(where: { $0.id == id }) {
            expressions[i].practiced += 1
            save()
        }
    }

    // MARK: Summary numbers

    var today: DayStat { days[Self.key(Date())] ?? DayStat() }

    var totalMinutes: Double { days.values.reduce(0) { $0 + $1.totalMinutes } }
    var totalPracticeMinutes: Double { days.values.reduce(0) { $0 + $1.practiceSeconds } / 60 }
    var totalSessions: Int { days.values.reduce(0) { $0 + $1.sessions } }
    var totalWordsSpoken: Int { days.values.reduce(0) { $0 + $1.userWords } }
    var totalTurns: Int { days.values.reduce(0) { $0 + $1.userTurns } }
    var totalShadows: Int { days.values.reduce(0) { $0 + $1.shadowCount } }
    var averageShadowScore: Int {
        let n = totalShadows
        return n == 0 ? 0 : days.values.reduce(0) { $0 + $1.shadowScoreSum } / n
    }
    var totalLookups: Int { days.values.reduce(0) { $0 + $1.lookups + $1.translations + $1.grammarChecks } }

    /// Consecutive days (ending today or yesterday) with at least 1 minute of learning.
    var streak: Int {
        let cal = Calendar.current
        var day = Date()
        if (days[Self.key(day)]?.totalMinutes ?? 0) < 1 {
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        var n = 0
        while (days[Self.key(day)]?.totalMinutes ?? 0) >= 1 {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    struct DayPoint: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    /// Minutes per day for the last `count` days (oldest first).
    func lastDays(_ count: Int) -> [DayPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            return DayPoint(date: d, minutes: days[Self.key(d)]?.totalMinutes ?? 0)
        }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "for", "is", "are", "was", "were",
        "be", "it", "i", "you", "we", "they", "he", "she", "my", "me", "so", "that", "this", "do", "did",
        "have", "has", "had", "not", "with", "as", "if", "its", "it's", "i'm", "can", "will", "would", "yes",
        "no", "ok", "okay", "um", "uh", "like", "just", "there", "what", "about", "your", "our", "them", "us",
    ]

    /// Most used content words (excludes very common function words).
    func topWords(_ n: Int) -> [(word: String, count: Int)] {
        wordsUsed.filter { !Self.stopWords.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(FileData(days: days, expressions: expressions, wordsUsed: wordsUsed)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Shadowing score (local, no tokens)

enum ShadowScorer {
    private static let contractions: [String: String] = [
        "i'm": "i am", "you're": "you are", "we're": "we are", "they're": "they are", "it's": "it is",
        "that's": "that is", "there's": "there is", "what's": "what is", "let's": "let us",
        "i've": "i have", "we've": "we have", "you've": "you have", "i'll": "i will", "we'll": "we will",
        "you'll": "you will", "it'll": "it will", "i'd": "i would", "we'd": "we would",
        "don't": "do not", "doesn't": "does not", "didn't": "did not", "can't": "cannot", "won't": "will not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not", "couldn't": "could not",
        "shouldn't": "should not", "wouldn't": "would not", "haven't": "have not",
    ]
    private static let numbers = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
                                  "6": "six", "7": "seven", "8": "eight", "9": "nine", "10": "ten"]

    static func words(_ s: String) -> [String] {
        let cleaned = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let raw = cleaned.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        return raw.flatMap { w -> [String] in
            if let e = contractions[w] { return e.split(separator: " ").map(String.init) }
            if let n = numbers[w] { return [n] }
            return [w.trimmingCharacters(in: CharacterSet(charactersIn: "'"))]
        }.filter { !$0.isEmpty }
    }

    /// Score 0–100 = share of target words said in order (LCS); also returns missed target words.
    static func score(target: String, heard: String) -> (score: Int, missed: [String]) {
        let t = words(target), h = words(heard)
        guard !t.isEmpty else { return (0, []) }
        guard !h.isEmpty else { return (0, t) }
        var dp = Array(repeating: Array(repeating: 0, count: h.count + 1), count: t.count + 1)
        for i in 1...t.count {
            for j in 1...h.count {
                dp[i][j] = t[i - 1] == h[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var matched = Set<Int>()
        var i = t.count, j = h.count
        while i > 0 && j > 0 {
            if t[i - 1] == h[j - 1] { matched.insert(i - 1); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        let missed = t.indices.filter { !matched.contains($0) }.map { t[$0] }
        return (Int((Double(dp[t.count][h.count]) / Double(t.count) * 100).rounded()), missed)
    }
}

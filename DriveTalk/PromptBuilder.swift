import Foundation

struct ParsedReply {
    let feedback: String
    let reply: String
    var vocab: [WordInfo] = []
    var explainZh: String = ""
    var better: String = ""
    /// Smart-review results: item (word or expression) → answered correctly?
    var graded: [(item: String, correct: Bool)] = []
}

enum PromptBuilder {
    static let startToken = "[START]"

    /// System prompt for the voice conversation. The reply uses a line-tagged plain-text format
    /// (not JSON) so it can be streamed and spoken sentence by sentence while it is still arriving.
    static func system(mode: PracticeMode, scenario: Scenario?, level: EnglishLevel,
                       feedback: Bool, feedbackLanguage: FeedbackLanguage,
                       article: NewsArticle? = nil, reviewWords: [VocabEntry] = [],
                       reviewExpressions: [SavedExpression] = [], sessionSeed: String = "") -> String {
        var p = """
        You are DriveTalk, a friendly English speaking partner for a Taiwanese engineer (native Mandarin speaker) \
        practicing spoken English while DRIVING. Everything you say is read aloud by text-to-speech.

        RULES:
        - Plain spoken English: no markdown, lists, emojis, URLs, code or parentheses.
        - Replies are SHORT: 1-3 sentences, under 45 words. Usually end with ONE simple question.
        - Never ask the user to look at a screen, read, type or write.
        - If the user must focus on driving, reply with a very short okay.
        - User text comes from speech recognition: ignore punctuation, capitalization and obvious recognition errors.
        - If the user asks for help, give one short example sentence they could say, then let them try.
        - If the user asks what an English word means, explain simply with one short example, then continue.
        - If the user asks how to say something in English, give the natural phrase and ask them to repeat it.
        - If the user speaks CHINESE or asks for a Chinese explanation, explain briefly in Traditional Chinese (Taiwan) \
        on the ZH line, and keep REPLY in English (usually the phrase to repeat or a question).

        LEARNER LEVEL: \(level.promptDescription)

        """

        switch mode {
        case .free:
            p += """
            MODE: Free conversation about daily life, work, technology, travel, food, hobbies. \
            Follow the user's interests and ask follow-up questions.

            """
        case .rolePlay, .workTech:
            if let s = scenario {
                p += """
                MODE: Role-play. Stay in character. You play \(s.aiRole). The user plays \(s.userRole). \
                Goal: \(s.goal). Be realistic: add small complications and follow-up questions.

                """
            }
            if mode == .workTech {
                p += """
                The user is an embedded Linux BSP engineer and team lead (kernel, U-Boot, device tree, Yocto/OpenWrt, \
                Wi-Fi drivers, CVE backporting, bring-up) at an industrial computer company. Use realistic technical, \
                professional workplace English.

                """
            }
        case .news:
            if let a = article {
                p += """
                MODE: News discussion. The user just LISTENED to this article:
                Title: \(a.title)
                \(a.paragraphs.joined(separator: "\n"))
                Ask these questions one at a time, reacting naturally to each answer: \(a.questions.joined(separator: " | "))
                Then chat freely about the topic. Explain simply if the user didn't understand.

                """
            }
        case .shadowing:
            break
        case .vocabReview:
            let list = reviewWords.map { "\($0.info.word) (\($0.info.meaningZh))" }.joined(separator: "; ")
            let exprs = reviewExpressions.map { "[\($0.original)] -> [\($0.better)]" }.joined(separator: "; ")
            p += """
            MODE: Smart review. Review these due items one at a time.
            WORDS: \(list.isEmpty ? "none" : list)
            EXPRESSIONS (old way -> better way): \(exprs.isEmpty ? "none" : exprs)
            Vary questions: meaning of a word, Chinese meaning -> English word, make a sentence; for expressions ask how \
            to say the old version more naturally. Give quick feedback and the right answer if missed, then move on.

            """
        }

        if !sessionSeed.isEmpty { p += sessionSeed + "\n\n" }

        let feedbackRule: String
        if feedback {
            let lang = feedbackLanguage == .chinese
                ? "Explain in Traditional Chinese, but keep the improved sentence in English."
                : "Use simple English."
            feedbackRule = """
            FEEDBACK: only if the user's LAST English utterance had a clear grammar mistake, wrong word or very unnatural \
            phrasing: Better: "<improved sentence>". plus at most one short reason, under 30 words. \(lang) \
            Skip it for fine sentences, Chinese utterances and \(startToken). Don't praise every turn.
            BETTER: only with FEEDBACK — just the improved sentence, no quotes.
            """
        } else {
            feedbackRule = "Never write FEEDBACK or BETTER lines."
        }

        p += """
        OUTPUT FORMAT — plain text, one field per line, in this order, OMIT any line that would be empty:
        FEEDBACK: ...
        BETTER: ...
        ZH: <Chinese explanation, only when needed>
        REPLY: <your spoken English reply — always present, on ONE line>
        VOCAB: word = 中文意思; phrase = 中文意思   (only words/phrases you explicitly taught this turn)
        \(mode == .vocabReview ? "GRADED: item = yes; item = no   (review items the user just answered; item = the word or the better expression)" : "")
        \(feedbackRule)

        When the user message is exactly \(startToken), greet briefly and open the conversation (or ask the first question).
        """
        return p
    }

    static func summarySystem() -> String {
        """
        You are an English speaking coach. Review a spoken practice transcript between a Taiwanese learner (USER) \
        and an AI partner (AI). The USER lines came from speech recognition, so ignore punctuation and capitalization.
        Write a concise review in Traditional Chinese (Taiwan) with English examples, plain text (no markdown symbols like # or *), using these sections:
        一、整體表現（2 句）
        二、做得好的地方（最多 3 點）
        三、最重要的 3 個修正（原句 → 更自然的說法，附一句原因）
        四、值得記住的 5 個實用片語（英文 + 中文意思）
        五、下次練習建議（1 句）
        """
    }

    static func transcriptText(_ messages: [ChatMessage]) -> String {
        messages.map { "\($0.role == .user ? "USER" : "AI"): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Parsing

    /// Parses the tagged format (FEEDBACK/BETTER/ZH/REPLY/VOCAB/GRADED). Falls back to JSON, then to plain text.
    static func parse(_ raw: String) -> ParsedReply {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for line in trimmed.components(separatedBy: .newlines) {
            if let pair = TaggedLine.split(line) {
                fields[pair.0] = (fields[pair.0].map { $0 + " " } ?? "") + pair.1
            }
        }
        if fields["REPLY"] != nil || fields["ZH"] != nil {
            return ParsedReply(feedback: fields["FEEDBACK"] ?? "",
                               reply: clean(fields["REPLY"] ?? ""),
                               vocab: parsePairs(fields["VOCAB"] ?? "").map { WordInfo(word: $0.0, meaningZh: $0.1) },
                               explainZh: clean(fields["ZH"] ?? ""),
                               better: (fields["BETTER"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")),
                               graded: parsePairs(fields["GRADED"] ?? "").map {
                                   (item: $0.0, correct: ["yes", "y", "true", "correct", "1"].contains($0.1.lowercased()))
                               })
        }
        if let json = parseJSON(trimmed) { return json }
        return ParsedReply(feedback: "", reply: clean(trimmed))
    }

    /// "a = b; c = d" → [(a, b), (c, d)]
    private static func parsePairs(_ s: String) -> [(String, String)] {
        s.components(separatedBy: ";").compactMap { part in
            let kv = part.components(separatedBy: "=")
            guard kv.count >= 2 else { return nil }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            return k.isEmpty || v.isEmpty ? nil : (k, v)
        }
    }

    private static func parseJSON(_ trimmed: String) -> ParsedReply? {
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let reply = (obj["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let zh = (obj["explainZh"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty || !zh.isEmpty else { return nil }
        return ParsedReply(feedback: obj["feedback"] as? String ?? "", reply: clean(reply),
                           explainZh: clean(zh), better: obj["better"] as? String ?? "")
    }

    /// Strip characters TTS would read awkwardly.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "")
         .replacingOccurrences(of: "#", with: "")
         .replacingOccurrences(of: "`", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits "TAG: value" lines of the reply format.
enum TaggedLine {
    static let tags = ["FEEDBACK", "BETTER", "ZH", "REPLY", "VOCAB", "GRADED"]

    static func split(_ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for tag in tags {
            for sep in [":", "："] where t.hasPrefix(tag + sep) {
                return (tag, String(t.dropFirst(tag.count + sep.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

/// Incremental parser for a streaming reply: emits things to speak as soon as they are complete
/// (whole FEEDBACK / ZH lines, and each finished sentence of REPLY).
struct StreamSpeechParser {
    enum Segment { case feedback(String), chinese(String), reply(String) }

    private var buffer = ""
    private var lineStart = 0          // index (in characters) where the current line starts
    private var replySpoken = 0        // characters of the current REPLY value already emitted
    private(set) var emittedAny = false
    var receivedText: String { buffer }

    mutating func feed(_ delta: String) -> [Segment] {
        buffer += delta
        var out: [Segment] = []
        // Complete lines
        while true {
            let chars = Array(buffer)
            guard let nl = chars[lineStart...].firstIndex(of: "\n") else { break }
            let line = String(chars[lineStart..<nl])
            out += finishLine(line)
            lineStart = nl + 1
            replySpoken = 0
        }
        // Partial REPLY line: emit finished sentences early
        let current = String(Array(buffer)[lineStart...])
        if let pair = TaggedLine.split(current), pair.0 == "REPLY" {
            let chars = Array(pair.1)
            var i = replySpoken
            var lastCut: Int?
            while i < chars.count - 1 {
                if ".!?".contains(chars[i]) && chars[i + 1] == " " { lastCut = i + 1 }
                i += 1
            }
            if let cut = lastCut, cut > replySpoken {
                let sentence = String(chars[replySpoken..<cut]).trimmingCharacters(in: .whitespaces)
                replySpoken = cut
                if !sentence.isEmpty { out.append(.reply(PromptBuilder.clean(sentence))); emittedAny = true }
            }
        }
        return out
    }

    /// Call when the stream ends.
    mutating func finish() -> [Segment] {
        let rest = String(Array(buffer)[lineStart...])
        lineStart = buffer.count
        let out = finishLine(rest)
        replySpoken = 0
        return out
    }

    private mutating func finishLine(_ line: String) -> [Segment] {
        guard let pair = TaggedLine.split(line) else { return [] }
        let value = pair.1
        switch pair.0 {
        case "FEEDBACK":
            guard !value.isEmpty else { return [] }
            emittedAny = true
            return [.feedback(PromptBuilder.clean(value))]
        case "ZH":
            guard !value.isEmpty else { return [] }
            emittedAny = true
            return [.chinese(PromptBuilder.clean(value))]
        case "REPLY":
            let chars = Array(value)
            guard replySpoken < chars.count else { return [] }
            let rest = String(chars[replySpoken...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return [] }
            emittedAny = true
            return [.reply(PromptBuilder.clean(rest))]
        default:
            return []
        }
    }
}

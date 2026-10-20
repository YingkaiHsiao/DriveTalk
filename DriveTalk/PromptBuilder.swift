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

    static func system(mode: PracticeMode, scenario: Scenario?, level: EnglishLevel,
                       feedback: Bool, feedbackLanguage: FeedbackLanguage,
                       article: NewsArticle? = nil, reviewWords: [VocabEntry] = [],
                       reviewExpressions: [SavedExpression] = []) -> String {
        var p = """
        You are DriveTalk, a friendly English speaking partner for a Taiwanese engineer \
        (native Mandarin speaker) who practices spoken English while DRIVING.

        HARD RULES (driving safety & voice-only):
        - Everything in "reply" will be read aloud by text-to-speech. Write plain spoken English only: \
        no markdown, no bullet points, no emojis, no URLs, no code, no parentheses asides.
        - Keep each reply SHORT: 1 to 3 sentences, under 45 words. Never lecture.
        - Usually end with ONE simple question so the conversation keeps going.
        - Never ask the user to look at a screen, read, type, or write anything.
        - If the user says they need to focus on driving or traffic, reply with a very short okay and wait.
        - The user's text comes from speech recognition and may contain transcription mistakes. \
        Silently ignore capitalization, punctuation and obvious recognition glitches; guess the intended meaning.
        - If the user asks for help or says they don't know how to say something, give one short example \
        sentence they could say, then let them try.

        VOICE DICTIONARY (the user cannot look things up while driving):
        - If the user asks what an English word or phrase means (e.g. "What does mitigate mean?"), explain it \
        in simple English with one short example sentence, then return to the conversation.
        - If the user asks how to say something in English, give the natural English phrase, ask them to repeat it, then continue.
        - CHINESE QUESTIONS: If the user speaks Chinese (e.g. 「這個字是什麼意思？」「剛剛那句怎麼說比較自然？」「延期英文怎麼說？」) \
        or asks you to explain in Chinese, put a short, clear explanation in Traditional Chinese (Taiwan) in "explainZh" \
        (it is read aloud by a Chinese voice; English words inside it are fine), and keep "reply" in English: \
        usually the English phrase to repeat or a question to continue. Otherwise "explainZh" is "".
        - Whenever you teach a word or phrase this way, also add it to "vocab".

        LEARNER LEVEL: \(level.promptDescription)

        """

        switch mode {
        case .free:
            p += """
            MODE: Free conversation. Be a curious, warm conversation partner. Chat about daily life, \
            work, technology, travel, food, news, hobbies. Follow the user's interests and ask follow-up questions.

            """
        case .rolePlay, .workTech:
            if let s = scenario {
                p += """
                MODE: Role-play. Stay in character for the whole session.
                You play: \(s.aiRole).
                The user plays: \(s.userRole).
                Scenario goal: \(s.goal).
                Make it realistic: introduce small complications, ask realistic follow-up questions.

                """
            }
            if mode == .workTech {
                p += """
                The user is an embedded Linux BSP engineer and team lead (Linux kernel, U-Boot, device tree, \
                Yocto/OpenWrt, Wi-Fi drivers, CVE backporting, hardware bring-up) at an industrial computer company. \
                Use realistic technical vocabulary and professional workplace English, and help them sound clear \
                and confident with customers and overseas colleagues.

                """
            }
        case .news:
            if let a = article {
                p += """
                MODE: News discussion. The user has just LISTENED to this short news article (read aloud by the app):
                Title: \(a.title)
                \(a.paragraphs.joined(separator: "\n"))

                Discuss it with the user. Ask these questions one at a time, in order, and react naturally to each answer \
                before moving on: \(a.questions.joined(separator: " | "))
                After the questions, chat freely about the topic. If the user didn't understand something, explain it simply. \
                If the user says "next news", the app handles it, so you don't need to.

                """
            }
        case .shadowing:
            break
        case .vocabReview:
            let list = reviewWords.map { "\($0.info.word) (\($0.info.meaningZh))" }.joined(separator: "; ")
            let exprs = reviewExpressions.map { "[\($0.original)] -> [\($0.better)]" }.joined(separator: "; ")
            p += """
            MODE: Smart review (spaced repetition). Review these items that are due, one at a time:
            WORDS (word + Chinese meaning): \(list.isEmpty ? "none" : list)
            EXPRESSIONS the user once said unnaturally -> the better version: \(exprs.isEmpty ? "none" : exprs)
            For words, vary the question: ask what the word means, give the Chinese meaning and ask for the English word, \
            or ask the user to make a sentence with it. For expressions, read the user's old version and ask how to say it \
            more naturally, or give the Chinese idea and ask them to say the better version. Give quick, encouraging \
            feedback and the correct answer if they miss it, then move on. When everything is done, say so.
            GRADING: In every turn where the user answered a review item, add it to "graded" with the exact item text \
            (the word, or the better version of the expression) and whether the answer was basically correct.

            """
        }

        let feedbackRule: String
        if feedback {
            let lang = feedbackLanguage == .chinese
                ? "Write the explanation part of the feedback in Traditional Chinese (Taiwan), but keep the improved English sentence in English."
                : "Write the feedback in simple English."
            feedbackRule = """
            - "feedback": You are also a gentle speaking coach. If the user's LAST utterance had a clear grammar mistake, \
            wrong word, or very unnatural phrasing, give ONE short correction in this style: Better: "<improved sentence>". \
            then at most one short reason. Under 30 words. If it was fine or only had minor issues, use "". \
            Never correct Chinese utterances. \
            Do not praise every turn. For the very first turn (the user message \(startToken)) always use "". \(lang)
            """
        } else {
            feedbackRule = "- \"feedback\": always \"\"."
        }

        p += """
        OUTPUT FORMAT: Respond ONLY with a JSON object, no other text:
        {"feedback": "...", "better": "...", "explainZh": "...", "reply": "...", "vocab": [{"word": "...", "meaningZh": "..."}], "graded": []}
        \(feedbackRule)
        - "better": when "feedback" is not empty, ONLY the improved sentence itself (no quotes); otherwise "".
        - "explainZh": see CHINESE QUESTIONS; usually "".
        - "graded": only in smart review mode: [{"item": "...", "correct": true}]; otherwise [].
        - "reply": your conversational reply following all the rules above.
        - "vocab": words or phrases you explicitly taught in this turn (dictionary questions, Chinese-to-English, \
        or the key phrase of a correction), with a short Traditional Chinese meaning. Usually an empty list [].

        When the user message is exactly \(startToken), greet the user briefly and open the conversation \
        (or ask the first question) with a question.
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

    /// Parses {"feedback": "...", "reply": "...", "vocab": [...]}; falls back to treating the whole text as the reply.
    static func parse(_ raw: String) -> ParsedReply {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end,
           let data = String(trimmed[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let fb = (obj["feedback"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = (obj["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let explainZh = (obj["explainZh"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let better = (obj["better"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            let vocab: [WordInfo] = (obj["vocab"] as? [[String: Any]] ?? []).compactMap {
                guard let w = $0["word"] as? String, let m = $0["meaningZh"] as? String,
                      !w.isEmpty, !m.isEmpty else { return nil }
                return WordInfo(word: w, meaningZh: m)
            }
            if !reply.isEmpty || !explainZh.isEmpty {
                let graded: [(item: String, correct: Bool)] = (obj["graded"] as? [[String: Any]] ?? []).compactMap {
                    guard let item = $0["item"] as? String, !item.isEmpty else { return nil }
                    return (item: item, correct: ($0["correct"] as? Bool) ?? false)
                }
                return ParsedReply(feedback: fb, reply: clean(reply), vocab: vocab,
                                   explainZh: clean(explainZh), better: better, graded: graded)
            }
        }
        return ParsedReply(feedback: "", reply: clean(trimmed))
    }

    /// Strip characters TTS would read awkwardly.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "")
         .replacingOccurrences(of: "#", with: "")
         .replacingOccurrences(of: "`", with: "")
    }
}

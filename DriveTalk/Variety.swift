import Foundation

/// Makes every session different: random topic / opening style / twist, and remembers what was
/// used recently so it isn't repeated. Costs only a few extra prompt tokens.
@MainActor
enum Variety {
    // MARK: Free conversation

    static let freeTopics = [
        "weekend plans", "a favorite night market snack", "a movie or series worth watching", "a memorable trip",
        "coffee or tea habits", "a useful phone app", "using AI tools at work", "learning a new skill",
        "childhood games", "Taiwanese festivals like Mid-Autumn or Lunar New Year", "a sport to watch or play",
        "simple ways to stay healthy", "the daily commute and traffic", "the weather and typhoon season",
        "a book or podcast", "music for driving", "pets", "a favorite home-cooked dish", "online shopping",
        "travel to Japan or Korea", "a dream vacation", "a funny thing that happened recently", "a hobby",
        "gadgets and tech news", "electric cars", "working from home vs the office", "a great restaurant",
        "convenience stores in Taiwan", "saving money tips", "a city you'd like to live in", "morning routines",
        "a team lunch", "a recent concert or event", "hiking and nature in Taiwan", "learning English tips",
        "the best way to relax after work", "a would-you-rather question", "future technology", "cooking fails",
        "a good teacher you remember", "public transport around the world", "a favorite season",
    ]

    static let openingStyles = [
        "ask a fun would-you-rather question about the topic",
        "share one short surprising fact about the topic, then ask a question",
        "start with a quick personal-style comment about the topic, then ask the user's opinion",
        "ask about the user's own experience with the topic",
        "describe a tiny everyday situation about the topic and ask what the user would do",
        "ask the user to compare two things related to the topic",
    ]

    // MARK: Role-play twists

    static let twists = [
        "the other person is in a hurry and speaks quickly",
        "there is a small misunderstanding the user must clarify",
        "a new requirement appears halfway through",
        "the other person is a bit unhappy and needs to be calmed down",
        "the other person is very friendly and chatty",
        "the other person asks many detailed follow-up questions",
        "the deadline or time slot suddenly changes",
        "the other person needs a short summary at the end",
    ]

    // MARK: Shadowing

    static func shadowSubtopics(_ topic: ShadowTopic) -> [String] {
        switch topic {
        case .work, .saved:
            return ["giving a status update", "asking for clarification", "polite disagreement", "reporting a bug",
                    "scheduling a meeting", "explaining a delay", "giving instructions", "small talk before a meeting",
                    "presenting test results", "negotiating a deadline", "asking a colleague for help",
                    "thanking and giving credit", "customer support phone call", "writing-style phrases said aloud",
                    "summarizing a discussion", "making a suggestion"]
        case .daily:
            return ["ordering food", "chatting with neighbors", "shopping and returns", "talking about feelings",
                    "making plans with friends", "at the doctor's office", "family conversations", "complimenting someone",
                    "apologizing", "asking for directions", "talking about the weather", "weekend activities",
                    "phone calls", "giving advice"]
        case .travel:
            return ["airport check-in", "hotel problems", "taking a taxi", "restaurant reservations", "trade show booth talk",
                    "meeting overseas colleagues", "asking for recommendations", "lost luggage", "train tickets",
                    "business dinner small talk", "currency and payment", "sightseeing"]
        }
    }

    static let grammarFocus = [
        "questions", "polite requests with could/would", "past tense stories", "future plans with going to / will",
        "if-sentences", "common phrasal verbs", "natural idioms", "linking words like although / however / so",
        "present perfect (have done)", "giving opinions",
    ]

    // MARK: Recent history (UserDefaults)

    private static let recentTopicsKey = "variety.recentTopics"
    private static let recentShadowKey = "variety.recentShadow"

    static var recentTopics: [String] { UserDefaults.standard.stringArray(forKey: recentTopicsKey) ?? [] }
    static var recentShadow: [String] { UserDefaults.standard.stringArray(forKey: recentShadowKey) ?? [] }

    private static func remember(_ item: String, key: String, keep: Int) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == item }
        list.append(item)
        UserDefaults.standard.set(Array(list.suffix(keep)), forKey: key)
    }

    static func rememberShadow(_ sentences: [String]) {
        var list = recentShadow
        list.append(contentsOf: sentences)
        UserDefaults.standard.set(Array(list.suffix(120)), forKey: recentShadowKey)
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Session seed for the system prompt

    /// A short instruction block that changes every session.
    static func sessionSeed(mode: PracticeMode) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d"
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 11 ? "morning" : hour < 14 ? "midday" : hour < 18 ? "afternoon" : "evening"
        var seed = "SESSION CONTEXT: It is \(f.string(from: Date())), \(part), in Taiwan. "

        switch mode {
        case .free:
            let recent = recentTopics
            let topic = freeTopics.filter { !recent.contains($0) }.randomElement() ?? freeTopics.randomElement()!
            remember(topic, key: recentTopicsKey, keep: 12)
            seed += "Today's starting topic: \(topic). Opening style: \(openingStyles.randomElement()!). "
            if !recent.isEmpty {
                seed += "Recently discussed (don't start with these): \(recent.suffix(6).joined(separator: ", ")). "
            }
            seed += "Vary your wording; do not start with \"How was your day\"."
        case .rolePlay, .workTech:
            seed += "Today's twist: \(twists.randomElement()!). Open the scene in a fresh way."
        default:
            seed += "Open in a fresh, varied way."
        }
        return seed
    }
}

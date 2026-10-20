import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case claude = "Claude"
    case gemini = "Gemini"
    var id: String { rawValue }
}

enum PracticeMode: String, CaseIterable, Identifiable, Codable {
    case free = "自由對話"
    case rolePlay = "情境角色扮演"
    case workTech = "工作英文（技術/嵌入式）"
    case news = "新聞聽讀討論"
    case vocabReview = "智慧複習（生字＋表達）"
    case shadowing = "跟讀練習（跟著唸）"
    var id: String { rawValue }

    var usesScenario: Bool { self == .rolePlay || self == .workTech }
}

enum EnglishLevel: String, CaseIterable, Identifiable, Codable {
    case beginner = "初級 (A2)"
    case intermediate = "中級 (B1–B2)"
    case advanced = "高級 (C1)"
    var id: String { rawValue }

    var promptDescription: String {
        switch self {
        case .beginner: return "CEFR A2. Use simple, common words and short sentences. Speak slowly and clearly."
        case .intermediate: return "CEFR B1-B2. Use natural everyday English with some useful idioms, but avoid rare words."
        case .advanced: return "CEFR C1. Use natural, fluent English including idioms and nuanced vocabulary."
        }
    }
}

enum ShadowTopic: String, CaseIterable, Identifiable, Codable {
    case work = "工作英文（技術/會議）"
    case daily = "日常生活"
    case travel = "出差旅遊"
    case saved = "只用我的表達方式"
    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .work: return "workplace English for an embedded Linux BSP engineer: meetings, status updates, customer support calls, emails read aloud, technical explanations"
        case .daily: return "everyday conversation: small talk, food, family, weekends, shopping, feelings"
        case .travel: return "business travel: airport, hotel, taxi, restaurant, trade shows, meeting overseas colleagues"
        case .saved: return "everyday and workplace English"
        }
    }
}

enum FeedbackLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "English"
    case chinese = "繁體中文"
    var id: String { rawValue }
}

struct Scenario: Identifiable, Hashable {
    let id: String
    let title: String
    let mode: PracticeMode
    let aiRole: String
    let userRole: String
    let goal: String

    static let all: [Scenario] = [
        // 情境角色扮演
        Scenario(id: "restaurant", title: "餐廳點餐", mode: .rolePlay,
                 aiRole: "a friendly waiter at a casual American restaurant",
                 userRole: "a customer ordering dinner",
                 goal: "order food and drinks, ask about the menu, handle a small problem with the order"),
        Scenario(id: "hotel", title: "飯店入住", mode: .rolePlay,
                 aiRole: "a hotel front desk clerk",
                 userRole: "a business traveler checking in",
                 goal: "check in, ask about breakfast, Wi-Fi and late checkout, solve a booking mix-up"),
        Scenario(id: "airport", title: "機場報到與轉機", mode: .rolePlay,
                 aiRole: "an airline check-in agent",
                 userRole: "a passenger flying to Germany via a connection",
                 goal: "check in, discuss baggage, seat preference, and a delayed connecting flight"),
        Scenario(id: "interview", title: "英文面試", mode: .rolePlay,
                 aiRole: "a hiring manager at a multinational tech company",
                 userRole: "a candidate for a senior embedded software engineer position",
                 goal: "answer behavioral and technical interview questions"),
        Scenario(id: "smalltalk", title: "跟外國同事閒聊", mode: .rolePlay,
                 aiRole: "a friendly American colleague visiting the Taiwan office",
                 userRole: "a local engineer making small talk",
                 goal: "small talk about weekends, food, travel, and Taiwan"),

        // 工作英文（技術/嵌入式）
        Scenario(id: "fae_boot", title: "客戶 FAE 電話：開機失敗除錯", mode: .workTech,
                 aiRole: "a customer's field application engineer whose boards fail to boot after a firmware update",
                 userRole: "the BSP engineer supporting the customer",
                 goal: "ask clarifying questions, request logs (UART console, U-Boot output), explain likely causes, agree on next steps"),
        Scenario(id: "standup", title: "每日站會進度報告", mode: .workTech,
                 aiRole: "a project manager running a daily stand-up with an overseas team",
                 userRole: "a BSP team lead reporting status",
                 goal: "report yesterday's progress, today's plan, and blockers clearly and concisely"),
        Scenario(id: "cve", title: "向客戶說明 Kernel CVE 修補狀態", mode: .workTech,
                 aiRole: "a security-focused customer asking about Linux kernel CVE exposure in their product",
                 userRole: "the engineer responsible for kernel CVE triage and backporting",
                 goal: "explain which CVEs affect the product, which are not applicable and why, and the patch release schedule"),
        Scenario(id: "vendor", title: "與晶片廠討論 Wi-Fi 驅動問題", mode: .workTech,
                 aiRole: "a support engineer at a Wi-Fi chipset vendor",
                 userRole: "an engineer reporting a Wi-Fi 7 driver stability issue",
                 goal: "describe the issue, reproduction steps and environment, negotiate a fix timeline"),
        Scenario(id: "schedule", title: "專案時程協商", mode: .workTech,
                 aiRole: "a demanding customer program manager who wants an earlier delivery date",
                 userRole: "the BSP team lead",
                 goal: "explain technical risks, push back politely, and propose a realistic compromise"),
        Scenario(id: "booth", title: "展會攤位介紹產品", mode: .workTech,
                 aiRole: "a visitor at an embedded systems trade show booth",
                 userRole: "an engineer introducing the company's industrial computers and embedded boards",
                 goal: "introduce products, answer questions about OS support, lifecycle, and customization"),
        Scenario(id: "design_review", title: "技術設計審查", mode: .workTech,
                 aiRole: "a senior architect reviewing a design proposal",
                 userRole: "the engineer presenting a design for a new board's software stack",
                 goal: "explain design decisions (bootloader, device tree, kernel version, update strategy) and handle challenging questions"),
    ]

    static func scenarios(for mode: PracticeMode) -> [Scenario] {
        all.filter { $0.mode == mode }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    let text: String
    var feedback: String? = nil
}

struct SessionRecord: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let title: String
    let summary: String
    let turns: Int
    let transcript: [ChatMessage]
}

/// A message sent to the LLM API.
struct LLMMessage: Codable {
    let role: String   // "user" or "assistant"
    let content: String
}

import Foundation

enum LLMError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "尚未設定 API Key"
        case .http(let code, let body):
            let hint = code == 429 ? "\n（用量超過限制：免費方案每分鐘/每天次數有限，請稍後再試或改用其他模型）" : ""
            return "API 錯誤 \(code)：\(body.prefix(500))\(hint)"
        case .badResponse: return "無法解析 API 回應"
        }
    }
}

/// Minimal client for OpenAI Chat Completions and Anthropic Messages APIs.
struct LLMService {
    let provider: AIProvider
    let apiKey: String
    let model: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    func complete(system: String, messages: [LLMMessage], maxTokens: Int = 400, json: Bool = false) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingKey }
        switch provider {
        case .openAI: return try await openAI(key: key, system: system, messages: messages, maxTokens: maxTokens, json: json)
        case .claude: return try await claude(key: key, system: system, messages: messages, maxTokens: maxTokens)
        case .gemini: return try await gemini(key: key, system: system, messages: messages, maxTokens: maxTokens, json: json)
        }
    }

    // MARK: OpenAI

    private func openAI(key: String, system: String, messages: [LLMMessage], maxTokens: Int, json: Bool) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": msgs,
            "max_completion_tokens": maxTokens,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw LLMError.badResponse }
        return content
    }

    // MARK: Claude

    private func claude(key: String, system: String, messages: [LLMMessage], maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw LLMError.badResponse }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw LLMError.badResponse }
        return text
    }

    // MARK: Gemini (generateContent REST API)

    enum GeminiThinking: Sendable {
        case level(String)   // Gemini 3.x / 4: "minimal" | "low" | "medium" | "high"
        case budget(Int)     // Gemini 2.5: 0 disables thinking (Flash)
    }

    /// Pick the lowest-latency thinking setting the model supports.
    static func geminiThinking(for model: String) -> GeminiThinking? {
        let m = model.lowercased()
        if m.contains("2.5") {
            if m.contains("flash-lite") { return nil }      // doesn't think by default
            if m.contains("flash") { return .budget(0) }
            return nil                                       // 2.5 Pro can't disable thinking
        }
        if m.contains("flash-lite") || m.contains("3.6-flash") || m.contains("3.5-flash") {
            return .level("minimal")
        }
        return .level("low")                                 // e.g. 3.8 Flash / Gemini 4 don't accept "minimal"
    }

    private func gemini(key: String, system: String, messages: [LLMMessage], maxTokens: Int, json: Bool) async throws -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")
        let thinking = Self.geminiThinking(for: name)
        do {
            return try await Self.geminiOnce(key: key, model: name, system: system, messages: messages,
                                             maxTokens: maxTokens, json: json, thinking: thinking)
        } catch LLMError.http(400, let body) where thinking != nil && body.lowercased().contains("think") {
            // Model rejected our thinking setting — retry with the model's default.
            return try await Self.geminiOnce(key: key, model: name, system: system, messages: messages,
                                             maxTokens: maxTokens, json: json, thinking: nil)
        }
    }

    private static func geminiOnce(key: String, model name: String, system: String, messages: [LLMMessage],
                                   maxTokens: Int, json: Bool, thinking: GeminiThinking?) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent") else {
            throw LLMError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Gemini uses "model" instead of "assistant"; the last turn must be a user turn.
        let contents: [[String: Any]] = messages.map {
            ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]]
        }
        // Thinking tokens count toward maxOutputTokens, so leave headroom.
        var generationConfig: [String: Any] = ["maxOutputTokens": max(maxTokens * 4, 1024)]
        if json { generationConfig["responseMimeType"] = "application/json" }
        switch thinking {
        case .level(let l): generationConfig["thinkingConfig"] = ["thinkingLevel": l]
        case .budget(let b): generationConfig["thinkingConfig"] = ["thinkingBudget": b]
        case nil: break
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": generationConfig,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw LLMError.badResponse }
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw LLMError.badResponse }
        return text
    }

    // MARK: OpenAI text-to-speech (optional, nicer voice)

    static func openAISpeech(key: String, text: String, voice: String, speed: Double) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": text,
            "response_format": "mp3",
            "instructions": "Speak in a warm, friendly, natural tone like a patient English conversation partner. Speak at a \(speed < 0.45 ? "slow" : "moderate") pace with clear pronunciation.",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Both OpenAI and Anthropic return {"error": {"type"/"code": ..., "message": ...}}
            var detail = String(data: data, encoding: .utf8) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any] {
                let kind = (err["type"] as? String) ?? (err["status"] as? String) ?? (err["code"] as? String) ?? ""
                let msg = (err["message"] as? String) ?? ""
                detail = kind.isEmpty ? msg : "[\(kind)] \(msg)"
            }
            throw LLMError.http(http.statusCode, detail)
        }
    }
}

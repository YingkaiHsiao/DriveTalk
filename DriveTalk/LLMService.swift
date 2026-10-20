import Foundation

enum LLMError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "尚未設定 API Key"
        case .http(let code, let body): return "API 錯誤 \(code)：\(body.prefix(300))"
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
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

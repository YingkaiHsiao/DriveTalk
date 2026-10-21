import Foundation

/// Timing + usage of one streamed reply (also used by the model speed test).
struct StreamStats {
    var text = ""
    var firstTokenSeconds: Double?
    var totalSeconds: Double = 0
    var inputTokens: Int?
    var outputTokens: Int?
}

extension LLMService {
    /// Streams the reply (Server-Sent Events) and calls `onDelta` with each new piece of text,
    /// so the app can start speaking before the whole answer has arrived.
    func stream(system: String, messages: [LLMMessage], maxTokens: Int = 400,
                onDelta: @escaping @MainActor (String) -> Void) async throws -> StreamStats {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingKey }

        switch provider {
        case .openAI:
            let candidates = Self.reasoningCandidates(for: model)
            for (i, effort) in candidates.enumerated() {
                do {
                    let req = try openAIStreamRequest(key: key, system: system, messages: messages,
                                                      maxTokens: maxTokens, effort: effort)
                    return try await run(req, onDelta: onDelta)
                } catch LLMError.http(400, let b) where i < candidates.count - 1 && b.lowercased().contains("reasoning") {
                    continue
                }
            }
            throw LLMError.badResponse
        case .claude:
            return try await run(claudeStreamRequest(key: key, system: system, messages: messages, maxTokens: maxTokens),
                                 onDelta: onDelta)
        case .gemini:
            let thinking = Self.geminiThinking(for: model)
            do {
                return try await run(geminiStreamRequest(key: key, system: system, messages: messages,
                                                         maxTokens: maxTokens, thinking: thinking), onDelta: onDelta)
            } catch LLMError.http(400, let b) where thinking != nil && b.lowercased().contains("think") {
                return try await run(geminiStreamRequest(key: key, system: system, messages: messages,
                                                         maxTokens: maxTokens, thinking: nil), onDelta: onDelta)
            }
        }
    }

    // MARK: Requests

    private func openAIStreamRequest(key: String, system: String, messages: [LLMMessage],
                                     maxTokens: Int, effort: String?) throws -> URLRequest {
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
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let effort { body["reasoning_effort"] = effort }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func claudeStreamRequest(key: String, system: String, messages: [LLMMessage], maxTokens: Int) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            // Cache the (identical every turn) system prompt: faster and much cheaper on later turns.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func geminiStreamRequest(key: String, system: String, messages: [LLMMessage],
                                     maxTokens: Int, thinking: GeminiThinking?) throws -> URLRequest {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "models/", with: "")
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent?alt=sse") else {
            throw LLMError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var generationConfig: [String: Any] = ["maxOutputTokens": max(maxTokens * 4, 1024)]
        switch thinking {
        case .level(let l): generationConfig["thinkingConfig"] = ["thinkingLevel": l]
        case .budget(let b): generationConfig["thinkingConfig"] = ["thinkingBudget": b]
        case nil: break
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": messages.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]] },
            "generationConfig": generationConfig,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: SSE loop

    private func run(_ req: URLRequest, onDelta: @escaping @MainActor (String) -> Void) async throws -> StreamStats {
        let start = Date()
        let (bytes, resp) = try await Self.session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            try Self.check(resp, data)
        }
        var stats = StreamStats()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw LLMError.http(500, err["message"] as? String ?? "stream error")
            }
            let delta = extractDelta(obj, into: &stats)
            if !delta.isEmpty {
                if stats.firstTokenSeconds == nil { stats.firstTokenSeconds = Date().timeIntervalSince(start) }
                stats.text += delta
                await onDelta(delta)
            }
        }
        stats.totalSeconds = Date().timeIntervalSince(start)
        guard !stats.text.isEmpty else { throw LLMError.badResponse }
        return stats
    }

    private func extractDelta(_ obj: [String: Any], into stats: inout StreamStats) -> String {
        switch provider {
        case .openAI:
            if let usage = obj["usage"] as? [String: Any] {
                stats.inputTokens = usage["prompt_tokens"] as? Int
                stats.outputTokens = usage["completion_tokens"] as? Int
            }
            let choices = obj["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String ?? ""
        case .claude:
            switch obj["type"] as? String {
            case "message_start":
                if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                    stats.inputTokens = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                        + (u["cache_creation_input_tokens"] as? Int ?? 0)
                }
                return ""
            case "message_delta":
                if let u = obj["usage"] as? [String: Any] { stats.outputTokens = u["output_tokens"] as? Int }
                return ""
            case "content_block_delta":
                let d = obj["delta"] as? [String: Any]
                return d?["type"] as? String == "text_delta" ? (d?["text"] as? String ?? "") : ""
            default:
                return ""
            }
        case .gemini:
            if let u = obj["usageMetadata"] as? [String: Any] {
                stats.inputTokens = u["promptTokenCount"] as? Int
                stats.outputTokens = (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0)
            }
            let cands = obj["candidates"] as? [[String: Any]]
            let content = cands?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
    }
}

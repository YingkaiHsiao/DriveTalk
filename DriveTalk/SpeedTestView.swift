import SwiftUI

/// Measures each model's real response speed from the user's own phone and network.
struct SpeedTestView: View {
    @EnvironmentObject var settings: SettingsStore

    struct Row: Identifiable {
        let model: String
        var runs: [StreamStats] = []
        var error: String?
        var running = false
        var id: String { model }

        var avgFirst: Double? { avg(runs.compactMap(\.firstTokenSeconds)) }
        var avgTotal: Double? { avg(runs.map(\.totalSeconds)) }
        var avgIn: Int? { avg(runs.compactMap(\.inputTokens).map { Double($0) }).map { Int($0) } }
        var avgOut: Int? { avg(runs.compactMap(\.outputTokens).map { Double($0) }).map { Int($0) } }
        var sample: String { runs.last?.text ?? "" }

        private func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    }

    @State private var rows: [Row] = []
    @State private var running = false
    @State private var extraModel = ""
    @State private var rounds = 3

    /// OpenAI models covered by the "share data → free daily tokens" small-model group.
    private static let openAIFree: Set<String> = [
        "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o-mini", "gpt-5-mini", "gpt-5-nano", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.6-luna", "gpt-5.6-terra",
    ]

    private var defaultModels: [String] { ModelCatalog.options(for: settings.provider).map(\.id) }

    private var currentModel: String { settings.activeModel }

    var body: some View {
        List {
            Section {
                Stepper("每個模型測 \(rounds) 次", value: $rounds, in: 1...5)
                Button {
                    Task { await runAll() }
                } label: {
                    HStack {
                        Label(running ? "測試中…" : "開始測試（\(settings.provider.rawValue)）", systemImage: "speedometer")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running || !settings.isConfigured)
                if !settings.isConfigured {
                    Text("請先在設定輸入 \(settings.provider.rawValue) API Key").foregroundStyle(.orange)
                }
            } footer: {
                Text("用真實的對話請求（含系統提示與幾輪對話紀錄）實測。「開始講話」＝送出到收到第一個字的時間，App 用串流朗讀，所以這個數字最接近你感覺到的等待時間。每次測試約用掉 1,500～2,500 tokens。")
            }

            Section("結果") {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(r.model).font(.headline)
                            if settings.provider == .openAI && Self.openAIFree.contains(r.model) {
                                Text("免費額度").font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.25), in: Capsule())
                            }
                            if r.model == currentModel {
                                Text("使用中").font(.caption2.bold()).foregroundStyle(.blue)
                            }
                            Spacer()
                            if r.running { ProgressView() }
                        }
                        if let e = r.error {
                            Text(e).font(.caption).foregroundStyle(.orange).lineLimit(3)
                        } else if let first = r.avgFirst, let total = r.avgTotal {
                            HStack(spacing: 16) {
                                metric("開始講話", String(format: "%.2f 秒", first), good: first < 1.0, bad: first > 2.0)
                                metric("完整回覆", String(format: "%.2f 秒", total), good: total < 2.0, bad: total > 4.0)
                                if let i = r.avgIn, let o = r.avgOut {
                                    metric("tokens", "\(i)+\(o)", good: false, bad: false)
                                }
                            }
                            if !r.sample.isEmpty {
                                Text(r.sample).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if r.model != currentModel {
                                Button("改用這個模型") { use(r.model) }.font(.callout)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("加入其他模型") {
                HStack {
                    TextField("模型名稱", text: $extraModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("加入") {
                        let m = extraModel.trimmingCharacters(in: .whitespaces)
                        if !m.isEmpty, !rows.contains(where: { $0.model == m }) { rows.append(Row(model: m)) }
                        extraModel = ""
                    }
                }
            }
        }
        .navigationTitle("模型速度測試")
        .onAppear { if rows.isEmpty { resetRows() } }
        .onChange(of: settings.provider) { _, _ in resetRows() }
    }

    private func metric(_ title: String, _ value: String, good: Bool, bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(good ? Color.green : (bad ? Color.orange : Color.primary))
        }
    }

    private func resetRows() {
        var models = defaultModels
        if !models.contains(currentModel) { models.insert(currentModel, at: 0) }
        rows = models.map { Row(model: $0) }
    }

    private func use(_ model: String) {
        switch settings.provider {
        case .openAI: settings.openAIModel = model
        case .claude: settings.claudeModel = model
        case .gemini: settings.geminiModel = model
        }
    }

    private func runAll() async {
        running = true
        defer { running = false }
        let system = PromptBuilder.system(mode: .free, scenario: nil, level: settings.level,
                                          feedback: true, feedbackLanguage: settings.feedbackLanguage)
        let history: [LLMMessage] = [
            LLMMessage(role: "user", content: PromptBuilder.startToken),
            LLMMessage(role: "assistant", content: "REPLY: Hi! How was your day at work today?"),
            LLMMessage(role: "user", content: "it was busy, i have a meeting with customer about the boot issue"),
            LLMMessage(role: "assistant", content: "FEEDBACK: Better: \"I had a meeting with a customer about the boot issue.\"\nBETTER: I had a meeting with a customer about the boot issue.\nREPLY: That sounds busy! What was causing the boot issue?"),
            LLMMessage(role: "user", content: "we found the bootloader can not verify the image, so we need update the key"),
        ]
        for i in rows.indices {
            rows[i].runs = []
            rows[i].error = nil
            rows[i].running = true
            let service = LLMService(provider: settings.provider, apiKey: settings.activeKey, model: rows[i].model)
            for _ in 0..<rounds {
                do {
                    let stats = try await service.stream(system: system, messages: history, maxTokens: 400) { _ in }
                    rows[i].runs.append(stats)
                } catch {
                    rows[i].error = error.localizedDescription
                    break
                }
            }
            rows[i].running = false
        }
        // Fastest first
        rows.sort { ($0.avgFirst ?? 99) < ($1.avgFirst ?? 99) }
    }
}

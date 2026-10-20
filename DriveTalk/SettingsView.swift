import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("AI 服務", selection: $settings.provider) {
                        ForEach(AIProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if settings.provider == .openAI {
                        SecureField("OpenAI API Key (sk-...)", text: $settings.openAIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型", text: $settings.openAIModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Anthropic API Key (sk-ant-...)", text: $settings.claudeKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型", text: $settings.claudeModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("測試連線")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || !settings.isConfigured)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI 綁定")
                } footer: {
                    Text("API Key 只存在本機 iOS 鑰匙圈，直接連到 OpenAI / Anthropic，不經過其他伺服器。開車對話建議用速度快的小模型。")
                }

                Section("練習內容") {
                    Picker("模式", selection: $settings.mode) {
                        ForEach(PracticeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if settings.mode != .free {
                        Picker("情境", selection: $settings.scenarioID) {
                            ForEach(Scenario.scenarios(for: settings.mode)) { Text($0.title).tag($0.id) }
                        }
                    }
                    Picker("程度", selection: $settings.level) {
                        ForEach(EnglishLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section {
                    Toggle("即時糾錯回饋", isOn: $settings.feedbackEnabled)
                    if settings.feedbackEnabled {
                        Picker("回饋說明語言", selection: $settings.feedbackLanguage) {
                            ForEach(FeedbackLanguage.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                } header: {
                    Text("糾錯")
                } footer: {
                    Text("每次你說完，若有明顯的文法或用字問題，AI 會先唸一句更自然的說法，再繼續對話。")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("AI 語速：\(settings.speechRate, specifier: "%.2f")")
                        Slider(value: $settings.speechRate, in: 0.35...0.6, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("停頓多久算說完：\(settings.silenceTimeout, specifier: "%.1f") 秒")
                        Slider(value: $settings.silenceTimeout, in: 1.0...4.0, step: 0.1)
                    }
                    Toggle("使用 OpenAI 語音（更自然）", isOn: $settings.useOpenAITTS)
                    if settings.useOpenAITTS {
                        if settings.openAIKey.isEmpty {
                            Text("需要 OpenAI API Key（即使對話使用 Claude）").font(.footnote).foregroundStyle(.orange)
                            SecureField("OpenAI API Key", text: $settings.openAIKey)
                                .textInputAutocapitalization(.never)
                        }
                        Picker("聲音", selection: $settings.openAIVoice) {
                            ForEach(SettingsStore.openAIVoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } header: {
                    Text("語音")
                } footer: {
                    Text("未開啟 OpenAI 語音時使用 iPhone 內建語音（免費、離線）。到 iOS 設定 > 輔助使用 > 語音內容 > 聲音 > English 下載「進階 (Premium)」語音，音質會好很多。")
                }

                Section("語音指令（行車中免動手）") {
                    LabeledContent("重講一次", value: "\"repeat\"")
                    LabeledContent("講慢一點", value: "\"slow down\"")
                    LabeledContent("講快一點", value: "\"speak faster\"")
                    LabeledContent("結束練習", value: "\"stop practice\"")
                    LabeledContent("不會說時", value: "\"How do I say…?\"")
                }
            }
            .navigationTitle("設定")
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let service = LLMService(provider: settings.provider, apiKey: settings.activeKey, model: settings.activeModel)
        do {
            let r = try await service.complete(system: "Reply with exactly: Ready to practice!",
                                               messages: [LLMMessage(role: "user", content: "Hi")], maxTokens: 20)
            testResult = "✅ 連線成功：\(r)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

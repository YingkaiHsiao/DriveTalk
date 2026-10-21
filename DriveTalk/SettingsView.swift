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
                        ModelPickerField(provider: .openAI, model: $settings.openAIModel)
                    } else if settings.provider == .claude {
                        SecureField("Anthropic API Key (sk-ant-...)", text: $settings.claudeKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ModelPickerField(provider: .claude, model: $settings.claudeModel)
                    } else {
                        SecureField("Gemini API Key (AIza...)", text: $settings.geminiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ModelPickerField(provider: .gemini, model: $settings.geminiModel)
                        Text("免費 Key：aistudio.google.com → Get API key。免費方案有每日次數限制，建議用 Flash-Lite 模型；免費方案的對話可能被 Google 用於改進模型，請勿說公司機密。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    Text("API Key 只存在本機 iOS 鑰匙圈，直接連到 OpenAI / Anthropic / Google，不經過其他伺服器。開車對話建議用速度快的小模型。")
                }

                Section("練習內容") {
                    Picker("模式", selection: $settings.mode) {
                        ForEach(PracticeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if settings.mode == .shadowing {
                        Picker("跟讀主題", selection: $settings.shadowTopic) {
                            ForEach(ShadowTopic.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("每句也唸中文意思", isOn: $settings.shadowSayChinese)
                    }
                    if settings.mode == .news {
                        Picker("新聞類別", selection: $settings.newsCategory) {
                            ForEach(NewsCategory.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if settings.mode.usesScenario {
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
                    Text("每次你說完，若有明顯的文法或用字問題，AI 會先唸一句更自然的說法，再繼續對話；修正會自動收進「表達方式」。")
                }

                Section {
                    Picker("辨識引擎", selection: $settings.speechEngine) {
                        ForEach(SpeechEngine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if settings.speechEngine == .apple {
                        Toggle("使用 Apple 伺服器辨識（較準確）", isOn: $settings.appleServerRecognition)
                    } else if settings.openAIKey.isEmpty {
                        Text("需要 OpenAI API Key（即使對話使用 Claude / Gemini）").font(.footnote).foregroundStyle(.orange)
                        SecureField("OpenAI API Key", text: $settings.openAIKey)
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("語音辨識")
                } footer: {
                    Text(settings.speechEngine == .apple
                         ? "免費。想用中文發問時先說「Chinese please」，下一句就用中文辨識。會自動把你生字本與情境的單字當成辨識提示。"
                         : "說完後把錄音送到 OpenAI（gpt-4o-mini-transcribe）轉文字，台灣口音英文、中英混講都辨識得比較準，可以直接用中文發問。不在每日免費額度內，約每講 1 分鐘 US$0.003。失敗時自動改用 iPhone 辨識。")
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

                Section {
                    NavigationLink("模型速度測試") { SpeedTestView() }
                } footer: {
                    Text("用你的手機與網路實測各模型的回應速度與 token 用量，選出最適合開車對話的模型。")
                }

                Section("語音指令（行車中免動手）") {
                    LabeledContent("重講一次", value: "\"repeat\"")
                    LabeledContent("講慢一點", value: "\"slow down\"")
                    LabeledContent("講快一點", value: "\"speak faster\"")
                    LabeledContent("結束練習", value: "\"stop practice\"")
                    LabeledContent("用中文問", value: "\"Chinese please\"")
                    LabeledContent("跳過（跟讀）", value: "\"next\"")
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
                                               messages: [LLMMessage(role: "user", content: "Hi")], maxTokens: 200)
            testResult = "✅ 連線成功：\(r)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

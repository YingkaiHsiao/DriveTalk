import SwiftUI

/// Known models per provider, shown in the model drop-down (any other name can be typed in).
enum ModelCatalog {
    struct Option: Identifiable, Hashable {
        let id: String
        let note: String
    }

    static func options(for provider: AIProvider) -> [Option] {
        switch provider {
        case .openAI:
            return [
                Option(id: "gpt-5.6-luna", note: "新・快又聰明・免費額度"),
                Option(id: "gpt-5.6-terra", note: "新・更聰明・免費額度"),
                Option(id: "gpt-4.1-mini", note: "穩定・快・免費額度"),
                Option(id: "gpt-4.1-nano", note: "最快・免費額度・糾錯較弱"),
                Option(id: "gpt-4o-mini", note: "快・免費額度"),
                Option(id: "gpt-5-mini", note: "推理模型・免費額度"),
                Option(id: "gpt-5-nano", note: "推理模型・免費額度"),
                Option(id: "gpt-5.4-mini", note: "免費額度"),
                Option(id: "gpt-5.4-nano", note: "免費額度"),
                Option(id: "gpt-4.1", note: "品質高・免費額度少"),
            ]
        case .claude:
            return [
                Option(id: "claude-haiku-4-5", note: "推薦・快"),
                Option(id: "claude-sonnet-4-5", note: "品質高・較慢較貴"),
            ]
        case .gemini:
            return [
                Option(id: "gemini-3.5-flash-lite", note: "推薦・快・免費次數較多"),
                Option(id: "gemini-3.1-flash-lite", note: "快・免費"),
                Option(id: "gemini-3.6-flash", note: "品質較好・較慢"),
                Option(id: "gemini-3.8-flash", note: "最新・最慢・免費次數最少"),
            ]
        }
    }
}

/// Drop-down of known models, plus "自訂輸入…" to type any model name.
struct ModelPickerField: View {
    let provider: AIProvider
    @Binding var model: String
    @State private var custom = false

    private static let customTag = "__custom__"
    private var options: [ModelCatalog.Option] { ModelCatalog.options(for: provider) }

    var body: some View {
        Picker("模型", selection: Binding(
            get: { custom ? Self.customTag : model },
            set: { v in
                if v == Self.customTag {
                    custom = true
                } else {
                    custom = false
                    model = v
                }
            }
        )) {
            ForEach(options) { o in
                Text("\(o.id)（\(o.note)）").tag(o.id)
            }
            Text("自訂輸入…").tag(Self.customTag)
        }
        .pickerStyle(.navigationLink)
        .onAppear {
            custom = !options.contains { $0.id == model }
        }

        if custom {
            TextField("輸入模型名稱，例如 gpt-4.1-mini", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

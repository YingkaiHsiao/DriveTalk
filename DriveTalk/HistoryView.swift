import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView("尚無練習紀錄", systemImage: "car",
                                           description: Text("完成一次至少 2 輪的對話後，會自動產生學習摘要。"))
                } else {
                    List {
                        ForEach(store.records) { r in
                            NavigationLink {
                                SessionDetailView(record: r)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.title).font(.headline)
                                    Text("\(r.date.formatted(date: .abbreviated, time: .shortened))・\(r.turns) 輪")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .themeBackground()
            .navigationTitle("練習紀錄")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct SessionDetailView: View {
    let record: SessionRecord
    @State private var tab = 0

    var body: some View {
        VStack {
            Picker("", selection: $tab) {
                Text("學習摘要").tag(0)
                Text("完整對話").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if tab == 0 {
                ScrollView {
                    Text(record.summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                TranscriptList(messages: record.transcript)
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: "\(record.title)\n\n\(record.summary)\n\n---\n\(PromptBuilder.transcriptText(record.transcript))")
        }
    }
}

import SwiftUI
import Charts

/// 學習統計：時間、詞彙、表達方式、跟讀。
struct StatsView: View {
    @ObservedObject private var progress = ProgressStore.shared
    @ObservedObject private var vocab = VocabStore.shared
    @State private var range = 7

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    timeSection
                    vocabSection
                    expressionSection
                    shadowSection
                }
                .padding()
            }
            .background(AppBackground())
            .navigationTitle("學習統計")
        }
    }

    // MARK: 學習時間

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("學習時間").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "今天", value: minutes(progress.today.totalMinutes),
                         detail: "練習 \(minutes(progress.today.practiceSeconds / 60))・閱讀查詢 \(minutes(progress.today.studySeconds / 60))")
                StatTile(title: "連續學習", value: "\(progress.streak) 天", detail: "每天至少 1 分鐘")
                StatTile(title: "累計", value: hours(progress.totalMinutes), detail: "開車練習 \(hours(progress.totalPracticeMinutes))")
                StatTile(title: "練習次數", value: "\(progress.totalSessions)", detail: "說了 \(progress.totalTurns) 句")
            }

            Picker("", selection: $range) {
                Text("近 7 天").tag(7)
                Text("近 30 天").tag(30)
            }
            .pickerStyle(.segmented)

            let data = progress.lastDays(range)
            Chart(data) { d in
                BarMark(x: .value("日期", d.date, unit: .day),
                        y: .value("分鐘", d.minutes))
                    .foregroundStyle(Color.green.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("分鐘")
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                }
            }
            .frame(height: 180)
            .accessibilityLabel("每日學習分鐘數長條圖")

            Text("平均每天 \(minutes(data.map(\.minutes).reduce(0, +) / Double(max(1, data.count))))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 詞彙

    private var vocabSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("詞彙").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "生字本", value: "\(vocab.entries.count)", detail: "已熟記 \(vocab.masteredCount)・待複習 \(vocab.dueEntries.count)")
                StatTile(title: "說過的不同單字", value: "\(progress.wordsUsed.count)", detail: "總共說了 \(progress.totalWordsSpoken) 個字")
                StatTile(title: "查詢／翻譯／修正", value: "\(progress.totalLookups)", detail: "今天 \(progress.today.lookups + progress.today.translations + progress.today.grammarChecks)")
                StatTile(title: "本週新增單字", value: "\(vocab.entries.filter { $0.added > Date().addingTimeInterval(-7 * 86_400) }.count)", detail: "近 7 天")
            }

            let top = progress.topWords(15)
            if !top.isEmpty {
                Text("你最常用的字").font(.headline)
                FlowWords(words: top.map { "\($0.word) ×\($0.count)" })
            }
        }
    }

    // MARK: 表達方式

    private var expressionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("表達方式").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "收集的說法", value: "\(progress.expressions.count)",
                         detail: "待複習 \(progress.dueExpressions.count)")
                StatTile(title: "今天被糾正", value: "\(progress.today.corrections)", detail: "改成更自然的說法")
            }
            if !progress.expressions.isEmpty {
                Text("最近學到的說法").font(.headline)
                ForEach(progress.expressions.prefix(5)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.better).font(.callout.weight(.semibold))
                        if !e.original.isEmpty {
                            Text(e.original).font(.caption).strikethrough().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 跟讀

    private var shadowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跟讀").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "跟讀句數", value: "\(progress.totalShadows)", detail: "今天 \(progress.today.shadowCount)")
                StatTile(title: "平均分數", value: progress.totalShadows == 0 ? "—" : "\(progress.averageShadowScore)",
                         detail: "85 分以上算過關")
            }
        }
    }

    private func minutes(_ m: Double) -> String {
        m < 1 ? "\(Int((m * 60).rounded())) 秒" : "\(Int(m.rounded())) 分"
    }

    private func hours(_ m: Double) -> String {
        m < 60 ? minutes(m) : String(format: "%.1f 小時", m / 60)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(padding: 12)
    }
}

/// Simple wrapping row of word chips.
private struct FlowWords: View {
    let words: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(words, id: \.self) { w in
                Text(w)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.chip, in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

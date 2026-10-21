import SwiftUI

/// 使用說明：可搜尋的用法、語音指令、疑難排解。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pron = Pronouncer.shared
    @State private var search = ""

    struct Command: Identifiable {
        let say: String          // what to say (English is tappable to hear it)
        let meaning: String
        var id: String { say }
    }

    struct Topic: Identifiable {
        let title: String
        let icon: String
        let body: String
        var id: String { title }
    }

    struct Section: Identifiable {
        let title: String
        let topics: [Topic]
        var id: String { title }
    }

    static let commands: [Command] = [
        Command(say: "Translate", meaning: "翻譯 AI 上一句（先唸中文，再慢慢唸英文）"),
        Command(say: "What does that mean?", meaning: "同上，翻譯上一句"),
        Command(say: "Repeat", meaning: "AI 再說一次上一句"),
        Command(say: "Slow down", meaning: "AI 講慢一點"),
        Command(say: "Speak faster", meaning: "AI 講快一點"),
        Command(say: "Chinese please", meaning: "下一句改用中文辨識（iPhone 辨識時用）"),
        Command(say: "What does mitigate mean?", meaning: "問單字意思，AI 用英文解釋＋例句，並存進生字本"),
        Command(say: "How do I say 延期 in English?", meaning: "問中文怎麼說（中文字需 OpenAI 辨識或先說 Chinese please）"),
        Command(say: "Next", meaning: "跟讀時跳過這一句"),
        Command(say: "Next news", meaning: "新聞模式換下一則"),
        Command(say: "I need to focus on driving", meaning: "AI 簡短回應並等你"),
        Command(say: "Stop practice", meaning: "結束練習並產生學習摘要"),
    ]

    static let sections: [Section] = [
        Section(title: "快速開始", topics: [
            Topic(title: "第一次設定", icon: "gearshape",
                  body: "練習頁右上角 ⚙️ → 選 AI 服務（OpenAI / Claude / Gemini）→ 貼上 API Key → 按「測試連線」出現 ✅ 即可。模型可用下拉選單選，或選「自訂輸入…」自己打。"),
            Topic(title: "開車前怎麼用", icon: "car.fill",
                  body: "停車時選好模式，按「開始練習」，聽到「叮」一聲後放好手機出發。之後全程用說的，不需要看或碰螢幕。螢幕鎖定、接藍牙車機都可以繼續。"),
            Topic(title: "畫面燈號", icon: "circle.fill",
                  body: "綠色＝輪到你說；黃色＝AI 思考中；藍色＝AI 說話中；橘色＝被電話或 Siri 中斷，結束後會自動繼續。你講完會聽到「叮」，代表已收到。"),
        ]),
        Section(title: "練習模式", topics: [
            Topic(title: "自由對話", icon: "bubble.left.and.bubble.right",
                  body: "每次隨機換開場話題與開場方式，聊日常、工作、科技、旅遊等。"),
            Topic(title: "情境角色扮演 / 工作英文", icon: "person.2",
                  body: "在設定選情境（餐廳、面試、客戶 FAE 電話、站會報告、CVE 說明…），AI 扮演對方，每次會加一個隨機狀況（對方很趕、中途改需求…）。"),
            Topic(title: "新聞聽讀討論", icon: "newspaper",
                  body: "AI 先朗讀一篇依你程度改寫的 BBC 新聞，再逐題用語音問你問題。說「Next news」換下一則。也可以在「新聞」分頁按「開車聽＋語音討論」。"),
            Topic(title: "跟讀練習（跟著唸）", icon: "repeat",
                  body: "AI 唸一句（可加唸中文意思），你跟著唸，手機直接打分數：85 分以上過關，沒過會提示沒唸到的字，最多 3 次。說「Next」跳過、「Translate」聽中文意思。評分在手機上算，不花 token。"),
            Topic(title: "智慧複習（生字＋表達）", icon: "brain.head.profile",
                  body: "AI 用對話考你到期的單字與表達方式，自動判斷答對與否並安排下次複習時間。"),
        ]),
        Section(title: "即時糾錯與中文", topics: [
            Topic(title: "即時糾錯", icon: "checkmark.bubble",
                  body: "你說完若有明顯文法或用字問題，AI 會先說 Better: \"…\" 再繼續對話。更自然的說法會自動存進「生字本 > 表達方式」。可在設定關閉，或改用中文說明。"),
            Topic(title: "聽不懂 AI 說什麼", icon: "character.bubble",
                  body: "說「Translate」：AI 先唸中文翻譯，再慢慢唸一次英文。用 OpenAI 辨識時也可以直接說「翻譯」「什麼意思」「聽不懂」。"),
            Topic(title: "用中文發問", icon: "questionmark.bubble",
                  body: "iPhone 辨識：先說「Chinese please」，下一句就能說中文，例如「延期英文怎麼說？」。OpenAI 辨識：直接說中文即可。AI 會用中文語音解釋，再請你用英文說一次。"),
        ]),
        Section(title: "停車時使用的分頁", topics: [
            Topic(title: "查詢 > 單字", icon: "character.book.closed",
                  body: "輸入英文或中文，得到音標、意思、例句（可點喇叭發音），按「加入生字本」。查過且存過的字再查不花 token。"),
            Topic(title: "查詢 > 翻譯", icon: "globe",
                  body: "輸入中文翻成英文（附較口語／較正式說法與台式英文提醒），輸入英文翻成中文。"),
            Topic(title: "查詢 > 文法修正", icon: "checkmark.seal",
                  body: "貼上你寫的 email 或訊息，得到修正版、更自然的說法與每個錯誤的中文說明，可存到表達方式拿來跟讀。"),
            Topic(title: "查詢 > 中文發問", icon: "text.bubble",
                  body: "用中文問任何英文問題，例如「affect 和 effect 差在哪？」，得到中文解答與例句。"),
            Topic(title: "新聞", icon: "newspaper",
                  body: "選類別看 BBC 最新新聞，點進去 AI 依程度改寫成短文。文章裡每個英文字都能點擊查詢，可朗讀、加入重點單字、看討論問題與原文連結。改寫過的文章會存起來，不重複花 token。"),
            Topic(title: "生字本", icon: "bookmark",
                  body: "「單字」與「表達方式」兩個清單。上方「卡片複習」：看題目 → 顯示答案 → 選 忘記／模糊／記得／很熟，系統依記憶狀況安排下次複習（忘記 10 分鐘後再出現，記得則 1、3、7…天後）。「開車語音複習」讓 AI 用說的考你。"),
            Topic(title: "統計", icon: "chart.bar.fill",
                  body: "今日／累計學習時間、連續天數、近 7／30 天圖表、生字數與已熟記數、說過的不同單字、最常用的字、收集的表達方式、跟讀分數。"),
            Topic(title: "練習紀錄", icon: "clock.arrow.circlepath",
                  body: "練習頁左上角。每次至少 2 輪對話會自動產生中文學習摘要與完整對話，可分享。"),
        ]),
        Section(title: "設定與省錢", topics: [
            Topic(title: "推薦模型", icon: "cpu",
                  body: "OpenAI：gpt-4.1-mini（穩定快速）、gpt-4.1-nano（最快）、gpt-5.6-luna（新、快又聰明）。可用「設定 > 模型速度測試」用你的手機實測，選最快的。"),
            Topic(title: "OpenAI 每日免費額度", icon: "gift",
                  body: "在 platform.openai.com 開啟資料分享（Settings > Organization > Data controls > Sharing）並保留一點餘額，小模型每天約 250 萬 tokens 免費，每天練 1 小時約用 20～35 萬。gpt-4.1 屬大模型組（每天 25 萬），不建議。"),
            Topic(title: "會額外花錢的功能", icon: "dollarsign.circle",
                  body: "「OpenAI 語音」（朗讀）與「OpenAI 高準確度辨識」不在免費額度內。想完全免費就用 iPhone 內建語音與 iPhone 辨識。建議關閉 OpenAI 自動儲值。"),
            Topic(title: "語音更自然", icon: "speaker.wave.3",
                  body: "iOS 設定 > 輔助使用 > 語音內容 > 聲音 > 英文 / 中文，下載「進階（Premium）」語音，內建朗讀會自然很多。"),
        ]),
        Section(title: "疑難排解", topics: [
            Topic(title: "辨識常常錯", icon: "waveform.badge.exclamationmark",
                  body: "設定 > 語音辨識：開啟「使用 Apple 伺服器辨識」，或改用「OpenAI 高準確度」。車上確認手機有連到車機的免持通話。說話時離麥克風近一點、一次說完整句子。"),
            Topic(title: "太早被切斷 / 要等很久才換 AI", icon: "timer",
                  body: "設定 > 語音 >「停頓多久算說完」：常被切斷就調高（1.6～2.0 秒），覺得等太久就調低（1.1～1.3 秒）。"),
            Topic(title: "AI 回應慢", icon: "tortoise",
                  body: "確認「使用 OpenAI 語音」已關閉；用「模型速度測試」換更快的模型；畫面上的「AI 回應 x.x 秒」超過 2 秒通常是網路或伺服器較慢。等太久 AI 會先說一句 \"Let me think\"。"),
            Topic(title: "API 錯誤 401", icon: "key",
                  body: "API Key 錯誤、已刪除或沒有權限。重新貼上 Key 後按「測試連線」。"),
            Topic(title: "API 錯誤 400", icon: "exclamationmark.triangle",
                  body: "常見原因：餘額不足（credit balance）、模型名稱錯誤或帳號沒有該模型權限。看錯誤訊息後半段的英文說明，或換成下拉選單裡的模型。"),
            Topic(title: "API 錯誤 429", icon: "hourglass",
                  body: "用量或次數超過限制（Gemini 免費方案常見）。稍等再試、換模型，或改用 OpenAI。"),
            Topic(title: "App 打不開（7 天過期）", icon: "calendar.badge.exclamationmark",
                  body: "免費 Apple ID 側載的 App 每 7 天過期，用 Sideloadly 重新安裝同一個 IPA 即可，資料不會消失。"),
        ]),
    ]

    private var q: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ text: String) -> Bool { q.isEmpty || text.lowercased().contains(q) }

    var body: some View {
        NavigationStack {
            List {
                let cmds = Self.commands.filter { matches($0.say) || matches($0.meaning) }
                if !cmds.isEmpty {
                    SwiftUI.Section {
                        ForEach(cmds) { c in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("「\(c.say)」").font(.body.weight(.semibold))
                                    Text(c.meaning).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { pron.speak(c.say, rate: 0.42) } label: {
                                    Image(systemName: "speaker.wave.2")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("聽發音")
                            }
                        }
                    } header: {
                        Text("語音指令（開車時用說的）")
                    } footer: {
                        Text("點喇叭可以聽怎麼唸。")
                    }
                }

                ForEach(Self.sections) { sec in
                    let topics = sec.topics.filter { matches($0.title) || matches($0.body) || matches(sec.title) }
                    if !topics.isEmpty {
                        SwiftUI.Section(sec.title) {
                            ForEach(topics) { t in
                                DisclosureGroup {
                                    Text(t.body)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .padding(.vertical, 4)
                                } label: {
                                    Label(t.title, systemImage: t.icon)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜尋用法，例如：翻譯、跟讀、429")
            .navigationTitle("使用說明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

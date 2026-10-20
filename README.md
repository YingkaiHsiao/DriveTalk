# DriveTalk — 開車英文口說練習 App（iOS 18 / SwiftUI）

綁定 OpenAI 或 Claude API，在開車時全程用語音和 AI 對話練英文：AI 開場 → 你說 → (即時糾錯) → AI 回應 → 你說……

## 功能

- **AI 綁定**：OpenAI（預設 `gpt-4.1-mini`）、Claude（預設 `claude-haiku-4-5`）或 Google Gemini（預設 `gemini-3.5-flash-lite`，有免費方案），模型名稱可在設定中自由修改。API Key 存在 iOS 鑰匙圈。
- **四種練習**：自由對話、情境角色扮演（餐廳／飯店／機場／面試／閒聊）、工作英文（客戶 FAE 開機除錯、站會報告、Kernel CVE 說明、晶片廠 Wi-Fi 驅動問題、時程協商、展會介紹、設計審查）。
- **即時糾錯**：你說完後，AI 先唸一句 `Better: "..."` 的更自然說法（可選英文或繁中說明），再接著對話。
- **免動手**：偵測停頓自動結束你的發言；語音指令 `repeat`、`slow down`、`speak faster`、`stop practice`。
- **適合車上**：支援車用藍牙（HFP 麥克風）、螢幕鎖定/背景持續運作、來電或 Siri 中斷後自動恢復、練習中螢幕不休眠、深色大字介面。
- **練習結束摘要**：自動產生繁中學習摘要（表現、3 個重要修正、5 個實用片語），可在「練習紀錄」回顧與分享。
- **語音**：預設 iPhone 內建英文語音（免費、離線）；可選 OpenAI TTS（`gpt-4o-mini-tts`）更自然的聲音。

## 安裝到 iPhone

需求：Mac + **Xcode 16 以上**、iPhone（iOS 18）、Apple ID。

1. 用 Xcode 打開 `DriveTalk.xcodeproj`。
2. 點左側專案 **DriveTalk** → Target **DriveTalk** → **Signing & Capabilities**：
   - Team 選你的 Apple ID（Personal Team 即可）。
   - **Bundle Identifier** 改成唯一值，例如 `com.louis.drivetalk`。
3. iPhone 用線接 Mac，iPhone 開啟 **設定 > 隱私權與安全性 > 開發者模式**（重開機後確認）。
4. Xcode 上方選擇你的 iPhone，按 ▶︎ Run。
5. 第一次執行若顯示「未受信任的開發者」：iPhone **設定 > 一般 > VPN 與裝置管理** → 信任你的 Apple ID。

> 免費 Apple ID 簽署的 App 有效期 7 天，到期重新用 Xcode Run 一次即可；付費開發者帳號（US$99/年）為 1 年，也可用 TestFlight。

## 沒有 Mac？用 Windows 安裝（GitHub Actions + Sideloadly）

### A. 上傳到 GitHub 並自動編譯

1. 到 https://github.com 註冊並登入 → 右上角 **+ → New repository**
   - 名稱：`DriveTalk`
   - 建議選 **Public**（macOS 編譯時數免費無上限；API Key 不在程式碼裡，公開沒有安全疑慮）。選 Private 的話，每月免費額度大約只夠編譯 40～60 次。
   - 不要勾選「Add a README」→ **Create repository**
2. 安裝 **GitHub Desktop**（https://desktop.github.com）並登入。
3. 把 DriveTalk.zip 解壓縮（例如解到 `C:\Projects\DriveTalk`，裡面要直接看到 `DriveTalk.xcodeproj` 和 `.github` 資料夾）。
4. GitHub Desktop：**File → Add local repository** → 選這個資料夾 → 出現「not a Git repository」時按 **create a repository** → **Create repository**。
5. 按 **Publish repository**（取消勾選 Keep this code private 則為 Public）→ Publish。
6. 回到 GitHub 網頁的 repo → **Actions** 分頁，會看到「Build iOS IPA」正在執行（約 3～6 分鐘）。
   - 綠色勾勾 ✅：點進去，頁面最下方 **Artifacts** 下載 `DriveTalk-ipa`（下載的是 zip，解壓縮後得到 `DriveTalk.ipa`）。
   - 紅色叉叉 ❌：點進去 → 展開「Show compile errors」，把錯誤內容貼給 Claude 修正。

之後每次修改程式，在 GitHub Desktop 按 **Commit to main → Push origin**，就會自動重新編譯。也可以在 Actions 頁面選「Build iOS IPA」→ **Run workflow** 手動重跑。

### B. 用 Sideloadly 安裝到 iPhone

1. 在 Windows 安裝 Apple 官網版（**非** Microsoft Store 版）的 **iTunes** 和 **iCloud**，Sideloadly 需要它們的驅動程式。
2. 安裝 **Sideloadly**：https://sideloadly.io
3. iPhone 用 USB 線接電腦，iPhone 上點「信任這部電腦」。
4. 開 Sideloadly：
   - 把 `DriveTalk.ipa` 拖進左上角 IPA 圖示
   - **Apple account** 輸入你的 Apple ID（建議用一個另外註冊的 Apple ID 專門簽 App）
   - 按 **Start** → 輸入密碼與雙重認證碼 → 等待顯示 Done
5. iPhone 設定：
   - **設定 > 一般 > VPN 與裝置管理** → 點你的 Apple ID → **信任**
   - **設定 > 隱私權與安全性 > 開發者模式** → 開啟 → 重新開機 → 確認開啟
6. 打開 DriveTalk 🎉

### 免費 Apple ID 的限制

- App 每 **7 天**過期（過期後打不開，資料不會消失）。重新用 Sideloadly 安裝同一個 IPA 就能續期。Sideloadly 進階選項也有自動續簽（Auto-refresh，電腦與 iPhone 需在同一個 Wi-Fi）。
- 同時最多 3 個側載 App。
- 想免去這些限制：加入 Apple Developer Program（US$99/年）後可改用 TestFlight。

## 第一次使用

1. 右上角 ⚙️ 設定 → 選 OpenAI 或 Claude → 貼上 API Key → 「測試連線」。
   - OpenAI Key：https://platform.openai.com/api-keys
   - Claude Key：https://console.anthropic.com/settings/keys
   - Gemini Key（免費）：https://aistudio.google.com → **Get API key** → Create API key
2. 選練習模式、情境、程度，是否開啟即時糾錯。
3. 建議到 iOS **設定 > 輔助使用 > 語音內容 > 聲音 > English** 下載 Premium/Enhanced 語音，內建語音會自然很多。
4. **出發前**按「開始練習」並允許麥克風、語音辨識權限，接著放好手機開車。全程只用語音，不需看螢幕。

## 行車安全

- 請在停車時設定與按下開始；行車中只用語音指令，不要操作或閱讀螢幕。
- 說 `I need to focus on driving` AI 會簡短回應並等你；說 `stop practice` 結束。
- 本 App 不是 CarPlay App（CarPlay 需要 Apple 特殊授權），但聲音與麥克風會透過車用藍牙/CarPlay 音訊正常運作。

## 費用參考

每回合送出約數百～兩千 tokens（保留最近 30 則對話），用小模型時，30 分鐘練習通常只要幾美分；開啟 OpenAI TTS 另計語音費用。

## Gemini 免費方案說明

- 不需要綁信用卡，在 Google AI Studio 用 Google 帳號建立 API Key 即可。
- 免費方案有每分鐘與每日請求次數限制（以 AI Studio 專案頁面顯示為準）。每一輪對話算 1 次請求，Flash-Lite 系列額度通常比 Flash 多，較適合長時間練習。
- 超過額度會出現「API 錯誤 429」，等額度重置（太平洋時間午夜，約台灣下午 3～4 點）或改用其他模型。
- 免費方案的輸入與回應可能被 Google 用來改進模型並由人員審閱，練習時請勿提到公司機密。

## 程式結構

| 檔案 | 說明 |
|---|---|
| `DriveTalkApp.swift` | App 進入點 |
| `DriveView.swift` | 主畫面（大按鈕、狀態燈、字幕、對話紀錄） |
| `SettingsView.swift` | 設定（AI、練習內容、糾錯、語音） |
| `HistoryView.swift` | 練習紀錄與學習摘要 |
| `ConversationEngine.swift` | 對話主迴圈、語音指令、音訊中斷處理、AudioSession、紀錄儲存 |
| `SpeechRecognizer.swift` | Apple Speech 英文辨識（裝置端優先）、停頓偵測 |
| `Speaker.swift` | 語音播放（內建 TTS / OpenAI TTS 音檔） |
| `LLMService.swift` | OpenAI Chat Completions、Anthropic Messages、Gemini generateContent、OpenAI TTS API |
| `PromptBuilder.swift` | System prompt（角色、程度、糾錯 JSON 格式）、摘要 prompt |
| `Models.swift` | 模式、情境清單、資料模型 |

想新增情境：在 `Models.swift` 的 `Scenario.all` 加一筆即可。

## 疑難排解

- **辨識不到聲音**：確認 iOS 設定 > DriveTalk 的麥克風與語音辨識已開啟；車用藍牙請確認手機已連上車機「免持通話」。
- **太早被切斷／等太久**：設定中調整「停頓多久算說完」（預設 1.8 秒）。
- **API 錯誤 404/400**：模型名稱可能已更新，到設定改成你帳號可用的模型名稱。
- **API 錯誤 401**：API Key 錯誤或額度不足。

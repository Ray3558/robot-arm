# Codex Island 0.4 — 深色儀表板與 App 圖示

iPhone 直接以 ChatGPT / Codex 裝置碼 OAuth 登入，讀取額度並顯示在靈動島。不需要 Mac、橋接伺服器或 OpenAI API Key。最低 iOS 16.2；需要支援靈動島的 iPhone。

## 0.4 介面更新

- 深色儀表板：額度圓環、主／第二視窗卡片、重置時間與靈動島預覽。
- 獨立設定頁：OAuth 裝置碼登入步驟、六種快速配色、完整 ColorPicker 與 15／30／60 秒更新間隔。
- 專屬 App Icon：以 imagegen 產生黑色玻璃靈動島與薄荷綠額度環；圖示為 1024×1024 不透明 RGB PNG，直接內嵌 IPA。
- 未登入時顯示 —，設定頁的 75% 色彩預覽會明確註記為示範。
- GitHub Actions 在完成 IPA 後額外嘗試擷取模擬器首頁，成功時可於 CodexIsland-UI-preview 下載實際畫面。

## 下載與安裝

GitHub Actions → 最新成功的 Build unsigned IPA → Artifacts → CodexIsland-unsigned-IPA。解壓取得 IPA，以自己的側載工具重新簽署並安裝；主 App 與 QuotaWidget.appex 都必須保留並簽署。

Actions 只負責編譯，沒有接收你的 OAuth 登入資料或 Apple 憑證。未簽署 IPA 不能直接安裝。

## 手機登入步驟

1. 打開 App，按「登入 ChatGPT」。
2. 複製 App 剛產生的一次性登入碼。
3. 按「開啟官方授權頁面」，在 https://auth.openai.com/codex/device 登入並輸入該碼。
4. 完成授權後切回 App，等待登入與額度讀取完成。
5. 按「開始顯示靈動島」。

登入碼約 15 分鐘有效。若伺服器要求開啟 device-code login，請在 ChatGPT 安全性設定開啟對應的 Codex 裝置碼登入選項後重試。不會要求在本 App 輸入密碼；授權在官方網站完成。只有使用者主動開始的登入碼應被授權。

## 支援與限制

這是個人用實驗整合：Swift 原生實作參照 OpenAI Codex 的裝置碼流程與額度 API，沒有在 iOS 執行 Codex CLI。它不是 OpenAI 官方 App，也不是聲稱具有穩定支援的第三方 iOS OAuth API。

- 帳號、裝置碼開關、網路限制與服務介面變更，都可能讓登入或額度讀取失敗。實際 OAuth 授權需由使用者在手機上驗證；編譯成功不代表已完成帳號端測試。
- 顯示 ChatGPT 帳號的 Codex 額度，而非 API key 餘額。只讀取用量，不發送模型推論請求或消耗 reset credits。
- App 提供「字體顏色」ColorPicker，可選任意不透明 RGB 顏色、預覽與恢復薄荷綠。套用至 App 額度、靈動島及鎖定畫面文字；設定會保留，修改時不需網路或重新登入，並保留最後額度更新時間／過期時間。
- 前景可選每 15／30／60 秒檢查（預設 15 秒），切回 App 時也會檢查；也可按「立即更新」。連線失敗時採 60／120／240／300 秒退避，避免反覆請求。不提供 Codex 額度變動事件或瞬時背景更新的保證。
- 背景只向 iOS 申請 BGAppRefresh，最早請求時間為約 15 分鐘後。是否執行及執行時間由系統決定，無法保證定時或即時更新；低耗電模式／背景重新整理關閉時可能不會執行。
- 無 APNs 伺服器，因此不能承諾切到其他 App 後持續刷新。超過 3 分鐘的資料在小島顯示 —；開啟 App 可更新。
- 即時動態有系統存續時限，結束後需重新開始。
- BGTask 允許的識別碼隨 bundle ID 生成。側載工具若修改 bundle ID，亦須對應調整 Info.plist 的 BGTaskSchedulerPermittedIdentifiers，否則背景重新整理無法運作；前景更新仍可用。

## 憑證處理

access token 與 refresh token 只保存在該 iPhone 的 Keychain（ThisDeviceOnly），不寫進 GitHub、日誌或一般設定。網路只使用固定的 OpenAI HTTPS 網域，沒有可填入的中介伺服器。

刷新憑證會保留輪替後的 refresh token；同一時間只執行一次憑證更新。過期或不支援的授權會顯示錯誤，不會捏造額度。

JWT 內容只解碼作為 expiry／workspace routing 提示，不把未驗證 claims 當作已驗證身分。實際存取權由 OpenAI HTTPS 伺服器驗證 access token。

「登出」移除手機本機憑證並停止即時動態；不是撤銷所有其他裝置的登入。若要撤銷帳號端存取，請使用 OpenAI 帳號的官方安全性／存取管理設定。

## 編譯

GitHub Actions 使用 macos-15 runner、XcodeGen 與 xcodebuild 建立未簽署 IPA，包含 Live Activity extension。

- `ios/App/DirectOAuth.swift`：裝置碼、token 交換、Keychain、額度 HTTPS 請求。
- `ios/App/CodexIslandApp.swift`：帳號介面、ActivityKit、前景與系統排程的背景更新。
- `ios/Shared/QuotaData.swift`：直接額度 API 解碼與有效範圍驗證。
- `ios/Widget/QuotaWidget.swift`：靈動島、鎖定畫面與資料逾期呈現。
- `tests/QuotaData/main.swift`：解碼、空視窗與錯誤資料測試；Actions 用 Swift 執行後再編譯 App。
- `mac/`：保留 0.1 版橋接程式供參考，0.2 App 完全不使用。

## 來源核對

https://learn.chatgpt.com/docs/auth
https://learn.chatgpt.com/docs/app-server
https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs
https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs
https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs

登入使用公開原始碼中的 Codex public OAuth client ID（不是 client secret）。回應碼／格式取自上述實作，但 OpenAI 仍可能拒絕第三方手機客戶端，請勿將此實驗版宣稱為官方支援的整合。



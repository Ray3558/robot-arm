# Codex Island — iPhone 靈動島額度顯示

第一版原始碼。iPhone 16 Pro 可用；最低 iOS 16.2。
包含 GitHub Actions 未簽署 IPA 編譯、SwiftUI App、Live Activity 擴充套件、Python 額度橋接服務及選配 APNs 更新。

## 目前驗證狀態

- Python 語法、額度轉換、JSON-RPC 初始化／額度讀取的模擬整合測試，以及 HTTP 驗證／示範資料路徑已在 Linux 驗證。
- 此環境沒有 Xcode，尚未實際編譯 Swift、執行 GitHub Actions 或用你的帳號／iPhone 驗證。第一次 Actions 執行會驗證 Apple 編譯器相容性。
- 沒有讀取你的帳號、建立 GitHub repository 或上傳 Apple／OpenAI 憑證。

## 1. 用 GitHub Actions 取得 IPA

1. 建立 GitHub repository，將此資料夾的「內容」放到 repository 根目錄，包含 `.github/workflows/build-ipa.yml`。不要多包一層 CodexIsland。
2. 將程式推送至 `main`；或在 Actions → Build unsigned IPA → Run workflow 手動啟動（workflow 需先存在預設分支）。
3. 完成後到該次執行的 Artifacts 下載 `CodexIsland-unsigned-IPA`，解開取得 `CodexIsland-unsigned.ipa`。
4. 使用你自己的側載／簽名工具重新簽署並安裝。**未簽署 IPA 無法直接點開安裝**。必須同時簽署主 App 與 `PlugIns/QuotaWidget.appex`，不要移除擴充套件。
5. 若簽名工具變更 bundle ID，主 App 與 extension 必須維持正確父子 ID 關係。推播用的 APNS_BUNDLE_ID 也要對應簽名後主 App ID。

編譯不需要 Apple ID、Apple 憑證或 GitHub Secrets。GitHub 的 macOS runner 額度／費用依你的帳號與 repository 設定而定。
這份 workflow 只產出未簽署 IPA，不提供自動簽名或 TestFlight 發布。

iPhone 上若透過網頁上傳檔案看不到 `.github`，可在 GitHub 建立檔案並將路徑輸入 `.github/workflows/build-ipa.yml`，貼上本包 workflow 內容。其他檔案須保留原本資料夾結構。

## 2. 在 Mac 啟動額度橋接服務

需要 Python 3.10+ 與已安裝的 Codex CLI。使用同一個 ChatGPT 帳號：

```sh
codex login
python3 mac/bridge.py --host 0.0.0.0
```

若找不到 codex，可用 `--codex /完整路徑/codex` 指定。程式每 60 秒透過 `codex app-server` 的 `account/rateLimits/read` 讀取真實額度。不建立對話、不執行模型任務，也不呼叫付費推論 API。Codex 登入憑證留在執行服務的電腦。

第一次執行會建立 `mac/.bridge-token`，權限僅限檔案擁有者讀寫。將內容貼到 iPhone App 的「連線金鑰」；這是本工具產生的配對密鑰，不是 OpenAI API key。iPhone 會存到 Keychain。

在 Mac 系統設定找到 Wi-Fi IP；iPhone 與 Mac 使用同一私人網路時，App 網址填 `http://192.168.x.x:8765`，依實際 IP 修改。允許 iPhone 的「本機網路」權限與 Mac 防火牆的 Python 連入。

預設不加 `--host` 時只監聽本機。`--host 0.0.0.0` 才允許其他裝置連入。HTTP 配對金鑰沒有傳輸加密，只適合可信任的家用網路或已加密的私人 VPN。不要把 8765 直接轉發到公網；跨網路請使用自己的 VPN 或帶 HTTPS 的受控反向代理，並讓 App 填對應網址。

只想看介面、還沒登入 Codex 時：

```sh
python3 mac/bridge.py --host 0.0.0.0 --demo
```

此模式在 App 和靈動島都標示「示範」，75% 為固定假資料。正式使用請停止程式，移除 `--demo` 後重開。

## 3. iPhone 使用

填入網址與金鑰 → 關閉「Apple 推播更新」→ 按「開始顯示靈動島」。

- 小島顯示主視窗剩餘百分比；長按可看第二視窗（若有）與主視窗重置時間。
- 視窗長度取自官方回傳值，沒有固定假設 5 小時／一週；「剩餘百分比」也不代表可精確換算的訊息數。
- App 前景每 60 秒讀取，也可按「立即更新」。背景沒有 APNs 時不會持續輪詢；靈動島只保留最後資料，3 分鐘後標示逾期「—」，點開 App 可更新。
- 資料讀取失敗時不會顯示假的 100%。
- iOS 會限制即時動態的存續時間與背景更新頻率；這不是永久常駐的系統狀態列。活動結束後需重新按開始。
- Mac 必須保持開機、服務執行且網路可達。

## 4. 選配：背景自動更新（APNs）

這條路需要 Apple Developer 帳號中可用的 APNs 金鑰與 App ID，以及含正確 `aps-environment` 權限的簽名／描述檔。**一般免費側載簽名不保證可用，GitHub Actions 編譯成功不代表有推播權限。** 本包未簽署編譯不內嵌憑證或可冒用的權限；正式推播的簽名與描述檔由你自己的簽名流程提供。

先準備 APNs `.p8`，在 Mac 本機終端機設定（不要放進 GitHub repo）：

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r mac/requirements.txt
export APNS_TEAM_ID='你的 Apple Team ID'
export APNS_KEY_ID='你的 APNs Key ID'
export APNS_KEY_PATH='/你的私人路徑/AuthKey.p8'
export APNS_BUNDLE_ID='com.example.CodexIsland'
export APNS_ENV='sandbox'
python3 mac/bridge.py --host 0.0.0.0
```

APNS_ENV 依實際描述檔選 sandbox 或 production，不能依 IPA 是 Debug／Release 猜測。簽名後主 App ID 若變更，必須修改 APNS_BUNDLE_ID。金鑰需允許該 App／環境。

iPhone 打開推播開關，先「停止顯示」再「開始顯示」。App 取得 ActivityKit push token 後會 POST 到 `/register`；服務每分鐘取得新資料後以低優先級 APNs 推播。Apple 會依預算與系統狀態調度，不能保證每分鐘顯示。

推播 token 暫存在服務記憶體，服務重開後需重新打開 App；超過 8 小時的登錄會移除。token 輪替時 App 會重新登錄；沒有即時 token 或註冊失敗時，前景更新仍可用。停止活動後 Apple 可能回傳 400／410，服務會移除無效 token。

## 檔案與介面

- `project.yml`：XcodeGen 專案設定；可在 Mac `brew install xcodegen` → `xcodegen generate` → 開啟 `CodexIsland.xcodeproj`。
- `.github/workflows/build-ipa.yml`：macOS runner 編譯、檢查 extension 並打包 IPA。
- `ios/App`：連線設定、Keychain、額度讀取、ActivityKit。
- `ios/Widget`：靈動島及鎖定畫面介面。
- `ios/Shared`：與 APNs JSON 對應的 ContentState。
- `mac/bridge.py`：只讀額度及選配推播，標準庫即可跑前景版本。
- `mac/test_bridge.py`：離線測試，不需帳號或 Apple 憑證。

`GET /quota` 與 `POST /register` 均要求 `Authorization: Bearer <配對金鑰>`。`/quota` 若上游讀取失敗或資料超過 180 秒會回 503，金鑰錯誤回 401。OpenAI 原始認證資訊不會傳送到 iPhone。

## 文件

- https://learn.chatgpt.com/docs/app-server （初始化與 account/rateLimits/read）
- https://developer.apple.com/documentation/activitykit
- https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts

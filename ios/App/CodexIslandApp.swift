import ActivityKit
import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @Published var status = "直接在 iPhone 登入 ChatGPT，無需 Mac。"
    @Published var connected = false
    @Published var device: DeviceAuthorization?
    @Published var usage: DirectUsage?
    @Published var updatedAt: Date?
    @Published var busy = false
    @Published var signingIn = false
    private var loginTask: Task<Void, Never>?
    private var sessionID = UUID()
    @Published private(set) var textColorHex = QuotaAppearance.normalized(UserDefaults.standard.string(forKey: "quotaTextColor"))
    @Published var refreshInterval: Int = {
        let saved = UserDefaults.standard.integer(forKey: "refreshIntervalSeconds")
        return [15, 30, 60].contains(saved) ? saved : 15
    }() {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshIntervalSeconds") }
    }
    private var consecutiveFailures = 0
    private var retryNotBefore = Date.distantPast
    var nextPollDelay: Int {
        max(refreshInterval, Int(ceil(retryNotBefore.timeIntervalSinceNow)))
    }
    private var appearanceTask: Task<Void, Never>?
    var textColor: Color { QuotaAppearance.color(textColorHex) }

    func setTextColor(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let hex = String(format: "#%02X%02X%02X", Int((min(1, max(0, r)) * 255).rounded()),
                         Int((min(1, max(0, g)) * 255).rounded()), Int((min(1, max(0, b)) * 255).rounded()))
        setTextColorHex(hex)
    }

    func setTextColorHex(_ hex: String) {
        textColorHex = QuotaAppearance.normalized(hex)
        UserDefaults.standard.set(textColorHex, forKey: "quotaTextColor")
        appearanceTask?.cancel()
        appearanceTask = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            for activity in Activity<QuotaAttributes>.activities {
                guard !Task.isCancelled else { return }
                var state = activity.content.state
                state.textColorHex = textColorHex
                // Preserve the quota timestamp and stale date; changing color is not a quota refresh.
                await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
            }
        }
    }
    init() { Task { connected = await DirectOAuth.shared.connected() } }
    func startLogin() {
        guard !signingIn else { return }
        signingIn = true
        loginTask = Task {
            defer { signingIn = false; device = nil }
            do {
                let authorization = try await DirectOAuth.shared.begin()
                try Task.checkCancellation()
                device = authorization
                status = "複製登入碼，在官方頁面授權後回到此 App。"
                while Date() < authorization.expiresAt {
                    try Task.checkCancellation()
                    if try await DirectOAuth.shared.poll(authorization) {
                        connected = true; consecutiveFailures = 0; retryNotBefore = .distantPast; status = "登入成功。"
                        await refresh(start: false)
                        return
                    }
                    try await Task.sleep(for: .seconds(authorization.interval))
                }
                status = "登入碼已過期，請重新登入。"
            } catch is CancellationError { status = "已取消登入。" }
            catch { status = error.localizedDescription }
        }
    }
    func cancelLogin() { loginTask?.cancel() }
    func refresh(start: Bool) async {
        guard !busy else { return }
        guard Date() >= retryNotBefore else {
            status = "連線暫時冷卻中，約 \(max(1, Int(ceil(retryNotBefore.timeIntervalSinceNow)))) 秒後自動重試。"
            return
        }
        busy = true
        let stamp = sessionID
        defer { busy = false }
        do {
            let result = try await DirectOAuth.shared.usage()
            try Task.checkCancellation()
            guard stamp == sessionID else { return }
            consecutiveFailures = 0; retryNotBefore = .distantPast
            usage = result; updatedAt = Date(); connected = true
            guard let primary = result.rateLimit?.primaryWindow else { return }
            let state = QuotaAttributes.ContentState(remaining: primary.remaining,
                secondaryRemaining: result.rateLimit?.secondaryWindow?.remaining,
                resetAt: primary.resetAt, updatedAt: Date().timeIntervalSince1970, textColorHex: textColorHex)
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
            var activities = Activity<QuotaAttributes>.activities
            if start && activities.isEmpty {
                guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw QuotaError.message("請在 iPhone 設定允許即時動態。") }
                activities = [try Activity.request(attributes: QuotaAttributes(label: "Codex"), content: content, pushType: nil)]
            }
            for activity in activities { await activity.update(content) }
            status = "已直接從 Codex 更新額度。"
        } catch is CancellationError { }
        catch {
            consecutiveFailures = min(consecutiveFailures + 1, 4)
            let delay = min(300, 30 * Int(pow(2.0, Double(consecutiveFailures))))
            retryNotBefore = Date().addingTimeInterval(Double(delay))
            status = error.localizedDescription + " \(delay) 秒後自動重試。"
        }
    }
    func stop() async {
        for a in Activity<QuotaAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        status = "已停止靈動島。"
    }
    func logout() async {
        sessionID = UUID(); loginTask?.cancel()
        await DirectOAuth.shared.signOut()
        await stop()
        consecutiveFailures = 0; retryNotBefore = .distantPast
        connected = false; usage = nil; updatedAt = nil; status = "已從這台 iPhone 移除登入資料。"
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var refreshID: String { (Bundle.main.bundleIdentifier ?? "com.example.CodexIsland") + ".refresh" }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                Self.schedule()
                await Model.shared.refresh(start: false)
                refresh.setTaskCompleted(success: !Task.isCancelled)
            }
            refresh.expirationHandler = { work.cancel() }
        }
        return true
    }
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct CodexIslandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("ChatGPT 帳號") {
                        Text(model.connected ? "已登入 · OAuth" : "尚未登入")
                        if !model.signingIn {
                            Button(model.connected ? "重新登入 ChatGPT" : "登入 ChatGPT") { model.startLogin() }
                        }
                        if let device = model.device {
                            Text(device.code).font(.title.monospaced().bold()).textSelection(.enabled)
                            Button("複製登入碼") { UIPasteboard.general.string = device.code }
                            Link("開啟官方授權頁面", destination: URL(string: "https://auth.openai.com/codex/device")!)
                            Text("在瀏覽器完成授權後切回此 App，會繼續完成登入。只輸入這台手機剛產生的登入碼。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.signingIn { Button("取消登入", role: .cancel) { model.cancelLogin() } }
                        if model.connected { Button("登出並清除手機憑證", role: .destructive) { Task { await model.logout() } } }
                    }
                    Section("字體顏色") {
                        ColorPicker("自訂顏色", selection: Binding(
                            get: { model.textColor },
                            set: { model.setTextColor($0) }
                        ), supportsOpacity: false)
                        HStack {
                            Text("預覽").foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("Codex  75%").font(.headline.monospacedDigit()).foregroundStyle(model.textColor)
                        }
                        .padding().background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                        Text(model.textColorHex).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("恢復預設薄荷綠") { model.setTextColorHex(QuotaAppearance.defaultHex) }
                        Text("套用到靈動島與鎖定畫面文字，會自動儲存並更新現有即時動態。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Codex 額度") {
                        if let p = model.usage?.rateLimit?.primaryWindow {
                            Text("主視窗剩餘 \(p.remaining)%").font(.title2.bold()).foregroundStyle(model.textColor)
                            ProgressView(value: Double(p.remaining), total: 100).tint(model.textColor)
                            Text("重置：\(Date(timeIntervalSince1970: p.resetAt).formatted())").font(.caption)
                        }
                        if let s = model.usage?.rateLimit?.secondaryWindow { Text("第二視窗剩餘 \(s.remaining)%") }
                        if let date = model.updatedAt { Text("最後更新：\(date.formatted())").font(.caption) }
                        Text(model.status).font(.callout)
                    }
                    Section {
                        Button("開始顯示靈動島") { Task { await model.refresh(start: true) } }.disabled(!model.connected || model.busy)
                        Button("立即更新") { Task { await model.refresh(start: false) } }.disabled(!model.connected || model.busy)
                        Button("停止顯示", role: .destructive) { Task { await model.stop() } }
                        Link("查看官方用量頁面", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                    }
                    Section("自動更新") {
                        Picker("App 開啟時檢查間隔", selection: $model.refreshInterval) {
                            Text("15 秒").tag(15)
                            Text("30 秒").tag(30)
                            Text("60 秒").tag(60)
                        }
                        Text("每次檢查後自動更新額度；較短的間隔會增加網路與電池用量。連線失敗時會延後重試。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("更新方式") {
                        Text("App 在前景時依選定間隔檢查並更新。切回 App 時也會檢查。背景由 iOS 決定是否喚醒，無法保證額度變動時立即更新；資料超過 3 分鐘，小島顯示 —。點小島開啟 App 即可刷新。")
                        Text("此版為個人用實驗整合，使用 Codex 裝置碼登入；服務介面變更或帳號限制可能導致登入／讀取失敗。憑證只存於這台 iPhone 的 Keychain。")
                    }.font(.caption).foregroundStyle(.secondary)
                }.navigationTitle("Codex Island")
                .task(id: "\(phase)-\(model.refreshInterval)") {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        if model.connected { await model.refresh(start: false) }
                        do { try await Task.sleep(for: .seconds(model.nextPollDelay)) } catch { return }
                    }
                }
                .onChange(of: phase) { state in
                    if state == .background && model.connected { AppDelegate.schedule() }
                }
            }
        }
    }
}


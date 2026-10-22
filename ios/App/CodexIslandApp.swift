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
                        connected = true; status = "登入成功。"
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
        guard !busy else { return }; busy = true
        let stamp = sessionID
        defer { busy = false }
        do {
            let result = try await DirectOAuth.shared.usage()
            try Task.checkCancellation()
            guard stamp == sessionID else { return }
            usage = result; updatedAt = Date(); connected = true
            guard let primary = result.rateLimit?.primaryWindow else { return }
            let state = QuotaAttributes.ContentState(remaining: primary.remaining,
                secondaryRemaining: result.rateLimit?.secondaryWindow?.remaining,
                resetAt: primary.resetAt, updatedAt: Date().timeIntervalSince1970)
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
            var activities = Activity<QuotaAttributes>.activities
            if start && activities.isEmpty {
                guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw QuotaError.message("請在 iPhone 設定允許即時動態。") }
                activities = [try Activity.request(attributes: QuotaAttributes(label: "Codex"), content: content, pushType: nil)]
            }
            for activity in activities { await activity.update(content) }
            status = "已直接從 Codex 更新額度。"
        } catch is CancellationError { }
        catch { status = error.localizedDescription }
    }
    func stop() async {
        for a in Activity<QuotaAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        status = "已停止靈動島。"
    }
    func logout() async {
        sessionID = UUID(); loginTask?.cancel()
        await DirectOAuth.shared.signOut()
        await stop()
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
                    Section("Codex 額度") {
                        if let p = model.usage?.rateLimit?.primaryWindow {
                            Text("主視窗剩餘 \(p.remaining)%").font(.title2.bold())
                            ProgressView(value: Double(p.remaining), total: 100).tint(.mint)
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
                    Section("更新方式") {
                        Text("前景每 60 秒更新。背景由 iOS 決定是否喚醒，無法保證即時更新；資料超過 3 分鐘，小島顯示 —。點小島開啟 App 即可刷新。")
                        Text("此版為個人用實驗整合，使用 Codex 裝置碼登入；服務介面變更或帳號限制可能導致登入／讀取失敗。憑證只存於這台 iPhone 的 Keychain。")
                    }.font(.caption).foregroundStyle(.secondary)
                }.navigationTitle("Codex Island")
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        if model.connected { await model.refresh(start: false) }
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    }
                }
                .onChange(of: phase) { state in
                    if state == .background && model.connected { AppDelegate.schedule() }
                }
            }
        }
    }
}

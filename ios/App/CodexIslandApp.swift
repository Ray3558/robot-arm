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
    private var islandEnabled = UserDefaults.standard.bool(forKey: "islandEnabled")
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
    init() {
        // Migrate existing activities when upgrading from versions without this preference.
        if !Activity<QuotaAttributes>.activities.isEmpty { setIslandEnabled(true) }
        Task { connected = await DirectOAuth.shared.connected() }
    }
    private func setIslandEnabled(_ enabled: Bool) {
        islandEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "islandEnabled")
    }
    private static let transientLoginErrors: Set<URLError.Code> = [.cancelled, .networkConnectionLost,
        .notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed]
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
                    do {
                        if try await DirectOAuth.shared.poll(authorization) {
                            connected = true; consecutiveFailures = 0; retryNotBefore = .distantPast; status = "登入成功。"
                            await refresh(start: false)
                            return
                        }
                    } catch let error as URLError where !Task.isCancelled && Self.transientLoginErrors.contains(error.code) {
                        // iOS drops in-flight requests (URLError.cancelled) while the user is in Safari
                        // authorizing the code; keep polling instead of abandoning the login.
                    }
                    try await Task.sleep(for: .seconds(authorization.interval))
                }
                status = "登入碼已過期，請重新登入。"
            } catch is CancellationError { status = "已取消登入。" }
            catch { status = Task.isCancelled ? "已取消登入。" : error.localizedDescription }
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
            let secondary = result.rateLimit?.secondaryWindow
            let state = QuotaAttributes.ContentState(remaining: primary.remaining,
                secondaryRemaining: secondary?.remaining,
                resetAt: primary.resetAt, updatedAt: Date().timeIntervalSince1970, textColorHex: textColorHex,
                primaryWindowSeconds: primary.limitWindowSeconds,
                secondaryWindowSeconds: secondary?.limitWindowSeconds, secondaryResetAt: secondary?.resetAt)
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
            var activities = Activity<QuotaAttributes>.activities.filter {
                $0.activityState == .active || $0.activityState == .stale
            }
            // Only create activities while the app is in the foreground.
            // An explicit stop clears the saved intent, so polling cannot restart it.
            if (start || islandEnabled) && activities.isEmpty && UIApplication.shared.applicationState == .active {
                guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw QuotaError.message("請在 iPhone 設定允許即時動態。") }
                activities = [try Activity.request(attributes: QuotaAttributes(label: "Codex"), content: content, pushType: nil)]
            }
            if start && !activities.isEmpty { setIslandEnabled(true) }
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
        setIslandEnabled(false)
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
            DashboardView(model: model)
                .preferredColorScheme(.dark)
                .tint(model.textColor)
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


import ActivityKit
import BackgroundTasks
import SwiftUI
import UIKit

enum IslandProvider: String, CaseIterable {
    case codex, claude
    var name: String { self == .codex ? "Codex" : "Claude" }
    /// Claude is polled every 10 minutes, so its data counts as stale later than Codex's.
    var staleAfter: TimeInterval { self == .codex ? 180 : 900 }
}
struct IslandSnapshot {
    let provider: IslandProvider
    let limits: UsageLimits
    let updatedAt: Date
}

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
    @Published var claudeConnected = false
    @Published var claudeUsage: UsageLimits?
    @Published var claudeUpdatedAt: Date?
    @Published var claudeStatus = "登入 Claude 以顯示 Claude 用量。"
    @Published var claudeLogin: ClaudeLoginRequest?
    @Published var claudeSigningIn = false
    @Published var islandProvider: IslandProvider = IslandProvider(rawValue: UserDefaults.standard.string(forKey: "islandProvider") ?? "") ?? .codex {
        didSet {
            UserDefaults.standard.set(islandProvider.rawValue, forKey: "islandProvider")
            Task { try? await updateIsland(start: false) }
        }
    }
    private var claudeSession = UUID()
    private var claudeFailures = 0
    private var claudeNotBefore = Date.distantPast
    private var claudeLastAttempt = Date.distantPast
    private static let claudeInterval: TimeInterval = 600
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
        Task {
            connected = await DirectOAuth.shared.connected()
            claudeConnected = await ClaudeOAuth.shared.connected()
        }
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
    var hasAccount: Bool { connected || claudeConnected }
    var islandSnapshot: IslandSnapshot? {
        switch islandProvider {
        case .codex:
            guard let limits = usage?.rateLimit, let updatedAt else { return nil }
            return IslandSnapshot(provider: .codex, limits: limits, updatedAt: updatedAt)
        case .claude:
            guard let limits = claudeUsage, let claudeUpdatedAt else { return nil }
            return IslandSnapshot(provider: .claude, limits: limits, updatedAt: claudeUpdatedAt)
        }
    }
    /// `manual` lets an explicit refresh skip Claude's 10-minute cadence (never a failure cooldown).
    func refresh(start: Bool, manual: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if connected { await refreshCodex() }
        if claudeConnected { await refreshClaude(manual: manual || start) }
        do { try await updateIsland(start: start) }
        catch { status = error.localizedDescription }
    }
    private func refreshCodex() async {
        guard Date() >= retryNotBefore else {
            status = "連線暫時冷卻中，約 \(max(1, Int(ceil(retryNotBefore.timeIntervalSinceNow)))) 秒後自動重試。"
            return
        }
        let stamp = sessionID
        do {
            let result = try await DirectOAuth.shared.usage()
            try Task.checkCancellation()
            guard stamp == sessionID else { return }
            consecutiveFailures = 0; retryNotBefore = .distantPast
            usage = result; updatedAt = Date(); connected = true
            status = "已直接從 Codex 更新額度。"
        } catch is CancellationError { }
        catch {
            consecutiveFailures = min(consecutiveFailures + 1, 4)
            let delay = min(300, 30 * Int(pow(2.0, Double(consecutiveFailures))))
            retryNotBefore = Date().addingTimeInterval(Double(delay))
            status = error.localizedDescription + " \(delay) 秒後自動重試。"
        }
    }
    private func refreshClaude(manual: Bool) async {
        let now = Date()
        // The usage endpoint rate-limits hard (429s can last hours), so poll sparingly.
        let allowed = now >= claudeNotBefore
            || (manual && claudeFailures == 0 && now.timeIntervalSince(claudeLastAttempt) >= 120)
        guard allowed else { return }
        claudeLastAttempt = now
        let stamp = claudeSession
        do {
            let result = try await ClaudeOAuth.shared.usage()
            guard stamp == claudeSession else { return }
            claudeUsage = result; claudeUpdatedAt = Date(); claudeFailures = 0
            claudeNotBefore = Date().addingTimeInterval(Self.claudeInterval)
            claudeStatus = "已從 Claude 更新用量，約每 10 分鐘更新一次。"
        } catch is CancellationError { }
        catch {
            guard stamp == claudeSession else { return }
            claudeFailures = min(claudeFailures + 1, 4)
            let limited = error is ClaudeRateLimited
            let delay = limited ? 1800 : min(1800, 300 * Int(pow(2.0, Double(claudeFailures - 1))))
            claudeNotBefore = Date().addingTimeInterval(Double(delay))
            claudeStatus = (limited ? "Claude 用量介面暫時限流。" : error.localizedDescription) + " \(delay / 60) 分鐘後自動重試。"
        }
    }
    private func updateIsland(start: Bool) async throws {
        guard let snapshot = islandSnapshot, let primary = snapshot.limits.primaryWindow else {
            if start { throw QuotaError.message("\(islandProvider.name) 尚無用量資料，請先登入或在設定切換靈動島來源。") }
            return
        }
        let secondary = snapshot.limits.secondaryWindow
        let state = QuotaAttributes.ContentState(remaining: primary.remaining,
            secondaryRemaining: secondary?.remaining,
            resetAt: primary.resetAt > 0 ? primary.resetAt : nil,
            updatedAt: snapshot.updatedAt.timeIntervalSince1970, textColorHex: textColorHex,
            primaryWindowSeconds: primary.limitWindowSeconds,
            secondaryWindowSeconds: secondary?.limitWindowSeconds,
            secondaryResetAt: secondary.flatMap { $0.resetAt > 0 ? $0.resetAt : nil },
            providerName: snapshot.provider.name)
        let content = ActivityContent(state: state, staleDate: snapshot.updatedAt.addingTimeInterval(snapshot.provider.staleAfter))
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
    }
    func startClaudeLogin() {
        Task {
            claudeLogin = await ClaudeOAuth.shared.makeLoginRequest()
            claudeStatus = "在官方頁面授權後，把頁面顯示的代碼貼回這裡。"
        }
    }
    func cancelClaudeLogin() { claudeLogin = nil; claudeStatus = "已取消 Claude 登入。" }
    func finishClaudeLogin(_ pasted: String) {
        guard let request = claudeLogin, !claudeSigningIn else { return }
        claudeSigningIn = true
        Task {
            defer { claudeSigningIn = false }
            do {
                try await ClaudeOAuth.shared.finishLogin(request, pasted: pasted)
                claudeLogin = nil; claudeConnected = true
                claudeFailures = 0; claudeNotBefore = .distantPast; claudeStatus = "Claude 登入成功。"
                await refresh(start: false)
            } catch is CancellationError { }
            catch { claudeStatus = error.localizedDescription }
        }
    }
    func claudeLogout() async {
        claudeSession = UUID()
        await ClaudeOAuth.shared.signOut()
        if islandProvider == .claude { await stop() }
        claudeConnected = false; claudeUsage = nil; claudeUpdatedAt = nil; claudeLogin = nil
        claudeFailures = 0; claudeNotBefore = .distantPast
        claudeStatus = "已從這台 iPhone 移除 Claude 登入資料。"
    }
    func stop() async {
        setIslandEnabled(false)
        for a in Activity<QuotaAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        status = "已停止靈動島。"
    }
    func logout() async {
        sessionID = UUID(); loginTask?.cancel()
        await DirectOAuth.shared.signOut()
        if islandProvider == .codex { await stop() }
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
                        if model.hasAccount { await model.refresh(start: false) }
                        do { try await Task.sleep(for: .seconds(model.nextPollDelay)) } catch { return }
                    }
                }
                .onChange(of: phase) { state in
                    if state == .background && model.hasAccount { AppDelegate.schedule() }
                }
        }
    }
}


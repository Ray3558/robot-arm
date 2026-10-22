import ActivityKit
import Security
import SwiftUI

struct QuotaWindow: Decodable { let remaining: Int; let minutes: Int; let resetAt: Double? }
struct Snapshot: Decodable {
    let primary: QuotaWindow
    let secondary: QuotaWindow?
    let updatedAt: Double
    let demo: Bool
    let pushEnabled: Bool
    var state: QuotaAttributes.ContentState {
        .init(remaining: primary.remaining, secondaryRemaining: secondary?.remaining,
              resetAt: primary.resetAt, updatedAt: updatedAt)
    }
}

enum TokenStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "CodexIsland", kSecAttrAccount as String: "bridge"]
    static func read() -> String {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "Keychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法儲存連線金鑰"])
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var token = TokenStore.read()
    @Published var status = "填入連線資料後，按開始顯示。"
    @Published var snapshot: Snapshot?
    @Published var busy = false
    private var watchers: [String: Task<Void, Never>] = [:]
    private func request(_ base: String, path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: base), ["http", "https"].contains(url.scheme ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw NSError(domain: "URL", code: 1, userInfo: [NSLocalizedDescriptionKey: "請輸入完整 http:// 或 https:// 連線網址"])
        }
        var req = URLRequest(url: url.appendingPathComponent(path))
        req.timeoutInterval = 15; req.httpMethod = method; req.httpBody = body
        req.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Bridge", code: code, userInfo: [NSLocalizedDescriptionKey:
                code == 401 ? "連線金鑰不正確" : "讀取失敗（\(code)），請檢查 Mac 程式與 Codex 登入"])
        }
        return data
    }
    func refresh(base: String, start: Bool, push: Bool) async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        do {
            try TokenStore.save(token)
            let data = try await send(request(base, path: "quota"))
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            guard Date().timeIntervalSince1970 - snap.updatedAt < 180 else {
                throw NSError(domain: "Stale", code: 1, userInfo: [NSLocalizedDescriptionKey: "資料已過期"])
            }
            snapshot = snap
            if start && !ActivityAuthorizationInfo().areActivitiesEnabled {
                throw NSError(domain: "Activity", code: 1, userInfo: [NSLocalizedDescriptionKey: "請在系統設定允許即時動態"])
            }
            var activities = Activity<QuotaAttributes>.activities
            let label = snap.demo ? "Codex 示範" : "Codex"
            for old in activities where old.attributes.label != label {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            activities = activities.filter { $0.attributes.label == label }
            let content = ActivityContent(state: snap.state, staleDate: Date(timeIntervalSince1970: snap.updatedAt + 180))
            if start && activities.isEmpty {
                let activity = try Activity.request(attributes: QuotaAttributes(label: label), content: content,
                                                    pushType: push ? .token : nil)
                activities = [activity]
            }
            for activity in activities {
                await activity.update(content)
                if push { watch(activity, base: base) }
            }
            status = snap.demo ? "示範資料，非真實額度。" : "額度已更新。"
            if !push { status += " 背景自動更新未啟用。" }
            else if !snap.pushEnabled { status += " Mac 尚未設定 Apple 推播金鑰。" }
            else { status += " 等待推播註冊；傳送受系統調度。" }
        } catch { status = error.localizedDescription }
    }
    private func watch(_ activity: Activity<QuotaAttributes>, base: String) {
        if let bytes = activity.pushToken {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            Task { [weak self] in
                guard let self else { return }
                do {
                    let body = try JSONSerialization.data(withJSONObject: ["token": hex])
                    _ = try await self.send(self.request(base, path: "register", method: "POST", body: body))
                } catch { self.status = "推播重新註冊失敗：\(error.localizedDescription)" }
            }
        }
        guard watchers[activity.id] == nil else { return }
        watchers[activity.id] = Task { [weak self] in
            for await bytes in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self else { return }
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                // Retry transient failures while the app is active; reopen to retry after suspension.
                for attempt in 0..<3 {
                    do {
                        let body = try JSONSerialization.data(withJSONObject: ["token": hex])
                        _ = try await self.send(self.request(base, path: "register", method: "POST", body: body))
                        self.status = "推播 Token 已註冊；仍需有效的 Apple 簽名與伺服器金鑰。"
                        break
                    } catch {
                        self.status = "推播註冊失敗：\(error.localizedDescription)。重新開啟 App 可重試。"
                        if attempt < 2 { try? await Task.sleep(for: .seconds(5)) }
                    }
                }
            }
        }
    }
    func stop() async {
        for task in watchers.values { task.cancel() }; watchers.removeAll()
        for activity in Activity<QuotaAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        status = "已停止靈動島顯示。"
    }
}

@main
struct CodexIslandApp: App {
    @StateObject private var model = Model()
    @AppStorage("bridgeURL") private var base = "http://"
    @AppStorage("pushEnabled") private var push = false
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("連線設定") {
                        TextField("Mac / 私人網路網址", text: $base).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("連線金鑰", text: $model.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Apple 推播更新（需憑證）", isOn: $push)
                        Text("切換推播模式後，先停止再開始。HTTP 僅供可信任的私人網路使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Codex 額度") {
                        if let s = model.snapshot {
                            Text(s.demo ? "示範資料" : "真實額度").foregroundStyle(s.demo ? .orange : .secondary)
                            Text("主視窗剩餘 \(s.primary.remaining)%").font(.title2.bold())
                            if let secondary = s.secondary { Text("第二視窗剩餘 \(secondary.remaining)%") }
                            Text("更新：\(Date(timeIntervalSince1970: s.updatedAt).formatted())").font(.caption)
                        }
                        Text(model.status).font(.callout)
                    }
                    Section {
                        Button("開始顯示靈動島") { Task { await model.refresh(base: base, start: true, push: push) } }.disabled(model.busy)
                        Button("立即更新") { Task { await model.refresh(base: base, start: false, push: push) } }.disabled(model.busy)
                        Button("停止顯示", role: .destructive) { Task { await model.stop() } }
                    }
                    Section {
                        Text("App 在前景時每 60 秒更新。背景更新需 APNs；沒有推播時，靈動島會保留上次資料，逾期標示 —。即時動態有系統時限，需要定期重新開始。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.navigationTitle("Codex Island")
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        if !Activity<QuotaAttributes>.activities.isEmpty {
                            await model.refresh(base: base, start: false, push: push)
                        }
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    }
                }
            }
        }
    }
}

import Foundation
import Security

struct OAuthCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double
    var accountID: String?
}

struct CredentialStore {
    static let codex = CredentialStore(account: "session")
    static let claude = CredentialStore(account: "claude-session")
    let account: String
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "CodexIsland.DirectOAuth", kSecAttrAccount as String: account] }
    func read() -> OAuthCredentials? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }
    func save(_ credentials: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw QuotaError.message("無法安全儲存登入資料。") }
        } else if result != errSecSuccess { throw QuotaError.message("無法更新安全儲存的登入資料。") }
    }
    func clear() { SecItemDelete(query as CFDictionary) }
}

struct DeviceAuthorization {
    let id: String
    let code: String
    let interval: Double
    let expiresAt: Date
}
struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
}

// Independent Swift implementation of OpenAI Codex's public device-code flow.
// These Codex endpoints are not a stable third-party iOS API contract.
actor DirectOAuth {
    static let shared = DirectOAuth()
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private var credentials = CredentialStore.codex.read()
    private var renewal: Task<OAuthCredentials, Error>?
    private var generation = UUID()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCache = nil; c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()
    func connected() -> Bool { credentials != nil }
    private func request(_ url: String, json: [String: String]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: json)
        return r
    }
    private func execute(_ r: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: r)
        guard let response = response as? HTTPURLResponse else { throw QuotaError.message("伺服器未回應。") }
        return (data, response.statusCode)
    }
    func begin() async throws -> DeviceAuthorization {
        let (data, code) = try await execute(request("https://auth.openai.com/api/accounts/deviceauth/usercode", json: ["client_id": Self.clientID]))
        guard code == 200 else {
            throw QuotaError.message("無法取得登入碼（HTTP \(code)）。請確認 ChatGPT 安全性設定允許 Codex 裝置碼登入；此手機整合也可能不被伺服器支援。")
        }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["device_auth_id"] as? String,
              let user = (o["user_code"] ?? o["usercode"]) as? String, !id.isEmpty, !user.isEmpty else {
            throw QuotaError.message("登入碼回應格式已變更。")
        }
        let interval = Double(String(describing: o["interval"] ?? "5")) ?? 5
        return DeviceAuthorization(id: id, code: user, interval: max(5, min(60, interval)), expiresAt: Date().addingTimeInterval(900))
    }
    func poll(_ device: DeviceAuthorization) async throws -> Bool {
        guard Date() < device.expiresAt else { throw QuotaError.message("登入碼已過期，請重新開始。") }
        let stamp = generation
        let (data, code) = try await execute(request("https://auth.openai.com/api/accounts/deviceauth/token", json: ["device_auth_id": device.id, "user_code": device.code]))
        if code == 403 || code == 404 { return false }
        guard code == 200 else { throw QuotaError.message("登入授權失敗（HTTP \(code)），請重新取得登入碼。") }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authCode = o["authorization_code"] as? String,
              let verifier = o["code_verifier"] as? String else { throw QuotaError.message("登入授權回應格式已變更。") }
        let t = try await exchange(["grant_type": "authorization_code", "client_id": Self.clientID,
            "code": authCode, "code_verifier": verifier, "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
        try Task.checkCancellation()
        guard stamp == generation else { throw CancellationError() }
        let c = makeCredentials(t, previous: nil)
        try CredentialStore.codex.save(c); credentials = c
        return true
    }
    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var r = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        r.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)
        let (data, code) = try await execute(r)
        guard code == 200 else { throw QuotaError.message("登入憑證交換／更新失敗（HTTP \(code)），請重新登入。") }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
    private func makeCredentials(_ t: TokenResponse, previous: OAuthCredentials?) -> OAuthCredentials {
        // Decode claims only as routing/expiry hints, never as verified identity.
        let claims = Self.claims(t.access_token)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return OAuthCredentials(accessToken: t.access_token, refreshToken: t.refresh_token ?? previous?.refreshToken ?? "",
            expiresAt: (claims["exp"] as? Double) ?? Date().timeIntervalSince1970 + (t.expires_in ?? 1800),
            accountID: auth?["chatgpt_account_id"] as? String ?? previous?.accountID)
    }
    private static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }
    private func validCredentials(force: Bool = false) async throws -> OAuthCredentials {
        guard let old = credentials else { throw QuotaError.message("請先登入 ChatGPT。") }
        if !force && old.expiresAt > Date().timeIntervalSince1970 + 90 { return old }
        if let renewal { return try await renewal.value }
        guard !old.refreshToken.isEmpty else { throw QuotaError.message("登入已過期，請重新登入。") }
        let stamp = generation
        let task = Task { try await self.exchange(["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": old.refreshToken]) }
        // Keep only one refresh-token exchange in flight (refresh tokens can rotate).
        let mapped = Task { let response = try await task.value; return self.makeCredentials(response, previous: old) }
        renewal = mapped
        defer { renewal = nil }
        let c = try await mapped.value
        guard stamp == generation else { throw CancellationError() }
        try CredentialStore.codex.save(c); credentials = c
        return c
    }
    func usage() async throws -> DirectUsage {
        for attempt in 0..<2 {
            let c = try await validCredentials(force: attempt == 1)
            var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            r.setValue("Bearer " + c.accessToken, forHTTPHeaderField: "Authorization")
            if let account = c.accountID { r.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, code) = try await execute(r)
            if code == 401 && attempt == 0 { continue }
            guard code == 200 else { throw QuotaError.message("讀取額度失敗（HTTP \(code)）。此介面可能不支援第三方手機程式，請稍後重試或重新登入。") }
            return try JSONDecoder().decode(DirectUsage.self, from: data).validated()
        }
        throw QuotaError.message("登入失效，請重新登入。")
    }
    func signOut() {
        generation = UUID(); renewal?.cancel(); renewal = nil
        credentials = nil; CredentialStore.codex.clear()
    }
}

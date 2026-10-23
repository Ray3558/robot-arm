import CryptoKit
import Foundation
import Security

struct ClaudeLoginRequest {
    let url: URL
    let verifier: String
    let state: String
}
struct ClaudeRateLimited: Error {}

// Mirrors Claude Code's subscription OAuth (PKCE, code pasted back from the callback page) and the
// undocumented /api/oauth/usage endpoint. Neither is a supported third-party API, and the usage
// endpoint rate-limits aggressively, so callers must poll sparingly.
actor ClaudeOAuth {
    static let shared = ClaudeOAuth()
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    private var credentials = CredentialStore.claude.read()
    private var renewal: Task<OAuthCredentials, Error>?
    private var generation = UUID()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCache = nil; c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()
    func connected() -> Bool { credentials != nil }

    func makeLoginRequest() -> ClaudeLoginRequest {
        let verifier = Self.randomToken(), state = Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "user:profile user:inference"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return ClaudeLoginRequest(url: c.url!, verifier: verifier, state: state)
    }
    func finishLogin(_ request: ClaudeLoginRequest, pasted: String) async throws {
        let (code, state) = try Self.parse(pasted)
        guard state == nil || state == request.state else { throw QuotaError.message("這組代碼不屬於這次登入，請重新開始。") }
        let stamp = generation
        let t = try await token(["grant_type": "authorization_code", "code": code, "state": request.state,
            "client_id": Self.clientID, "redirect_uri": Self.redirectURI, "code_verifier": request.verifier])
        guard stamp == generation else { throw CancellationError() }
        let c = makeCredentials(t, previous: nil)
        try CredentialStore.claude.save(c); credentials = c
    }
    /// Accepts the callback page's `code#state`, a bare code, or the full callback URL.
    static func parse(_ text: String) throws -> (code: String, state: String?) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http"), let c = URLComponents(string: s),
           let code = c.queryItems?.first(where: { $0.name == "code" })?.value {
            return (code, c.queryItems?.first(where: { $0.name == "state" })?.value ?? c.fragment)
        }
        let parts = s.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw QuotaError.message("請貼上授權頁顯示的代碼。") }
        return (code, parts.count > 1 ? parts[1] : nil)
    }
    private func token(_ fields: [String: String]) async throws -> TokenResponse {
        var r = URLRequest(url: URL(string: Self.tokenURL)!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw QuotaError.message("Claude 登入憑證交換／更新失敗（HTTP \(code)），請重新登入。") }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
    private func makeCredentials(_ t: TokenResponse, previous: OAuthCredentials?) -> OAuthCredentials {
        OAuthCredentials(accessToken: t.access_token, refreshToken: t.refresh_token ?? previous?.refreshToken ?? "",
            expiresAt: Date().timeIntervalSince1970 + (t.expires_in ?? 3600), accountID: nil)
    }
    private func validCredentials(force: Bool = false) async throws -> OAuthCredentials {
        guard let old = credentials else { throw QuotaError.message("請先登入 Claude。") }
        if !force && old.expiresAt > Date().timeIntervalSince1970 + 90 { return old }
        if let renewal { return try await renewal.value }
        guard !old.refreshToken.isEmpty else { throw QuotaError.message("Claude 登入已過期，請重新登入。") }
        let stamp = generation
        // Refresh tokens are single-use, so keep only one exchange in flight and store the rotated one.
        let task = Task { try await self.token(["grant_type": "refresh_token", "refresh_token": old.refreshToken, "client_id": Self.clientID]) }
        let mapped = Task { let response = try await task.value; return self.makeCredentials(response, previous: old) }
        renewal = mapped
        defer { renewal = nil }
        let c = try await mapped.value
        guard stamp == generation else { throw CancellationError() }
        try CredentialStore.claude.save(c); credentials = c
        return c
    }
    func usage() async throws -> UsageLimits {
        for attempt in 0..<2 {
            let c = try await validCredentials(force: attempt == 1)
            var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            r.setValue("Bearer " + c.accessToken, forHTTPHeaderField: "Authorization")
            r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { continue }
            if code == 429 { throw ClaudeRateLimited() }
            guard code == 200 else { throw QuotaError.message("讀取 Claude 用量失敗（HTTP \(code)）。此介面非公開，可能已變更。") }
            return try JSONDecoder().decode(ClaudeUsage.self, from: data).limits()
        }
        throw QuotaError.message("Claude 登入失效，請重新登入。")
    }
    func signOut() {
        generation = UUID(); renewal?.cancel(); renewal = nil
        credentials = nil; CredentialStore.claude.clear()
    }
    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

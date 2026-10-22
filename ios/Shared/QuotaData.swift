import Foundation

struct UsageWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAt: Double
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent", limitWindowSeconds = "limit_window_seconds", resetAt = "reset_at"
    }
    var remaining: Int { max(0, min(100, Int((100 - usedPercent).rounded(.down)))) }
}
struct UsageLimits: Decodable {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window", secondaryWindow = "secondary_window"
    }
}
struct DirectUsage: Decodable {
    let rateLimit: UsageLimits?
    let planType: String?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit", planType = "plan_type" }
    func validated() throws -> DirectUsage {
        guard let p = rateLimit?.primaryWindow, p.usedPercent.isFinite,
              (0...100).contains(p.usedPercent), p.limitWindowSeconds > 0, p.resetAt > 0 else {
            throw QuotaError.message("此帳號沒有可讀取的 Codex 額度，或伺服器格式已變更。")
        }
        if let s = rateLimit?.secondaryWindow {
            guard s.usedPercent.isFinite, (0...100).contains(s.usedPercent), s.limitWindowSeconds > 0, s.resetAt > 0 else {
                throw QuotaError.message("第二視窗額度格式不正確。")
            }
        }
        return self
    }
}
enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

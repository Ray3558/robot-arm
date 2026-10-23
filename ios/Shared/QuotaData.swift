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
                throw QuotaError.message("長期額度格式不正確。")
            }
        }
        return self
    }
}
enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum QuotaWindowText {
    /// Names a rate-limit window by its length, e.g. 18000s → "5 小時", 604800s → "每週".
    static func name(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds == 604_800 { return "每週" }
        if seconds == 86_400 { return "每日" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400) 天" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) 小時" }
        return "\(max(1, seconds / 60)) 分鐘"
    }
    static func title(_ seconds: Int?, fallback: String) -> String {
        name(seconds).map { $0 + "額度" } ?? fallback
    }
    /// Time only when the reset is within a day, otherwise month/day as well.
    static func reset(_ timestamp: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = date.timeIntervalSince(now) < 86_400 ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date) + " 重置"
    }
}

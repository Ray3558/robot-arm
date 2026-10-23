import Foundation
let decoder = JSONDecoder()
let fixture = Data("""
{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1900000000},"secondary_window":null}}
""".utf8)
let quota = try decoder.decode(DirectUsage.self, from: fixture).validated()
precondition(quota.rateLimit?.primaryWindow?.remaining == 75)
precondition(quota.rateLimit?.secondaryWindow == nil)
for invalid in ["{}", "{\"rate_limit\":null}", String(data: fixture, encoding: .utf8)!.replacingOccurrences(of: "\"used_percent\":25", with: "\"used_percent\":125")] {
    do {
        _ = try decoder.decode(DirectUsage.self, from: Data(invalid.utf8)).validated()
        fatalError("Invalid quota was accepted")
    } catch { }
}
precondition(QuotaWindowText.title(18000, fallback: "") == "5 小時額度")
precondition(QuotaWindowText.title(604800, fallback: "") == "每週額度")
precondition(QuotaWindowText.title(nil, fallback: "長期額度") == "長期額度")
precondition(QuotaWindowText.reset(1900000000, now: Date(timeIntervalSince1970: 1899990000)).hasSuffix(" 重置"))
let claude = try decoder.decode(ClaudeUsage.self, from: Data("""
{"five_hour":{"utilization":7.0,"resets_at":"2026-10-23T12:59:00.123456+00:00"},"seven_day":{"utilization":10,"resets_at":"2026-10-27T16:59:00Z"},"seven_day_opus":null}
""".utf8)).limits()
precondition(claude.primaryWindow?.remaining == 93 && claude.primaryWindow?.limitWindowSeconds == 18000)
precondition(claude.primaryWindow?.resetAt == 1792760340)
precondition(claude.secondaryWindow?.remaining == 90 && claude.secondaryWindow?.resetAt == 1793120340)
let idle = try decoder.decode(ClaudeUsage.self, from: Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#.utf8)).limits()
precondition(idle.primaryWindow?.resetAt == 0 && idle.secondaryWindow == nil)
do {
    _ = try decoder.decode(ClaudeUsage.self, from: Data(#"{"five_hour":null}"#.utf8)).limits()
    fatalError("Missing Claude window was accepted")
} catch { }
print("Quota decoding: primary, null secondary, unavailable and invalid ranges, Claude usage passed")

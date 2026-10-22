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
print("Quota decoding: primary, null secondary, unavailable and invalid ranges passed")

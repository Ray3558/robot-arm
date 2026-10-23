import ActivityKit
import Foundation

struct QuotaAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var remaining: Int
        var secondaryRemaining: Int?
        var resetAt: Double?
        var updatedAt: Double
        var textColorHex: String? = nil
        // Optional so activities started by older versions still decode.
        var primaryWindowSeconds: Int? = nil
        var secondaryWindowSeconds: Int? = nil
        var secondaryResetAt: Double? = nil
    }
    var label: String
}


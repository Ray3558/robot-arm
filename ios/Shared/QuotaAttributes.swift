import ActivityKit
import Foundation

struct QuotaAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var remaining: Int
        var secondaryRemaining: Int?
        var resetAt: Double?
        var updatedAt: Double
    }
    var label: String
}

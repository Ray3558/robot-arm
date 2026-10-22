import Foundation
import SwiftUI

enum QuotaAppearance {
    static let defaultHex = "#63E6BE"

    static func normalized(_ value: String?) -> String {
        guard let value else { return defaultHex }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return defaultHex }
        return "#" + hex
    }

    static func color(_ hex: String?) -> Color {
        let value = UInt32(normalized(hex).dropFirst(), radix: 16) ?? 0x63E6BE
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}


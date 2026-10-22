import SwiftUI

/// Filled sector represents remaining quota; the muted sector represents used quota.
struct QuotaPieChart: View {
    let remaining: Int?
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            if let remaining {
                QuotaPieSector(fraction: Double(max(0, min(100, remaining))) / 100)
                    .fill(color)
            } else {
                Text("—").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            }
            Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remaining.map { "剩餘額度 \($0) 百分比" } ?? "額度資料待更新")
    }
}

private struct QuotaPieSector: Shape {
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        if fraction >= 1 { path.addEllipse(in: rect); return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + fraction * 360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

private struct PieSummary: View {
    let title: String
    let remaining: Int?
    let resetAt: Double?
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            QuotaPieChart(remaining: remaining, color: color).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(color.opacity(0.8))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(remaining.map { "\($0)%" } ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("剩餘").font(.caption2)
                }.foregroundStyle(color)
                if let resetAt {
                    Text(QuotaWindowText.reset(resetAt)).font(.caption2).foregroundStyle(color.opacity(0.7))
                }
            }.lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaSummaries: View {
    let state: QuotaAttributes.ContentState
    let color: Color
    var body: some View {
        HStack(spacing: 16) {
            PieSummary(title: QuotaWindowText.title(state.primaryWindowSeconds, fallback: "短期額度"),
                       remaining: state.remaining, resetAt: state.resetAt, color: color)
            if let secondary = state.secondaryRemaining {
                PieSummary(title: QuotaWindowText.title(state.secondaryWindowSeconds, fallback: "長期額度"),
                           remaining: secondary, resetAt: state.secondaryResetAt, color: color)
            }
        }
    }
}

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaAttributes.self) { context in
            let color = QuotaAppearance.color(context.state.textColorHex)
            VStack(alignment: .leading, spacing: 12) {
                Text(context.state.providerName ?? context.attributes.label).font(.headline).foregroundStyle(color)
                QuotaSummaries(state: context.state, color: color)
                Text("更新於 \(Date(timeIntervalSince1970: context.state.updatedAt).formatted(date: .omitted, time: .shortened))" +
                    (context.isStale ? " · 上次額度，待更新" : ""))
                    .font(.caption).foregroundStyle(color.opacity(0.8))
            }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(color)
        } dynamicIsland: { context in
            let color = QuotaAppearance.color(context.state.textColorHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.providerName ?? context.attributes.label).font(.headline).foregroundStyle(color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "chart.pie.fill").font(.headline).foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        QuotaSummaries(state: context.state, color: color)
                        if context.isStale {
                            Text("上次額度 · 待更新 · 點此開啟 App")
                                .font(.caption2).foregroundStyle(color.opacity(0.7))
                                .frame(maxWidth: .infinity)
                        }
                    }.padding(.top, 4).padding(.horizontal, 8)
                }
            } compactLeading: {
                QuotaPieChart(remaining: context.state.remaining, color: color)
                    .frame(width: 20, height: 20)
            } compactTrailing: {
                HStack(spacing: 3) {
                    if context.isStale {
                        Circle().fill(.orange).frame(width: 4, height: 4)
                    }
                    Text("\(context.state.remaining)%")
                }
                    .accessibilityLabel(context.isStale ? "上次額度，剩餘 \(context.state.remaining) 百分比，待更新" : "剩餘 \(context.state.remaining) 百分比")
                    .monospacedDigit().foregroundStyle(color)
            } minimal: {
                QuotaPieChart(remaining: context.state.remaining, color: color)
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .bottomTrailing) {
                        if context.isStale {
                            Circle().fill(.orange).frame(width: 5, height: 5)
                        }
                    }
                    .accessibilityLabel(context.isStale ? "上次額度，待更新" : "額度圓餅圖")
            }
            .keylineTint(color)
        }
    }
}

@main
struct QuotaWidgetBundle: WidgetBundle {
    var body: some Widget { QuotaWidget() }
}

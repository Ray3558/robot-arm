import ActivityKit
import SwiftUI
import WidgetKit

private struct PieSummary: View {
    let title: String
    let remaining: Int?
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            QuotaPieChart(remaining: remaining, color: color).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(color.opacity(0.8))
                Text(remaining.map { "\($0)%" } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaAttributes.self) { context in
            let color = QuotaAppearance.color(context.state.textColorHex)
            VStack(alignment: .leading, spacing: 12) {
                Text(context.attributes.label).font(.headline).foregroundStyle(color)
                HStack(spacing: 16) {
                    PieSummary(title: "主視窗", remaining: context.state.remaining, color: color)
                    if let secondary = context.state.secondaryRemaining {
                        PieSummary(title: "第二視窗", remaining: secondary, color: color)
                    }
                }
                Text("更新於 \(Date(timeIntervalSince1970: context.state.updatedAt).formatted(date: .omitted, time: .shortened))" +
                    (context.isStale ? " · 上次額度，待更新" : ""))
                    .font(.caption).foregroundStyle(color.opacity(0.8))
            }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(color)
        } dynamicIsland: { context in
            let color = QuotaAppearance.color(context.state.textColorHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.label).font(.headline).foregroundStyle(color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "chart.pie.fill").font(.headline).foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            PieSummary(title: "主視窗", remaining: context.state.remaining, color: color)
                            if let secondary = context.state.secondaryRemaining {
                                PieSummary(title: "第二視窗", remaining: secondary, color: color)
                            }
                        }
                        if let reset = context.state.resetAt {
                            HStack(spacing: 4) {
                                Text("主視窗重置")
                                Text(Date(timeIntervalSince1970: reset), format: .dateTime.month().day().hour().minute())
                            }.font(.caption2).foregroundStyle(color.opacity(0.8)).lineLimit(2)
                        }
                        Text(context.isStale ? "上次額度 · 待更新 · 點此開啟 App" : "彩色代表剩餘 · 點此更新")
                            .font(.caption2).foregroundStyle(color.opacity(0.7))
                    }.padding(.top, 4)
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

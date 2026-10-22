import ActivityKit
import SwiftUI
import WidgetKit

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.attributes.label).font(.headline)
                HStack {
                    Text("剩餘 \(context.state.remaining)%").font(.title2.bold())
                    Spacer()
                    if let secondary = context.state.secondaryRemaining {
                        Text("第二視窗 \(secondary)%")
                    }
                }
                ProgressView(value: Double(context.state.remaining), total: 100).tint(.mint)
                Text(context.isStale ? "資料已過期，請開啟 App 更新" : "更新於 \(Date(timeIntervalSince1970: context.state.updatedAt).formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(.mint)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.label).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale ? "—" : "\(context.state.remaining)%").font(.title2.bold()).foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        if let secondary = context.state.secondaryRemaining {
                            Text("第二視窗剩餘 \(secondary)%")
                        }
                        if let reset = context.state.resetAt {
                            Text("主視窗重置：\(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                        }
                        Text(context.isStale ? "資料已過期，點此更新" : "點此開啟 App 更新").font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill").foregroundStyle(.mint)
            } compactTrailing: {
                Text(context.isStale ? "—" : "\(context.state.remaining)%").monospacedDigit().foregroundStyle(.mint)
            } minimal: {
                Text(context.isStale ? "—" : "\(context.state.remaining)").font(.caption).foregroundStyle(.mint)
            }
            .keylineTint(.mint)
        }
    }
}

@main
struct QuotaWidgetBundle: WidgetBundle {
    var body: some Widget { QuotaWidget() }
}

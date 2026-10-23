import ActivityKit
import SwiftUI
import UIKit

private enum Surface {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.060)
    static let card = Color(red: 0.065, green: 0.078, blue: 0.095)
    static let muted = Color(red: 0.57, green: 0.62, blue: 0.66)
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}
private extension View { func islandCard() -> some View { modifier(CardSurface()) } }

private struct PrimaryButton: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(Color.black).background(color, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct DashboardView: View {
    @ObservedObject var model: Model
    @State private var showSettings = false
    @State private var islandActive = !Activity<QuotaAttributes>.activities.isEmpty
    @Environment(\.scenePhase) private var phase
    private var primary: UsageWindow? { model.usage?.rateLimit?.primaryWindow }
    private var secondary: UsageWindow? { model.usage?.rateLimit?.secondaryWindow }
    private var isStale: Bool { model.updatedAt.map { Date().timeIntervalSince($0) > 180 } ?? true }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    quotaHero
                    windowCards
                    islandPreview
                    actions
                    statusCard
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield")
                        Text("OAuth 直連 · 憑證保存在這台 iPhone")
                    }
                    .font(.caption2).foregroundStyle(Surface.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
            }
            .background(Surface.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { if model.connected { await model.refresh(start: false) } }
            .sheet(isPresented: $showSettings) { IslandSettingsView(model: model) }
            .onChange(of: phase) { _ in updateActivityState() }
            .onChange(of: model.updatedAt) { _ in updateActivityState() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("BrandIcon")
                .resizable().scaledToFill().frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("CODEX ISLAND").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Surface.muted)
                Text("用量總覽").font(.system(size: 25, weight: .bold))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(.white.opacity(0.06), in: Circle())
            }.accessibilityLabel("設定與帳號")
        }
    }

    private var quotaHero: some View {
        VStack(spacing: 23) {
            HStack {
                Text("剩餘額度").font(.system(size: 15, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.connected ? (isStale ? Color.orange : model.textColor) : Surface.muted).frame(width: 6, height: 6)
                    Text(model.connected ? (isStale ? "待更新" : "已連線") : "尚未連線")
                        .font(.system(size: 11, weight: .medium))
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.05), in: Capsule())
            }
            ZStack {
                Circle().stroke(.white.opacity(0.055), lineWidth: 13)
                Circle().trim(from: 0, to: Double(primary?.remaining ?? 0) / 100)
                    .stroke(model.textColor.gradient, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: model.textColor.opacity(0.2), radius: 12)
                VStack(spacing: 5) {
                    if let primary {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(primary.remaining)").font(.system(size: 64, weight: .semibold, design: .rounded))
                            Text("%").font(.system(size: 24, weight: .medium, design: .rounded))
                        }.foregroundStyle(model.textColor).monospacedDigit()
                    } else {
                        Text("—").font(.system(size: 64, weight: .medium, design: .rounded)).foregroundStyle(Surface.muted)
                    }
                    Text(primary.map { QuotaWindowText.title($0.limitWindowSeconds, fallback: "短期額度") + "剩餘" } ?? "登入後查看額度")
                        .font(.system(size: 12)).foregroundStyle(Surface.muted)
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(primary.map { QuotaWindowText.title($0.limitWindowSeconds, fallback: "短期額度") + "剩餘 \($0.remaining) 百分比" } ?? "尚未取得額度")
            HStack(spacing: 7) {
                if model.busy { ProgressView().controlSize(.mini).tint(model.textColor) }
                else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                Text(model.updatedAt.map { "更新於 " + $0.formatted(date: .omitted, time: .shortened) } ?? "等待第一次更新")
                Text("· \(model.refreshInterval) 秒檢查")
            }.font(.system(size: 11)).foregroundStyle(Surface.muted)
        }.frame(maxWidth: .infinity).islandCard()
    }

    private var windowCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            WindowCard(title: QuotaWindowText.title(primary?.limitWindowSeconds, fallback: "短期額度"), window: primary, color: model.textColor, symbol: "clock")
            WindowCard(title: QuotaWindowText.title(secondary?.limitWindowSeconds, fallback: "長期額度"), window: secondary, color: model.textColor, symbol: "calendar")
        }
    }

    private var islandPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("靈動島").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("顯示預覽").font(.system(size: 11)).foregroundStyle(Surface.muted)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let stale = model.updatedAt.map { context.date.timeIntervalSince($0) > 180 } ?? true
                HStack {
                    QuotaPieChart(remaining: primary?.remaining, color: model.textColor)
                        .frame(width: 24, height: 24)
                    Spacer()
                    if stale && primary != nil {
                        Text("待更新").font(.caption2).foregroundStyle(.orange)
                    }
                    Text(primary.map { "\($0.remaining)%" } ?? "—")
                        .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(model.textColor).padding(.horizontal, 23).frame(height: 56)
                .background(.black, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .frame(maxWidth: 290).frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Circle().fill(islandActive ? model.textColor : Surface.muted).frame(width: 5, height: 5)
                Text(islandActive ? "即時動態已開啟" : "即時動態未開啟")
                Spacer()
                Button("更換顏色") { showSettings = true }.font(.system(size: 11, weight: .medium))
            }.font(.system(size: 11)).foregroundStyle(Surface.muted)
        }.islandCard()
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if model.connected {
                Button {
                    Task {
                        if islandActive { await model.stop() }
                        else { await model.refresh(start: true) }
                        updateActivityState()
                    }
                } label: {
                    Label(islandActive ? "停止靈動島顯示" : "開啟靈動島", systemImage: islandActive ? "stop.circle" : "play.circle")
                }.buttonStyle(PrimaryButton(color: model.textColor)).disabled(model.busy)
                Button { Task { await model.refresh(start: false) } } label: {
                    Label(model.busy ? "正在更新" : "立即更新額度", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.disabled(model.busy)
            } else {
                Button { showSettings = true; model.startLogin() } label: {
                    Label("登入 ChatGPT", systemImage: "person.crop.circle")
                }.buttonStyle(PrimaryButton(color: model.textColor))
                Text("使用現有帳號查看 Codex 額度").font(.caption).foregroundStyle(Surface.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(model.textColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                Text("背景更新由 iOS 調度，可能延遲。超過 3 分鐘會保留上次額度並標示待更新；回到 App 自動更新，已開啟的靈動島若結束也會自動恢復。")
                    .font(.system(size: 11)).foregroundStyle(Surface.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
    }
    private func updateActivityState() { islandActive = !Activity<QuotaAttributes>.activities.isEmpty }
}

private struct WindowCard: View {
    let title: String
    let window: UsageWindow?
    let color: Color
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Surface.muted)
            Text(window.map { "\($0.remaining)%" } ?? "—")
                .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            if let window {
                Text("剩餘額度").font(.system(size: 10)).foregroundStyle(Surface.muted)
                Text(QuotaWindowText.reset(window.resetAt))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            } else {
                Text("尚無可用資料").font(.system(size: 11)).foregroundStyle(Surface.muted)
                Text("等待帳號回傳").font(.system(size: 11)).foregroundStyle(Surface.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).islandCard()
    }
}

private struct IslandSettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCode = false
    private let swatches = ["#63E6BE", "#FFFFFF", "#77B5FF", "#B69CFF", "#FF94C2", "#FFC66D"]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 13) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(model.textColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ChatGPT 帳號").font(.headline)
                            Text(model.connected ? "OAuth 已連線" : "登入以查看真實額度").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                    if !model.signingIn {
                        Button(model.connected ? "重新登入" : "登入 ChatGPT") { model.startLogin() }
                    }
                    if model.signingIn && model.device == nil {
                        HStack(spacing: 10) { ProgressView(); Text("正在準備安全登入…") }
                    }
                    if let device = model.device {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("1  複製一次性登入碼").font(.caption).foregroundStyle(.secondary)
                            Text(device.code).font(.system(size: 29, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button(copiedCode ? "已複製" : "複製登入碼") {
                                UIPasteboard.general.string = device.code; copiedCode = true
                            }
                            Divider()
                            Text("2  在官方頁面完成授權").font(.caption).foregroundStyle(.secondary)
                            Link(destination: URL(string: "https://auth.openai.com/codex/device")!) {
                                Label("開啟官方授權頁面", systemImage: "arrow.up.right.square")
                            }
                            Text("完成後回到這裡，App 會繼續登入。只授權這台手機剛產生的登入碼。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    if model.signingIn { Button("取消登入", role: .cancel) { model.cancelLogin() } }
                    if model.connected { Button("登出這台 iPhone", role: .destructive) { Task { await model.logout() } } }
                } header: { Text("帳號") } footer: { Text(model.status) }

                Section {
                    ColorPicker("自訂字體顏色", selection: Binding(get: { model.textColor }, set: { model.setTextColor($0) }), supportsOpacity: false)
                    HStack(spacing: 12) {
                        ForEach(swatches, id: \.self) { hex in
                            Button { model.setTextColorHex(hex) } label: {
                                Circle().fill(QuotaAppearance.color(hex)).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
                                    .overlay {
                                        if model.textColorHex == hex {
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                                        }
                                    }
                            }.buttonStyle(.plain).accessibilityLabel("選擇顏色 \(hex)")
                        }
                    }.padding(.vertical, 8)
                    HStack {
                        Image(systemName: "terminal.fill")
                        Spacer()
                        Text("Codex  75%").monospacedDigit()
                    }.font(.headline).foregroundStyle(model.textColor)
                        .padding(18).background(.black, in: Capsule())
                        .accessibilityLabel("示範文字顏色，75 百分比為預覽資料")
                    HStack { Text("色碼"); Spacer(); Text(model.textColorHex).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    Button("恢復預設薄荷綠") { model.setTextColorHex(QuotaAppearance.defaultHex) }
                } header: { Text("外觀") } footer: { Text("顏色會自動儲存，並套用到靈動島與鎖定畫面。上方 75% 僅用於色彩預覽。") }

                Section {
                    Picker("前景檢查間隔", selection: $model.refreshInterval) {
                        Text("15 秒").tag(15); Text("30 秒").tag(30); Text("60 秒").tag(60)
                    }.pickerStyle(.segmented)
                    Label("切回 App 時自動檢查", systemImage: "arrow.triangle.2.circlepath")
                } header: { Text("自動更新") } footer: {
                    Text("較短間隔會增加耗電。背景更新由 iOS 決定，不能保證額度變動時立即刷新；連線失敗會延後重試。")
                }

                Section {
                    Link(destination: URL(string: "https://chatgpt.com/codex/settings/usage")!) {
                        Label("查看官方用量頁面", systemImage: "safari")
                    }
                    HStack { Text("版本"); Spacer(); Text("0.5.2").foregroundStyle(.secondary) }
                    Label("憑證僅儲存於本機 Keychain", systemImage: "lock.shield")
                } header: { Text("關於") } footer: {
                    Text("個人用實驗整合。Codex 服務介面或帳號限制可能影響登入及用量讀取。")
                }
            }
            .scrollContentBackground(.hidden).background(Surface.background)
            .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: model.device?.code) { _ in copiedCode = false }
        }.preferredColorScheme(.dark).tint(model.textColor)
    }
}

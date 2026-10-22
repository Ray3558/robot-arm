import SwiftUI
import WebKit
import CoreMotion

@main
struct ArmLinkApp: App {
    var body: some Scene { WindowGroup { ControllerView().preferredColorScheme(.dark) } }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let siteURL = URL(string: "https://arduino-arm-3d-viewer.freshauk74.chatgpt.site/")!
    let webView: WKWebView
    @Published var loading = true
    @Published var errorMessage: String?
    private let motion = CMMotionManager()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.configuration.userContentController.add(self, name: "armMotion")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.047, green: 0.067, blue: 0.098, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.allowsBackForwardNavigationGestures = true
        loadHome()
    }
    func loadHome() {
        errorMessage = nil
        webView.load(URLRequest(url: Self.siteURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
    }
    func reload() {
        errorMessage = nil
        if webView.url == nil { loadHome() } else { webView.reload() }
    }
    func signIn() {
        errorMessage = nil
        let url = URL(string: "signin-with-chatgpt?return_to=%2F", relativeTo: Self.siteURL)!.absoluteURL
        webView.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stopMotion()
        loading = true; errorMessage = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "armMotion", message.frameInfo.securityOrigin.host == Self.siteURL.host,
              let body = message.body as? [String: String], let action = body["action"] else { return }
        if action == "start" { startMotion() }
        if action == "stop" { stopMotion() }
    }
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            webView.evaluateJavaScript("window.armMotion?.error('此 iPhone 無法提供動作感測器資料')")
            return
        }
        motion.stopDeviceMotionUpdates()
        motion.deviceMotionUpdateInterval = 1.0 / 25.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            guard let self else { return }
            if error != nil {
                self.stopMotion()
                self.webView.evaluateJavaScript("window.armMotion?.error('無法讀取動作感測器')")
                return
            }
            guard let attitude = sample?.attitude else { return }
            let yaw = attitude.yaw * 180 / Double.pi
            let pitch = attitude.pitch * 180 / Double.pi
            let roll = attitude.roll * 180 / Double.pi
            guard yaw.isFinite, pitch.isFinite, roll.isFinite else { return }
            self.webView.evaluateJavaScript("window.armMotion?.receive({yaw:\(yaw),pitch:\(pitch),roll:\(roll)})")
        }
    }
    func stopMotion() { motion.stopDeviceMotionUpdates() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { handle(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handle(error) }
    private func handle(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        errorMessage = "無法連上同步工作台。請確認網路後重試。\n\(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "https" || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else if url.scheme == "mailto" {
            UIApplication.shared.open(url); decisionHandler(.cancel)
        } else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" {
            if url.host == Self.siteURL.host { webView.load(navigationAction.request) }
            else { UIApplication.shared.open(url) }
        }
        return nil
    }
}

struct ArmBrowser: UIViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ControllerView: View {
    @StateObject private var model = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingHelp = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.mint)
                Text("ARM Link").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新整理工作台")
                Button { showingHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("同步使用說明")
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(Color(red: 0.047, green: 0.067, blue: 0.098))
            ZStack {
                ArmBrowser(model: model)
                if let error = model.errorMessage {
                    VStack(spacing: 18) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.mint)
                        Text("連線暫時中斷").font(.title3.bold())
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重新連線") { model.loadHome() }.buttonStyle(.borderedProminent).tint(.teal)
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 0.047, green: 0.067, blue: 0.098))
                }
            }
        }
        .background(Color(red: 0.047, green: 0.067, blue: 0.098))
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                List {
                    Section("同步手機與電腦") {
                        Text("1. 在 App 與電腦網站登入同一個 ChatGPT 帳號。")
                        Text("2. 兩邊保持開啟並連上網路，調整任一關節即可同步。")
                        Text("3. 儲存多個姿態後按播放，兩邊會依相同時間軸執行。")
                        Text("啟用手機傾斜後，轉動手機控制底座、肩部和肘部；其餘關節用 + / − 按鈕微調。可按重新校準將目前姿勢設為中心。")
                        Text("同步約每 0.5 秒檢查一次，實際延遲取決於網路。切回 App 後會重新取得最新狀態。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("電腦網站") {
                        Text(BrowserModel.siteURL.absoluteString).textSelection(.enabled).font(.footnote)
                        ShareLink("分享網站連結", item: BrowserModel.siteURL)
                        Button("複製網站連結") { UIPasteboard.general.string = BrowserModel.siteURL.absoluteString }
                    }
                    Section("帳號") {
                        Text("登入由網站的 ChatGPT 官方登入流程處理。App 不內嵌帳號憑證，也不會讀取登入密碼。")
                            .font(.footnote)
                        Button("開啟登入頁面") { showingHelp = false; model.signIn() }
                        Button("回到工作台") { showingHelp = false; model.loadHome() }
                    }
                    Section("馬達配置") {
                        Text("MG996R × 3：底座、肩部、肘部")
                        Text("SG90 × 3：手腕旋轉、手腕俯仰、夾爪")
                        Text("目前為軟體預覽；未連接實體 Arduino。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("使用說明")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingHelp = false } } }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.stopMotion() }
        }
    }
}

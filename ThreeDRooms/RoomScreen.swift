import SwiftUI
import WebKit

/// One saved view, full screen, with nothing else. A swipe in from the left
/// edge opens the view list.
struct RoomScreen: View {
    let view: ViewRef
    @Environment(AppModel.self) private var model
    @State private var page: PageLoad?
    @State private var failure: String?
    @State private var showHint = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let page {
                RoomWebView(page: page) { message in
                    failure = message
                }
                .ignoresSafeArea()
                // A thin strip on the left edge owns the switch swipe; the 3D
                // view keeps every other touch.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                                .onEnded { drag in
                                    if drag.translation.width > 50, abs(drag.translation.height) < drag.translation.width {
                                        model.showPicker = true
                                    }
                                })
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
            }
            if let failure {
                ContentUnavailableView {
                    Label("Can't open \(view.title)", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { attempt += 1 }.buttonStyle(.borderedProminent)
                    Button("Choose another view") { model.showPicker = true }
                }
                .background(Theme.background.ignoresSafeArea())
            }
            if showHint {
                SwipeHint().transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: "\(view.id)#\(attempt)") { await load() }
        .task { await hintOnce() }
    }

    private func load() async {
        failure = nil
        guard let server = model.server else { return }
        do {
            // A fresh token goes with every load, so the page never starts expired.
            let tokens = try await model.freshTokens()
            page = PageLoad(url: HomeAssistant.viewURL(server, viewID: view.id),
                            script: HomeAssistant.tokenScript(tokens, origin: server),
                            origin: server, attempt: attempt)
        } catch HAError.signedOut {
            // Signed out: the root shows the sign-in screen.
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The first few launches remind the user how to switch views.
    private func hintOnce() async {
        let shown = UserDefaults.standard.integer(forKey: "switchHintShown")
        guard shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: "switchHintShown")
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { showHint = true }
        try? await Task.sleep(for: .seconds(3.5))
        withAnimation { showHint = false }
    }
}

private struct SwipeHint: View {
    var body: some View {
        // Below the middle, clear of the page's own "Preparing the 3D view…" label.
        HStack {
            Label("Swipe from the edge to switch views", systemImage: "chevron.compact.right")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.leading, 12)
            Spacer()
        }
        .offset(y: 90)
        .allowsHitTesting(false)
    }
}

struct PageLoad: Equatable {
    let url: URL
    let script: String
    let origin: URL
    let attempt: Int
}

private struct RoomWebView: UIViewRepresentable {
    let page: PageLoad
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Persistent, so room models stay cached between launches.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.background)
        web.scrollView.backgroundColor = UIColor(Theme.background)
        // The page lays itself out around the notch (viewport-fit=cover).
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        #if DEBUG
        web.isInspectable = true
        #endif
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        let scripts = web.configuration.userContentController
        scripts.removeAllUserScripts()
        scripts.addUserScript(WKUserScript(source: page.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.load(URLRequest(url: page.url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RoomWebView
        var loaded: PageLoad?
        init(_ parent: RoomWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Links away from Home Assistant open in Safari, never inside the app.
            if let url = action.request.url, action.targetFrame?.isMainFrame != false,
               url.host() != parent.page.origin.host() || url.port != parent.page.origin.port,
               ["http", "https"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.onFailure("Could not reach Home Assistant at \(parent.page.origin.absoluteString). \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                parent.onFailure(http.statusCode == 404
                    ? "This Home Assistant has no 3D Rooms view page. Update the 3D Rooms integration."
                    : "Home Assistant answered \(http.statusCode). Is 3D Rooms set up?")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // iOS ends a background page that uses too much memory: start it again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}

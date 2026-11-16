import SwiftUI
import WebKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var login: LoginRequest?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("3D Rooms").font(.largeTitle.bold())
                Text("Sign in to your Home Assistant to open your 3D views.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Home Assistant address", text: $address,
                          prompt: Text("http://homeassistant.local:8123").foregroundStyle(.secondary))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(start)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Button(action: start) {
                Text("Sign in with Home Assistant")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 480)
        .onAppear {
            address = model.server?.absoluteString ?? ""
            if address.isEmpty { focused = true }
        }
        .sheet(item: $login) { request in
            LoginSheet(request: request) { tokens in
                model.signedIn(origin: request.origin, tokens: tokens)
            }
        }
    }

    private func start() {
        guard let origin = HomeAssistant.origin(from: address) else {
            error = HAError.invalidServer.localizedDescription
            return
        }
        error = nil
        address = origin.absoluteString
        login = LoginRequest(origin: origin)
    }
}

struct LoginRequest: Identifiable {
    let id = UUID()
    let origin: URL
    let state = UUID().uuidString
}

/// Home Assistant's own login page. The app only catches its final redirect,
/// so passwords and 2FA codes stay between the user and Home Assistant.
struct LoginSheet: View {
    let request: LoginRequest
    let onTokens: (HATokens) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var exchanging = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                LoginWebView(request: request, attempt: attempt, onCode: exchange) { message in
                    error = message
                }
                if exchanging {
                    ProgressView("Signing in…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if let error {
                    ContentUnavailableView {
                        Label("Can't sign in", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") {
                            self.error = nil
                            attempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .background(Theme.background)
                }
            }
            .navigationTitle(request.origin.host() ?? "Home Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(exchanging)
    }

    private func exchange(_ code: String?) {
        guard let code else {
            error = "Home Assistant did not confirm the login. Try again."
            return
        }
        exchanging = true
        Task {
            do {
                let tokens = try await HomeAssistant.exchange(code: code, origin: request.origin)
                onTokens(tokens)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            exchanging = false
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let request: LoginRequest
    let attempt: Int
    let onCode: (String?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing from the login page is kept; the app stores only its own tokens.
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.background)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedAttempt != attempt else { return }
        context.coordinator.loadedAttempt = attempt
        web.load(URLRequest(url: HomeAssistant.authorizeURL(request.origin, state: request.state)))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LoginWebView
        var loadedAttempt: Int?
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url,
               let code = HomeAssistant.authorizationCode(in: url, origin: parent.request.origin, state: parent.request.state) {
                decisionHandler(.cancel)
                parent.onCode(code)
                return
            }
            decisionHandler(.allow)
        }

        // Another server, or Home Assistant behind a broken proxy: say so
        // instead of showing its error page.
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel)
                parent.onError("No Home Assistant login found at \(parent.request.origin.absoluteString) (it answered \(http.statusCode)). Check the address and port.")
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            // Our own cancel of the redirect is not a failure.
            if (error as NSError).code == NSURLErrorCancelled || (error as NSError).code == 102 { return }
            parent.onError("Could not reach Home Assistant at \(parent.request.origin.absoluteString). \(error.localizedDescription)")
        }
    }
}

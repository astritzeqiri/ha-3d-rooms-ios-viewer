import Observation
import SwiftUI
import UIKit
import WebKit

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum ListState: Equatable { case idle, loading, loaded, failed(String) }

    private let defaults = UserDefaults.standard

    /// The Home Assistant origin, such as `http://192.168.1.10:8123`.
    var server: URL? {
        didSet { defaults.set(server?.absoluteString, forKey: "server") }
    }
    let wifi = HomeWiFi()
    var connectionURL: URL? {
        guard let config = wifi.configuration else { return server }
        return wifi.resolved ? config.address(on: wifi.ssid, external: server) : nil
    }
    var tokens: HATokens? {
        didSet { if tokens != oldValue { Keychain.save(tokens) } }
    }
    /// The view that opens, full screen, every time the app launches.
    var defaultView: ViewRef? {
        didSet { defaults.set(try? JSONEncoder().encode(defaultView), forKey: "defaultView") }
    }
    var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: "keepScreenOn")
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
    }

    /// How much model detail the room loads. Rooms are kept on the device
    /// after the first download, so full detail costs data only once.
    var roomDetail: RoomDetail = .view {
        didSet { defaults.set(roomDetail.rawValue, forKey: "roomDetail") }
    }

    var views: [SavedView] = []
    var listState = ListState.idle
    /// The view list over the room (edge swipe or the "Switch view" quick action).
    var showPicker = false

    init() {
        server = defaults.string(forKey: "server").flatMap(URL.init(string:))
        tokens = Keychain.load()
        defaultView = defaults.data(forKey: "defaultView").flatMap { try? JSONDecoder().decode(ViewRef.self, from: $0) }
        keepScreenOn = defaults.bool(forKey: "keepScreenOn")
        roomDetail = RoomDetail(rawValue: defaults.string(forKey: "roomDetail") ?? "") ?? .view
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }

    var isSignedIn: Bool { server != nil && tokens != nil }

    func signedIn(origin: URL, tokens: HATokens) {
        if server != origin {
            defaultView = nil
            wifi.save(nil)
        }
        server = origin
        self.tokens = tokens
    }

    /// A current access token, refreshed when it is about to expire.
    func freshTokens() async throws -> HATokens {
        guard let server, let endpoint = connectionURL, let current = tokens else { throw HAError.signedOut }
        if current.expires.timeIntervalSinceNow > 120 { return current }
        do {
            let next = try await HomeAssistant.refresh(current, origin: endpoint, loginOrigin: server)
            if tokens?.refreshToken == current.refreshToken { tokens = next }
            return next
        } catch HAError.signedOut {
            guard tokens?.refreshToken == current.refreshToken, connectionURL == endpoint else { throw CancellationError() }
            guard endpoint == server else { throw HAError.server("The internal server rejected this login. Check your internal URL in Settings.") }
            tokens = nil
            throw HAError.signedOut
        }
    }

    func loadViews() async {
        guard let server = connectionURL, let session = tokens?.refreshToken else { return }
        listState = .loading
        do {
            let token = try await freshTokens().accessToken
            guard !Task.isCancelled, server == connectionURL, session == tokens?.refreshToken else { return }
            let result = try await HomeAssistant.savedViews(origin: server, accessToken: token)
            guard !Task.isCancelled, server == connectionURL, session == tokens?.refreshToken else { return }
            views = result
            listState = .loaded
            // Keep the remembered title current; forget a view that was deleted.
            if let chosen = defaultView {
                if let view = views.first(where: { $0.id == chosen.id }) {
                    if view.title != chosen.title { defaultView = ViewRef(id: view.id, title: view.title) }
                } else {
                    defaultView = nil
                }
            }
            updateQuickActions()
        } catch {
            guard !Task.isCancelled, server == connectionURL, session == tokens?.refreshToken else { return }
            listState = .failed(error.localizedDescription)
        }
    }

    func choose(_ view: SavedView) {
        defaultView = ViewRef(id: view.id, title: view.title)
        showPicker = false
    }

    func signOut() {
        if let endpoint = connectionURL ?? server, let tokens { Task { await HomeAssistant.revoke(tokens, origin: endpoint) } }
        wifi.save(nil)
        tokens = nil
        defaultView = nil
        views = []
        listState = .idle
        showPicker = false
        UIApplication.shared.shortcutItems = []
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    // MARK: Home screen quick actions

    private func updateQuickActions() {
        UIApplication.shared.shortcutItems = views.prefix(3).map { view in
            UIApplicationShortcutItem(
                type: "open", localizedTitle: view.title, localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "cube"),
                userInfo: ["id": view.id as NSString, "title": view.title as NSString])
        }
    }

    func handle(_ item: UIApplicationShortcutItem) {
        if item.type == "open", let id = item.userInfo?["id"] as? String, let title = item.userInfo?["title"] as? String {
            defaultView = ViewRef(id: id, title: title)
            showPicker = false
        } else {
            showPicker = defaultView != nil
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            Task { @MainActor in AppModel.shared.handle(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private var privacyWindow: UIWindow?

    func sceneWillResignActive(_ scene: UIScene) {
        // Face ID temporarily makes the scene inactive. The lock screen
        // already covers this transition and can dismiss on a successful match.
        guard !AppLock.shared.locked else { return }
        coverPrivateContent(in: scene)
    }

    private func coverPrivateContent(in scene: UIScene) {
        guard privacyWindow == nil, AppLock.shared.enabled, let scene = scene as? UIWindowScene else { return }
        let cover = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: LockScreen(appLock: .shared))
        controller.view.backgroundColor = UIColor(Theme.background)
        cover.rootViewController = controller
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        cover.windowLevel = .alert + 1
        cover.isHidden = false
        privacyWindow = cover
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        coverPrivateContent(in: scene)
        AppLock.shared.enteredBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        privacyWindow?.isHidden = true
        privacyWindow = nil
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            AppModel.shared.handle(item)
            completionHandler(true)
        }
    }
}

/// The Room detail setting: follow the saved view, or force full or lighter
/// detail. Sent to the integration's full-screen page as `?quality=`.
enum RoomDetail: String, CaseIterable, Identifiable {
    case view, high, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .view: "As set in the view"
        case .high: "Full detail"
        case .low: "Lighter (less data)"
        }
    }
    /// The page's `quality` value, or nil to use the view's own setting.
    var quality: String? { self == .view ? nil : rawValue }
}

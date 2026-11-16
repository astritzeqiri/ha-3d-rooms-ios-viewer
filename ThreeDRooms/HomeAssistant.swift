import Foundation
import Security
import UIKit

/// Tokens from Home Assistant's own OAuth login. The refresh token lasts until
/// the user removes "3D Rooms" under Profile → Security in Home Assistant.
struct HATokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
}

/// A saved 3D Rooms view, as `three_d_rooms/request` → `components` lists it.
struct SavedView: Identifiable {
    let id: String
    let title: String
    let thumbnail: UIImage?
}

/// The view the app opens on launch. Kept with its title so the app can show
/// it before the list has loaded.
struct ViewRef: Codable, Equatable {
    let id: String
    let title: String
}

enum HAError: LocalizedError {
    case signedOut
    case invalidServer
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Your Home Assistant login has ended. Sign in again."
        case .invalidServer: "Enter your Home Assistant address, for example http://homeassistant.local:8123."
        case .server(let message): message
        }
    }
}

enum HomeAssistant {
    /// `http://host:port` with no path, the form Home Assistant and the page's
    /// `location.origin` both use.
    static func origin(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    // MARK: Login (IndieAuth OAuth2)

    // Same host as Home Assistant, so it accepts the redirect without fetching
    // a client page from the internet. The app catches the redirect itself.
    static func clientID(_ origin: URL) -> String { origin.absoluteString + "/three_d_rooms_ios" }
    static func redirectURI(_ origin: URL) -> String { clientID(origin) + "/callback" }

    static func authorizeURL(_ origin: URL, state: String) -> URL {
        var parts = URLComponents(url: origin.appendingPathComponent("auth/authorize"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID(origin)),
            .init(name: "redirect_uri", value: redirectURI(origin)),
            .init(name: "state", value: state),
        ]
        return parts.url!
    }

    /// The `code` when `url` is the login's redirect, else nil.
    static func authorizationCode(in url: URL, origin: URL, state: String) -> String?? {
        guard let redirect = URLComponents(string: redirectURI(origin)),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == redirect.scheme, parts.host == redirect.host,
              parts.port == redirect.port, parts.path == redirect.path
        else { return nil }
        let items = parts.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { return .some(nil) }
        return .some(items.first(where: { $0.name == "code" })?.value)
    }

    static func exchange(code: String, origin: URL) async throws -> HATokens {
        let body = try await token(origin, [
            "grant_type": "authorization_code", "code": code, "client_id": clientID(origin),
        ])
        guard let access = body["access_token"] as? String, let refresh = body["refresh_token"] as? String else {
            throw HAError.server("Home Assistant did not return a login.")
        }
        return HATokens(accessToken: access, refreshToken: refresh, expires: expiry(body))
    }

    static func refresh(_ tokens: HATokens, origin: URL) async throws -> HATokens {
        let body = try await token(origin, [
            "grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": clientID(origin),
        ])
        guard let access = body["access_token"] as? String else { throw HAError.signedOut }
        return HATokens(accessToken: access, refreshToken: tokens.refreshToken, expires: expiry(body))
    }

    /// Removes this app's login from Home Assistant. Best effort.
    static func revoke(_ tokens: HATokens, origin: URL) async {
        var request = URLRequest(url: origin.appendingPathComponent("auth/revoke"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["token": tokens.refreshToken])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func expiry(_ body: [String: Any]) -> Date {
        Date().addingTimeInterval((body["expires_in"] as? Double) ?? 1800)
    }

    private static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func token(_ origin: URL, _ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: origin.appendingPathComponent("auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // An invalid or revoked refresh token: the login is gone.
        if [400, 401, 403].contains(status), values["grant_type"] == "refresh_token" { throw HAError.signedOut }
        guard status == 200 else {
            let message = body["error_description"] as? String ?? body["error"] as? String
            throw HAError.server(message ?? "Home Assistant answered \(status).")
        }
        return body
    }

    // MARK: Saved views

    /// Lists the saved views over Home Assistant's websocket. Any signed-in
    /// user may; only administrators also receive the preview images.
    static func savedViews(origin: URL, accessToken: String) async throws -> [SavedView] {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/api/websocket"
        let socket = URLSession.shared.webSocketTask(with: parts.url!)
        socket.maximumMessageSize = 64 * 1024 * 1024 // Preview images are ~100 KB each.
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        func receive() async throws -> [String: Any] {
            let data: Data
            switch try await socket.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: data = Data()
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        func send(_ message: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }

        _ = try await receive() // auth_required
        try await send(["type": "auth", "access_token": accessToken])
        let auth = try await receive()
        guard auth["type"] as? String == "auth_ok" else { throw HAError.signedOut }
        try await send([
            "id": 1, "type": "three_d_rooms/request", "operation": "components",
            "data": ["include_thumbnails": true],
        ])
        while true {
            let message = try await receive()
            guard message["id"] as? Int == 1 else { continue }
            guard message["success"] as? Bool == true, let list = message["result"] as? [[String: Any]] else {
                let error = message["error"] as? [String: Any]
                throw HAError.server(error?["message"] as? String ?? "3D Rooms could not list views.")
            }
            return list.compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
                return SavedView(id: id, title: title, thumbnail: image(item["thumbnail"] as? String))
            }
        }
    }

    private static func image(_ dataURL: String?) -> UIImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ",") else { return nil }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    // MARK: The full-screen page

    /// The integration's own chrome-free page for one saved view.
    static func viewURL(_ origin: URL, viewID: String) -> URL {
        origin.appendingPathComponent("three_d_rooms_view").appendingPathComponent(viewID)
    }

    /// Script that hands the login to the page before it starts. The page signs
    /// in with `localStorage.hassTokens`, the same store Home Assistant uses.
    static func tokenScript(_ tokens: HATokens, origin: URL) -> String {
        let payload: [String: Any] = [
            "hassUrl": origin.absoluteString,
            "clientId": clientID(origin),
            "access_token": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "token_type": "Bearer",
            "expires_in": max(0, Int(tokens.expires.timeIntervalSinceNow)),
            "expires": Int(tokens.expires.timeIntervalSince1970 * 1000),
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        // Wrapped in arrays so both values are valid JavaScript string literals.
        let values = String(decoding: try! JSONSerialization.data(withJSONObject: [origin.absoluteString, json]), as: UTF8.self)
        return "(function(){try{var v=\(values);if(location.origin===v[0])localStorage.setItem('hassTokens',v[1]);}catch(e){}})();"
    }
}

/// The login is kept in the Keychain, readable only on this device once unlocked.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.astritzeqiri.threedrooms",
        kSecAttrAccount as String: "home-assistant-tokens",
    ]

    static func load() -> HATokens? {
        var search = query
        search[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(HATokens.self, from: data)
    }

    static func save(_ tokens: HATokens?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

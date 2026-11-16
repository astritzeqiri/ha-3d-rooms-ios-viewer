import CoreLocation
import Network
import NetworkExtension
import Observation

struct HomeNetwork: Codable {
    let name: String
    let url: URL

    func address(on ssid: String?, external: URL?) -> URL? {
        guard let ssid, name.utf8.elementsEqual(ssid.utf8) else { return external }
        return url
    }
}

@MainActor
@Observable
final class HomeWiFi: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var monitor: NWPathMonitor?
    private var polling: Task<Void, Never>?
    private var revision = 0
    private var foreground = false
    private(set) var ssid: String?
    private(set) var resolved = false
    private(set) var needsPermission = false
    private(set) var configuration: HomeNetwork?

    override init() {
        if let data = UserDefaults.standard.data(forKey: "homeNetwork") {
            configuration = try? JSONDecoder().decode(HomeNetwork.self, from: data)
        }
        super.init()
        location.delegate = self
    }

    func save(_ value: HomeNetwork?) {
        configuration = value
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: "homeNetwork")
        if value != nil && location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        restart()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        restart()
    }

    private func restart() {
        revision += 1
        monitor?.cancel()
        monitor = nil
        polling?.cancel()
        polling = nil
        ssid = nil
        resolved = false
        guard foreground, configuration != nil else { return }
        let path = NWPathMonitor()
        monitor = path
        path.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        path.start(queue: DispatchQueue(label: "3DRooms.HomeWiFi"))
        // A switch between two Wi-Fi networks can keep the same network path.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in refresh() }
    }

    private func refresh() {
        guard foreground, configuration != nil else { return }
        revision += 1
        let request = revision
        let status = location.authorizationStatus
        needsPermission = (status != .authorizedAlways && status != .authorizedWhenInUse)
            || location.accuracyAuthorization != .fullAccuracy
        guard !needsPermission, monitor?.currentPath.usesInterfaceType(.cellular) != true else {
            ssid = nil
            resolved = true
            return
        }
        Task {
            let network = await NEHotspotNetwork.fetchCurrent()
            guard request == revision else { return }
            ssid = network?.ssid
            resolved = true
        }
    }
}

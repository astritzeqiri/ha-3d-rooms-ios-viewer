import LocalAuthentication
import Observation

@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()
    private static let preference = "requireFaceID"
    private(set) var enabled = UserDefaults.standard.bool(forKey: preference)
    private(set) var locked = UserDefaults.standard.bool(forKey: preference)
    private(set) var authenticating = false
    private(set) var message: String?
    private var automaticUnlockPending = true
    @ObservationIgnored private var currentContext: LAContext?

    var supportsFaceID: Bool {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .faceID
    }

    func enteredBackground() {
        currentContext?.invalidate()
        currentContext = nil
        authenticating = false
        locked = enabled
        automaticUnlockPending = true
        message = nil
    }

    func becameActive() async {
        guard locked, automaticUnlockPending else { return }
        automaticUnlockPending = false
        await unlock()
    }

    func unlock() async {
        guard locked else { return }
        if await authenticate(.deviceOwnerAuthentication, reason: "Unlock 3D Rooms.") {
            locked = false
        }
    }

    func setEnabled(_ value: Bool) async {
        guard enabled != value, !locked else { return }
        let policy: LAPolicy = value ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard await authenticate(policy, reason: value ? "Turn on Face ID for 3D Rooms." : "Turn off Face ID for 3D Rooms.") else { return }
        UserDefaults.standard.set(value, forKey: Self.preference)
        enabled = value
    }

    private func authenticate(_ policy: LAPolicy, reason: String) async -> Bool {
        guard currentContext == nil else { return false }
        let context = LAContext()
        currentContext = context
        authenticating = true
        message = nil
        defer {
            if currentContext === context {
                currentContext = nil
                authenticating = false
            }
        }
        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            return currentContext === context && success
        } catch {
            guard currentContext === context else { return false }
            switch (error as? LAError)?.code {
            case .userCancel, .systemCancel, .appCancel: break
            default: message = error.localizedDescription
            }
            return false
        }
    }
}

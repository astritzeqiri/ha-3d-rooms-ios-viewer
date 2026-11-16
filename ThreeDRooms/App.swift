import SwiftUI

@main
struct ThreeDRoomsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    @State private var appLock = AppLock.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: phase, initial: true) { _, phase in
                    if phase != .inactive { model.wifi.setForeground(phase == .active) }
                    if phase == .active { Task { await appLock.becameActive() } }
                }
                .environment(appLock)
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct LockScreen: View {
    let appLock: AppLock
    var openingRoom = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: openingRoom ? "lock.open.fill" : "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text(openingRoom ? "Opening your room…" : "3D Rooms is locked")
                .font(.title2.bold())
            if openingRoom {
                ProgressView()
            } else {
                Button("Unlock 3D Rooms") { Task { await appLock.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(appLock.authenticating)
                if let message = appLock.message {
                    Text(message).font(.footnote).multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

enum Theme {
    static let background = Color(red: 0x10 / 255, green: 0x17 / 255, blue: 0x15 / 255)
    static let accent = Color(red: 0x36 / 255, green: 0xD4 / 255, blue: 0xC2 / 255)
}

/// Signed out → sign in. A default view → that view, full screen, and nothing
/// else. No default yet → the list of views to choose one.
struct RootView: View {
    @Environment(AppModel.self) private var model

    @Environment(AppLock.self) private var appLock

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.isSignedIn, let view = model.defaultView {
                RoomScreen(view: view)
                    .opacity(appLock.locked ? 0 : 1)
                    .allowsHitTesting(!appLock.locked)
                    .accessibilityHidden(appLock.locked)
            }
            if appLock.locked {
                LockScreen(appLock: appLock)
            } else if !model.isSignedIn {
                OnboardingView()
            } else if model.defaultView == nil {
                NavigationStack { ViewPicker(asSheet: false) }
            } else {
                Color.clear.allowsHitTesting(false)
                    .sheet(isPresented: $model.showPicker) {
                        NavigationStack { ViewPicker(asSheet: true) }
                    }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        // The list also feeds the home screen quick actions, so it refreshes on launch.
        .task(id: [model.tokens?.refreshToken, model.connectionURL?.absoluteString, String(appLock.locked)]) {
            if model.isSignedIn && !appLock.locked { await model.loadViews() }
        }
    }
}

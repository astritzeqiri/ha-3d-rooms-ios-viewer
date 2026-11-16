import SwiftUI

@main
struct ThreeDRoomsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
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

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.isSignedIn {
                OnboardingView()
            } else if let view = model.defaultView {
                RoomScreen(view: view)
                    .sheet(isPresented: $model.showPicker) {
                        NavigationStack { ViewPicker(asSheet: true) }
                    }
            } else {
                NavigationStack { ViewPicker(asSheet: false) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        // The list also feeds the home screen quick actions, so it refreshes on launch.
        .task(id: model.tokens?.refreshToken) {
            if model.isSignedIn { await model.loadViews() }
        }
    }
}

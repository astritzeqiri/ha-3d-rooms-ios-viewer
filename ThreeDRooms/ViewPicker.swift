import SwiftUI

/// The saved 3D Rooms views. Tapping one makes it the view the app opens with.
struct ViewPicker: View {
    let asSheet: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Choose a view")
        .refreshable { await model.loadViews() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            if asSheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch (model.listState, model.views.isEmpty) {
        case (.failed(let message), true):
            ContentUnavailableView {
                Label("Can't load views", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.loadViews() } }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 80)
        case (.loaded, true):
            ContentUnavailableView(
                "No saved views",
                systemImage: "cube.transparent",
                description: Text("Create one in Home Assistant under 3D Rooms → Dashboard views, then pull down to refresh."))
            .padding(.top, 80)
        case (_, true):
            ProgressView().padding(.top, 120)
        default:
            VStack(alignment: .leading, spacing: 16) {
                Text("The view you choose opens full screen every time you start the app. Swipe in from the left edge to come back here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(model.views) { view in
                        Button { model.choose(view) } label: {
                            ViewCard(view: view, isDefault: view.id == model.defaultView?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct ViewCard: View {
    let view: SavedView
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white.opacity(0.05)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let image = view.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                    }
                }
                .clipped()
            HStack {
                Text(view.title).font(.headline).lineLimit(2)
                Spacer()
                if isDefault {
                    Label("Opens on launch", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.accent)
                        .font(.title3)
                }
            }
            .padding(14)
        }
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isDefault ? Theme.accent : .white.opacity(0.08), lineWidth: isDefault ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDefault ? .isSelected : [])
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Home Assistant") {
                LabeledContent("Server", value: model.server?.absoluteString ?? "—")
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
            Section {
                Toggle("Keep screen on", isOn: $model.keepScreenOn)
            } footer: {
                Text("Useful for a wall-mounted iPad or a phone on a stand.")
            }
            Section("Switching views") {
                Text("Swipe in from the left edge of a view, or long-press the app icon and choose Switch view.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Home Assistant?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOut() }
        }
    }
}

import SwiftUI
import WidgetKit

@main
struct RoomsWidgets: WidgetBundle {
    var body: some Widget {
        RoomsLauncher()
        RoomsControl()
    }
}

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(.roomsGlyph)
                        .font(.system(size: 27))
                }
            } else {
                VStack(spacing: 8) {
                    Image(.roomsGlyph)
                        .font(.system(size: 48))
                        .foregroundStyle(Color.mint)
                        .widgetAccentable()
                    Text("3D Rooms").font(.headline)
                }
            }
        }
        .accessibilityLabel("Open 3D Rooms")
        .containerBackground(for: .widget) { Color(red: 0.06, green: 0.09, blue: 0.08) }
    }
}

private struct RoomsLauncher: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.astritzeqiri.threedrooms.launcher", provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Open 3D Rooms")
        .description("Open your 3D Rooms app.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

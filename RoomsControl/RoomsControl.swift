import SwiftUI
import WidgetKit

struct RoomsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.astritzeqiri.threedrooms.open") {
            ControlWidgetButton(action: OpenRoomsIntent(target: .rooms)) {
                Label("Open 3D Rooms", image: .roomsGlyph)
            }
        }
        .displayName("Open 3D Rooms")
        .description("Open your 3D Rooms app.")
    }
}

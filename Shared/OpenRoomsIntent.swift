import AppIntents

@available(iOS 18.0, *)
enum RoomsDestination: String, AppEnum {
    case rooms

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.rooms: "3D Rooms"]
}

@available(iOS 18.0, *)
struct OpenRoomsIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open 3D Rooms"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Destination") var target: RoomsDestination

    init() {}
    init(target: RoomsDestination) { self.target = target }

    func perform() async throws -> some IntentResult { .result() }
}

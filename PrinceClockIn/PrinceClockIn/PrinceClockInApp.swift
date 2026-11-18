import SwiftUI

@main
struct PrinceClockInApp: App {
    // Created with the app, not when the panel opens: a `.window` panel builds its content only
    // when first shown, and the timers and notification delegate must run from launch.
    @State private var appModel: AppModel

    init() {
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra("PrinceClockIn", systemImage: "clock") {
            PanelView(coordinator: appModel.coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

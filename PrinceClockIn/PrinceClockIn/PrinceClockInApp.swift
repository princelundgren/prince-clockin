import SwiftUI

@main
struct PrinceClockInApp: App {
    // Created with the app, not when the panel opens: a `.window` panel builds its content only
    // when first shown, and the timers and notification delegate must run from launch.
    @State private var appModel: AppModel
    @State private var updater: Updater

    init() {
        _appModel = State(initialValue: AppModel())
        _updater = State(initialValue: Updater())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(appModel: appModel, updater: updater)
        } label: {
            MenuBarLabel(coordinator: appModel.coordinator, updater: updater)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appModel: appModel)
        }
    }
}

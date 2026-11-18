import ServiceManagement

/// Launching the app at login, through the system's login items. Off until the user turns it on.
enum LaunchAtLogin {
    /// Read each time it is shown, since the user can change it in System Settings.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Throws: the system's error when the login item can't be added or removed.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

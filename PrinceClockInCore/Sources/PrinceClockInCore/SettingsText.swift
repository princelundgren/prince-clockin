import Foundation

/// The name + gives a new preset in Settings → Presets: "New preset", or the first of "New preset 2",
/// "New preset 3", … that no preset in `existingNames` has.
public func newPresetName(existingNames: [String]) -> String {
    let taken = Set(existingNames)
    let base = "New preset"
    var number = 1
    var name = base
    while taken.contains(name) {
        number += 1
        name = "\(base) \(number)"
    }
    return name
}

/// −'s help tag in Settings → Presets: the preset it removes.
public func removePresetHelp(for preset: Preset?) -> String {
    guard let preset else { return "Remove the selected preset." }
    return "Remove \(preset.name)."
}

/// The times Settings → Notifications' "Notify before a login expires" pop-up offers.
public let listedNotificationLeadTimes: [TimeInterval] = [5, 10, 15, 30, 60, 120].map { $0 * 60 }

/// The times Settings → Logins' "Login timeout" pop-up offers.
public let listedLoginTimeouts: [TimeInterval] = [2, 5, 10, 15].map { $0 * 60 }

/// The times a settings pop-up shows, in ascending order: `listed`, plus `stored` when it isn't
/// listed, so a stored time keeps showing, unchanged, until the user picks another.
public func durationOptions(_ listed: [TimeInterval], showing stored: TimeInterval) -> [TimeInterval] {
    listed.contains(stored) ? listed : (listed + [stored]).sorted()
}

/// The Notifications row in Settings → Notifications.
public struct NotificationsSetting: Equatable, Sendable {
    /// "On" or "Off".
    public let state: String
    /// Under the row while notifications are off: what shows the expiry instead.
    public let note: String?

    public init(state: String, note: String?) {
        self.state = state
        self.note = note
    }
}

/// The Notifications row for notifications that the user has turned off (`areOff`) or not.
public func notificationsSetting(areOff: Bool) -> NotificationsSetting {
    guard areOff else { return NotificationsSetting(state: "On", note: nil) }
    return NotificationsSetting(
        state: "Off", note: "With notifications off, only the menu bar shows that a login is about to expire.")
}

/// The app's login item as the system reports it.
public enum LaunchAtLoginStatus: Equatable, Sendable {
    case off
    case on
    /// Registered, but waiting for the user to allow it in System Settings → General → Login Items.
    case needsApproval
    /// The system can't find the app's login item.
    case notFound
}

/// Turning launch at login on (`turningOn`) or off failed, for the system's `reason`.
public struct LaunchAtLoginFailure: Equatable, Sendable {
    public let turningOn: Bool
    public let reason: String

    public init(turningOn: Bool, reason: String) {
        self.turningOn = turningOn
        self.reason = reason
    }
}

/// What Settings → General shows under Launch at login.
public enum LaunchAtLoginNote: Equatable, Sendable {
    /// Shown with Open…, which opens System Settings → General → Login Items.
    case needsApproval(String)
    case failed(String)
}

/// Settings → General's Launch at login toggle.
public struct LaunchAtLoginSetting: Equatable, Sendable {
    public let isOn: Bool
    public let note: LaunchAtLoginNote?

    public init(isOn: Bool, note: LaunchAtLoginNote?) {
        self.isOn = isOn
        self.note = note
    }
}

/// The toggle for the system's `status` and the last change that failed, if any. A login item
/// waiting for approval is on, and says where to approve it; a failure shows until the status
/// shows the change happened after all.
public func launchAtLoginSetting(status: LaunchAtLoginStatus, failure: LaunchAtLoginFailure?) -> LaunchAtLoginSetting {
    let isOn = status == .on || status == .needsApproval
    if status == .needsApproval {
        return LaunchAtLoginSetting(
            isOn: isOn, note: .needsApproval("Needs your approval in System Settings → General → Login Items."))
    }
    guard let failure, failure.turningOn != isOn else { return LaunchAtLoginSetting(isOn: isOn, note: nil) }
    let change = failure.turningOn ? "on" : "off"
    return LaunchAtLoginSetting(isOn: isOn, note: .failed("Couldn't turn \(change) launch at login. \(failure.reason)"))
}

/// Settings → About's version: "v1.0.0 (42)", the marketing version and the build number.
public func versionText(marketingVersion: String, build: String) -> String {
    "v\(marketingVersion) (\(build))"
}

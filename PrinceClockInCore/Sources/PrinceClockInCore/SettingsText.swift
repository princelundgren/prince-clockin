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

/// A preset's login count under its name in Settings → Presets: "No logins", "1 login", "3 logins".
public func presetLoginCount(_ count: Int) -> String {
    switch count {
    case 0: "No logins"
    case 1: "1 login"
    default: "\(count) logins"
    }
}

/// The title and help tag of a ⊕ or ⊖ button on a login's row in Settings → Presets.
public struct PresetMemberAction: Equatable, Sendable {
    public let label: String
    public let help: String

    public init(label: String, help: String) {
        self.label = label
        self.help = help
    }
}

/// ⊕ on a login not in `preset`: "Add qa", "Add qa to Morning.".
public func addToPresetAction(for login: Login, preset: Preset) -> PresetMemberAction {
    PresetMemberAction(label: "Add \(login.displayName)", help: "Add \(login.displayName) to \(preset.name).")
}

/// ⊖ on a login in `preset`: "Remove dev", "Remove dev from Morning.".
public func removeFromPresetAction(for login: Login, preset: Preset) -> PresetMemberAction {
    PresetMemberAction(label: "Remove \(login.displayName)", help: "Remove \(login.displayName) from \(preset.name).")
}

/// The preset Settings → Presets selects after − removes `id` from `ids`: the one after it, else the
/// one before it, else none.
public func selectionAfterRemoving(_ id: UUID, from ids: [UUID]) -> UUID? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    if index + 1 < ids.count { return ids[index + 1] }
    return index > 0 ? ids[index - 1] : nil
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
    /// Under the row: where notifications are turned on or off, and while they're off, what shows
    /// the expiry instead.
    public let note: String

    public init(state: String, note: String) {
        self.state = state
        self.note = note
    }
}

/// The Notifications row for notifications that the user has turned off (`areOff`) or not.
public func notificationsSetting(areOff: Bool) -> NotificationsSetting {
    guard areOff else {
        return NotificationsSetting(state: "On", note: "Turn notifications on or off in System Settings → Notifications.")
    }
    return NotificationsSetting(
        state: "Off",
        note: "With notifications off, only the menu bar shows that a login is about to expire. "
            + "Turn them on in System Settings → Notifications.")
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

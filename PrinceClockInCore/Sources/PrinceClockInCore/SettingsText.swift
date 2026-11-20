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

/// Settings → Warnings' Notifications row.
public struct NotificationsSetting: Equatable, Sendable {
    /// "On" or "Off".
    public let state: String
    /// Under the row while notifications are off: what warns instead.
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

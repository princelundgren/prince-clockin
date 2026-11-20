import Foundation

/// What the menu bar item shows for one state: a template SF Symbol, whether it pulses, and the one
/// label VoiceOver reads. The item shows no text.
public struct MenuBarLabel: Equatable, Sendable {
    /// The SF Symbol, drawn as a template image.
    public let symbolName: String
    /// Whether the symbol runs the pulse effect, which only logging in does.
    public let isPulsing: Bool
    /// Whether the dot that says an update is waiting follows the symbol.
    public let showsUpdateDot: Bool
    /// The whole item's label for VoiceOver, with durations in the wide style.
    public let accessibilityLabel: String
}

/// The menu bar label for `status`, naming the login it is about from `logins`. `updateVersion` is
/// the waiting update's version, or `nil` when none waits.
public func menuBarLabel(
    for status: MenuBarStatus, logins: [Login], updateVersion: String?, locale: Locale
) -> MenuBarLabel {
    func name(_ id: UUID) -> String {
        logins.first { $0.id == id }?.displayName ?? "a login"
    }
    let symbolName: String
    var isPulsing = false
    let spoken: String
    switch status {
    case .loggingIn(let progress):
        symbolName = "clock.arrow.circlepath"
        isPulsing = true
        spoken = "logging in, \(batchProgressText(progress))"
    case .failure:
        symbolName = "clock.badge.xmark"
        spoken = "something failed"
    case .expired(let id):
        symbolName = "clock.badge.xmark"
        spoken = "\(name(id)) expired"
    case .expiring(let id, let remaining):
        symbolName = "clock.badge.exclamationmark"
        spoken = "\(name(id)) expiring in \(spokenTimeLeftText(remaining, locale: locale))"
    case .ok(let id, let remaining):
        symbolName = "clock"
        spoken = "\(name(id)) expires in \(spokenTimeLeftText(remaining, locale: locale))"
    case .noTimer:
        symbolName = "clock"
        spoken = "no timer"
    }
    var accessibilityLabel = "PrinceClockIn, \(spoken)"
    if let updateVersion { accessibilityLabel += ", update \(updateVersion) available" }
    return MenuBarLabel(
        symbolName: symbolName, isPulsing: isPulsing, showsUpdateDot: updateVersion != nil,
        accessibilityLabel: accessibilityLabel)
}

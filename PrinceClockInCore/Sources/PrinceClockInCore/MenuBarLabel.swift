import Foundation

/// What the menu bar item shows for one state: a template SF Symbol, the text beside it, and the
/// one label VoiceOver reads.
public struct MenuBarLabel: Equatable, Sendable {
    /// The SF Symbol, drawn as a template image.
    public let symbolName: String
    /// The time left or the batch's progress, in monospaced digits; `nil` for a state with none.
    public let text: String?
    /// One sample of each form of text the state can show, at its widest, in the locale. The app
    /// measures them and reserves the widest, so the item's width doesn't change as the time
    /// counts down. Empty when the state shows no text.
    public let widthSamples: [String]
    /// Whether the dot that says an update is waiting follows the label.
    public let showsUpdateDot: Bool
    /// The whole item's label for VoiceOver, with durations in the wide style.
    public let accessibilityLabel: String
}

/// The menu bar label for `status`, naming the login it is about from `logins`. `leadTime` is the
/// warning time, which bounds what an expiring login can show. `updateVersion` is the waiting
/// update's version, or `nil` when none waits.
public func menuBarLabel(
    for status: MenuBarStatus, logins: [Login], leadTime: TimeInterval, updateVersion: String?, locale: Locale
) -> MenuBarLabel {
    func name(_ id: UUID) -> String {
        logins.first { $0.id == id }?.displayName ?? "a login"
    }
    let symbolName: String
    var text: String?
    var widthSamples: [String] = []
    let spoken: String
    switch status {
    case .loggingIn(let progress):
        symbolName = "clock.arrow.circlepath"
        text = batchProgressText(progress)
        widthSamples = [widestForm(of: batchProgressText(BatchProgress(position: 10, total: 10)))]
        spoken = "logging in, \(batchProgressText(progress))"
    case .failure:
        symbolName = "exclamationmark.triangle"
        spoken = "something failed"
    case .expired(let id):
        symbolName = "clock.badge.xmark"
        spoken = "\(name(id)) expired"
    case .expiring(let id, let remaining):
        symbolName = "clock.badge.exclamationmark"
        text = timeLeftText(remaining, locale: locale)
        widthSamples = timeLeftWidthSamples(upTo: leadTime, locale: locale)
        spoken = "\(name(id)) expiring in \(spokenTimeLeftText(remaining, locale: locale))"
    case .ok(let id, let remaining):
        symbolName = "clock"
        text = timeLeftText(remaining, locale: locale)
        widthSamples = timeLeftWidthSamples(upTo: nil, locale: locale)
        spoken = "\(name(id)) expires in \(spokenTimeLeftText(remaining, locale: locale))"
    case .noTimer:
        symbolName = "clock"
        spoken = "no timer"
    }
    var accessibilityLabel = "PrinceClockIn, \(spoken)"
    if let updateVersion { accessibilityLabel += ", update \(updateVersion) available" }
    return MenuBarLabel(
        symbolName: symbolName, text: text, widthSamples: widthSamples, showsUpdateDot: updateVersion != nil,
        accessibilityLabel: accessibilityLabel)
}

/// The widest time left of each form up to `limit` (`nil` for none): under a minute, minutes,
/// hours and minutes, and days and hours. Minutes stop at 59 and hours at 23, and `limit` sets
/// how many digits its largest unit has; with no limit, days get two.
private func timeLeftWidthSamples(upTo limit: TimeInterval?, locale: Locale) -> [String] {
    let minute: TimeInterval = 60
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86400
    let bound = limit ?? .infinity
    var samples = [timeLeftText(minute / 2, locale: locale)]
    if bound >= minute {
        samples.append(widestForm(of: timeLeftText(min(bound, 59 * minute), locale: locale)))
    }
    if bound >= hour {
        let hours = min((bound / hour).rounded(.down), 23)
        samples.append(widestForm(of: timeLeftText(hours * hour + 10 * minute, locale: locale)))
    }
    if bound >= day {
        let days = limit.map { ($0 / day).rounded(.down) } ?? 10
        samples.append(widestForm(of: timeLeftText(days * day + 10 * hour, locale: locale)))
    }
    return samples
}

/// `text` with every digit an 8, which in monospaced digits is as wide as any other.
private func widestForm(of text: String) -> String {
    String(text.map { $0.isWholeNumber ? "8" : $0 })
}

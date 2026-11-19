import Foundation

/// Time left for the tiles, the menu bar and notifications: narrow, at most two of days, hours and
/// minutes, rounded down ("5h 13m" in en_GB; sv_SE joins each number to its unit with U+202F).
/// Under a minute it is "<1m" in every locale.
public func timeLeftText(_ remaining: TimeInterval, locale: Locale) -> String {
    if isUnderAMinute(remaining) { return "<1m" }
    return Duration.seconds(remaining).formatted(timeLeftStyle(width: .narrow, locale: locale))
}

/// Time left for VoiceOver: the same units in the wide style ("5 hours, 13 minutes"), and "less
/// than a minute" under a minute.
public func spokenTimeLeftText(_ remaining: TimeInterval, locale: Locale) -> String {
    if isUnderAMinute(remaining) { return "less than a minute" }
    return Duration.seconds(remaining).formatted(timeLeftStyle(width: .wide, locale: locale))
}

/// A time of day in `calendar`'s time zone, in the locale's shortened form and 12- or 24-hour
/// setting ("14:02").
public func clockTimeText(_ date: Date, locale: Locale, calendar: Calendar) -> String {
    date.formatted(
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
}

/// A time on another day, for the middle of a sentence: relative where the locale has a word for
/// the day ("tomorrow at 03:55"), else the medium date and short time, in `calendar`'s time zone.
/// Relative to the real clock.
public func dayAndTimeText(_ date: Date, locale: Locale, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    formatter.formattingContext = .middleOfSentence
    return formatter.string(from: date)
}

/// A batch's progress, in its one form ("1 of 2").
public func batchProgressText(_ progress: BatchProgress) -> String {
    "\(progress.position) of \(progress.total)"
}

/// Foundation would round this down to "0m".
private func isUnderAMinute(_ remaining: TimeInterval) -> Bool {
    remaining > 0 && remaining < 60
}

private func timeLeftStyle(width: Duration.UnitsFormatStyle.UnitWidth, locale: Locale) -> Duration.UnitsFormatStyle {
    Duration.UnitsFormatStyle(
        allowedUnits: [.days, .hours, .minutes], width: width, maximumUnitCount: 2,
        fractionalPart: .hide(rounded: .down)
    ).locale(locale)
}

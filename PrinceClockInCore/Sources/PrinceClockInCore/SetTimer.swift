import Foundation

/// Set Timer's two ways of saying when a login logged in.
public enum SetTimerMode: Hashable, Sendable {
    case expiresIn
    case loggedInAt
}

/// What the user has entered in a login's Set Timer form, as typed, so it can be kept while the
/// form is open and checked as it changes.
public struct SetTimerDraft: Equatable, Sendable {
    public var mode: SetTimerMode
    /// Expires In's whole hours and minutes.
    public var hours: String
    public var minutes: String
    public var loggedInAt: Date
    /// The Session Length pop-up's choice, from `sessionLengthOptions()`.
    public var sessionLength: SessionLengthChoice
    /// Custom…'s number of hours, in the locale's number format.
    public var customHours: String
    /// The login's own length when the list doesn't have it, and the text Custom… showed for it,
    /// so a rounded text doesn't change the length unless the user edits it.
    private var unlistedLength: UnlistedLength?

    private struct UnlistedLength: Equatable, Sendable {
        let text: String
        let length: TimeInterval
    }

    /// A new draft for `login`: Expires In 1 hour, Logged In At its login time or else `now`, and
    /// its session length, under Custom… when the list doesn't have it.
    public init(for login: Login, now: Date, locale: Locale) {
        mode = .expiresIn
        hours = "1"
        minutes = "0"
        loggedInAt = login.loginTime ?? now
        customHours = ""
        switch login.sessionLength {
        case nil:
            sessionLength = .noTimer
        case let length? where isListedSessionLength(length):
            sessionLength = .length(length)
        case let length?:
            sessionLength = .custom
            customHours = sessionLengthHoursText(length, locale: locale)
            unlistedLength = UnlistedLength(text: customHours, length: length)
        }
    }

    /// What the draft tells Set Timer, or `nil` while a field it needs is empty or not a number,
    /// Expires In's hours are negative or its minutes outside 0 to 59, or no finite session length
    /// is chosen. An empty hours or minutes field counts as zero, as long as the other isn't empty
    /// too.
    public func entry(locale: Locale) -> TimerEntry? {
        guard let length = sessionLengthValue(locale: locale) else { return nil }
        switch mode {
        case .expiresIn:
            let fields = [hours, minutes].map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.contains(where: { !$0.isEmpty }) else { return nil }
            let numbers = fields.map { $0.isEmpty ? 0 : Int($0) }
            guard let hours = numbers[0], let minutes = numbers[1], hours >= 0, (0...59).contains(minutes)
            else { return nil }
            return .expiresIn(
                TimeInterval(hours) * Self.secondsPerHour + TimeInterval(minutes) * 60, sessionLength: length)
        case .loggedInAt:
            return .loggedInAt(loggedInAt, sessionLength: length)
        }
    }

    /// Whether Set would set a timer at `now`, and which.
    public func check(now: Date, locale: Locale) -> SetTimerCheck {
        if sessionLength == .noTimer { return .noSessionLength }
        guard let entry = entry(locale: locale) else { return .incomplete }
        do throws(TimerError) {
            return .ready(try timerSetting(for: entry, now: now))
        } catch {
            return .refused(error)
        }
    }

    private static let secondsPerHour: TimeInterval = 3600

    private func sessionLengthValue(locale: Locale) -> TimeInterval? {
        switch sessionLength {
        case .length(let length):
            return length
        case .custom:
            if let unlistedLength, customHours == unlistedLength.text { return unlistedLength.length }
            return sessionLengthFromHours(customHours, locale: locale)
        case .noTimer:
            return nil
        }
    }
}

/// Whether a Set Timer draft can be set.
public enum SetTimerCheck: Equatable, Sendable {
    /// The Session Length pop-up is on No timer, whatever the other fields hold.
    case noSessionLength
    /// A field it needs is empty, not a number or out of range.
    case incomplete
    case refused(TimerError)
    case ready(TimerSetting)
}

/// The line under Set Timer's fields: when the login would expire ("Expires tomorrow at 03:55.
/// The session length times its next login."), today's expiry as a clock time alone, or why Set
/// refuses the draft. "Choose a session length" while none is chosen, and `nil` while a field is
/// incomplete.
public func setTimerCaption(for check: SetTimerCheck, now: Date, locale: Locale, calendar: Calendar) -> String? {
    switch check {
    case .noSessionLength:
        return "Choose a session length"
    case .incomplete:
        return nil
    case .refused(let error):
        return error.message
    case .ready(let setting):
        let expiry = setting.expiry
        let when = calendar.isDate(expiry, inSameDayAs: now)
            ? "at \(clockTimeText(expiry, locale: locale, calendar: calendar))"
            : dayAndTimeText(expiry, locale: locale, calendar: calendar)
        return "Expires \(when). The session length times its next login."
    }
}
